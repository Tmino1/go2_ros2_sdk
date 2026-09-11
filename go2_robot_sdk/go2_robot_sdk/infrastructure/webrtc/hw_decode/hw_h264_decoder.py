"""
Hardware-accelerated H264 decoder for aiortc, bridging to hw_decode_helper.py
(a helper process running under SYSTEM Python, where the Jetson's real
nvv4l2decoder plugin actually loads) over a Unix domain socket. See that
file's module docstring for the full rationale and the wire protocol.

Threading note this design depends on: aiortc runs H264Decoder.decode() on
its own dedicated per-track thread (rtcrtpreceiver.py's decoder_worker), not
the asyncio event loop - confirmed by tracing decoder_worker's call site
before building this. Blocking here on the IPC round-trip is therefore
safe: it cannot stall the event loop or anything else in the process.
"""
import logging
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
from typing import List, Optional

import av
import numpy as np
from aiortc.codecs.h264 import H264Decoder as _SoftwareH264Decoder
from aiortc.jitterbuffer import JitterFrame
from av.frame import Frame

logger = logging.getLogger(__name__)

_SYSTEM_PYTHON = "/usr/bin/python3"
_HELPER_SCRIPT = os.path.join(os.path.dirname(__file__), "hw_decode_helper.py")

_CONNECT_TIMEOUT_S = 5.0
_CONNECT_RETRY_INTERVAL_S = 0.05


class HardwareDecodeUnavailable(Exception):
    pass


class HardwareH264Decoder:
    """Drop-in replacement for aiortc.codecs.h264.H264Decoder.

    Deliberately holds no back-reference to the aiortc objects that use it
    (no bound methods/closures over self handed to anything else) so this
    object's internals stay cycle-free. That matters because aiortc's
    decoder_worker does a plain `del decoder` on shutdown, and CPython's
    refcounting only collects (and calls __del__) immediately if nothing -
    including a reference cycle - is keeping the object alive. Immediate,
    deterministic teardown here is what promptly closes the helper's
    socket, rather than leaving it open until the next cyclic-GC pass.

    Falls back to aiortc's own software (PyAV) decoder if the helper can't
    start, or if it fails mid-stream - hardware decode is a performance
    optimization, not something that should be able to take the whole
    video pipeline down if it misbehaves.
    """

    def __init__(self) -> None:
        self._sock: Optional[socket.socket] = None
        self._proc: Optional[subprocess.Popen] = None
        self._socket_path: Optional[str] = None
        self._fallback: Optional[_SoftwareH264Decoder] = None

        try:
            self._start_helper()
        except Exception:
            logger.warning(
                "hardware H264 decoder unavailable, using software decode instead",
                exc_info=True,
            )
            self._fall_back()

    def _start_helper(self) -> None:
        fd, path = tempfile.mkstemp(prefix="go2-hwdecode-", suffix=".sock")
        os.close(fd)
        os.remove(path)  # helper binds this path itself; we just need a unique name
        self._socket_path = path

        # Deliberately NOT start_new_session=True / setsid: staying in
        # go2_driver_node's own process group means the process-group
        # SIGINT teardown already used everywhere else in this project
        # (smoke-test.sh's stop_launch, go2-launch's own Ctrl-C handling)
        # reaches this helper for free, with no new cleanup plumbing.
        self._proc = subprocess.Popen(
            [_SYSTEM_PYTHON, _HELPER_SCRIPT, self._socket_path],
            stdin=subprocess.DEVNULL,
        )

        deadline = time.monotonic() + _CONNECT_TIMEOUT_S
        sock = None
        last_err: Optional[BaseException] = None
        while time.monotonic() < deadline:
            if self._proc.poll() is not None:
                raise HardwareDecodeUnavailable(
                    f"helper process exited early (rc={self._proc.returncode})"
                )
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(self._socket_path)
                break
            except (FileNotFoundError, ConnectionRefusedError) as e:
                last_err = e
                sock.close()
                sock = None
                time.sleep(_CONNECT_RETRY_INTERVAL_S)
        if sock is None:
            self._stop_helper()
            raise HardwareDecodeUnavailable(
                f"could not connect to hw decode helper: {last_err}"
            )
        self._sock = sock
        logger.info(
            "hardware H264 decoder helper connected (pid %s)", self._proc.pid
        )

    def decode(self, encoded_frame: JitterFrame) -> List[Frame]:
        if self._fallback is not None:
            return self._fallback.decode(encoded_frame)
        try:
            return self._decode_via_helper(encoded_frame)
        except Exception:
            logger.warning(
                "hardware decode failed, switching to software decode for "
                "the rest of this connection",
                exc_info=True,
            )
            self._stop_helper()
            self._fall_back()
            return self._fallback.decode(encoded_frame)

    def _decode_via_helper(self, encoded_frame: JitterFrame) -> List[Frame]:
        data = bytes(encoded_frame.data)
        self._sock.sendall(struct.pack("!I", len(data)) + data)

        (count,) = self._recv_struct("!I")
        frames: List[Frame] = []
        for _ in range(count):
            width, height, length = self._recv_struct("!III")
            raw = self._recv_exact(length)
            arr = np.frombuffer(raw, dtype=np.uint8).reshape((height, width, 4))
            frame = av.VideoFrame.from_ndarray(arr, format="rgba")
            frame.pts = encoded_frame.timestamp
            frames.append(frame)
        return frames

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("hw decode helper closed the connection")
            buf += chunk
        return buf

    def _recv_struct(self, fmt: str):
        return struct.unpack(fmt, self._recv_exact(struct.calcsize(fmt)))

    def _fall_back(self) -> None:
        self._fallback = _SoftwareH264Decoder()

    def _stop_helper(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        # Closing the socket IS the shutdown signal - hw_decode_helper.py
        # exits on its own on EOF and tears its own pipeline down. Not
        # waiting on the child here keeps this non-blocking; the
        # process-group SIGINT path covers anything that doesn't exit
        # promptly on its own.
        self._proc = None

    def __del__(self) -> None:
        self._stop_helper()


def install_hardware_decoder() -> None:
    """Monkeypatch aiortc to use HardwareH264Decoder in place of its own
    software-only H264Decoder. Must run before any RTCPeerConnection
    negotiates a video track: aiortc.codecs.get_decoder() resolves the name
    `H264Decoder` from the aiortc.codecs module's namespace at *call* time
    (not at aiortc's own import time), so reassigning it here - any time
    before that first call - cleanly redirects every future video decoder
    aiortc creates, with no changes to aiortc's own installed source."""
    import aiortc.codecs

    aiortc.codecs.H264Decoder = HardwareH264Decoder
    logger.info("installed hardware-accelerated H264 decoder for aiortc")
