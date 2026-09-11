#!/usr/bin/env python3
"""
Hardware H264 decode helper - runs under SYSTEM Python (apt's python3, 3.8
on this JetPack), never under the nix devShell's Python.

Why this process exists at all: nix's own Python/GStreamer stack cannot
load the Jetson's real hardware decoder plugin (nvv4l2decoder) - it needs
system libraries (and, underneath those, NVIDIA's proprietary Tegra/CUDA
driver stack) that nix's isolated environment deliberately doesn't expose,
and there is no safe way to bridge that in-process (patching library search
paths breaks nix's own glibc resolution; patchelf-ing the plugin only pushes
the same problem into the proprietary driver libraries one level down).
System Python, on the other hand, already has working GStreamer GI bindings
and can load nvv4l2decoder natively - so decoding happens over here, and
only the decoded pixels cross back to go2_driver_node (nix's Python 3.11)
over a Unix domain socket. See hw_h264_decoder.py for the client side and
the aiortc integration point.

Protocol (both sides must stay in sync - this file is the source of truth):
  request  (client -> server): 4-byte BE uint32 length L, then L bytes of
                                one H264 access unit (Annex-B byte-stream,
                                exactly what aiortc's JitterFrame.data
                                already contains - no repackaging needed).
  response (server -> client): 4-byte BE uint32 frame count N (can be 0 -
                                the decoder may need a few pushes before
                                its first output, same as software decode
                                returning an empty list), then for each of
                                N frames: 4-byte BE width, 4-byte BE height,
                                4-byte BE data length, then that many bytes
                                of raw RGBA pixel data.

Lifecycle: spawned as a plain (non-detached) child of go2_driver_node, so
it shares its process group and dies for free under the same process-group
SIGINT teardown as every other node in the launch (see smoke-test.sh /
flake.nix go2-launch history for why that matters - an earlier version of
this project's launch cleanup left real orphaned nodes running connected to
the robot, which is exactly the failure mode being avoided here). On top of
that: this process does NOT assume it will always be signalled cleanly - if
its socket read hits EOF (the client closed normally) or a connection
reset, it exits and tears down the pipeline on its own rather than waiting
around for a signal that might not come.
"""
import os
import queue
import signal
import socket
import struct
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

Gst.init(None)

PIPELINE_DESC = (
    "appsrc name=src is-live=true format=time "
    "caps=video/x-h264,stream-format=byte-stream,alignment=au ! "
    "h264parse ! nvv4l2decoder ! nvvidconv ! "
    "video/x-raw,format=RGBA ! "
    "appsink name=sink emit-signals=true sync=false max-buffers=4 drop=false"
)

# Frames land here from GStreamer's own streaming thread (the "new-sample"
# callback below does not run on this file's main thread) - a Queue is the
# thread-safe hand-off, not a plain list.
_ready_frames: "queue.Queue" = queue.Queue()


def _on_new_sample(sink):
    sample = sink.emit("pull-sample")
    if sample is not None:
        buf = sample.get_buffer()
        struct_ = sample.get_caps().get_structure(0)
        width = struct_.get_value("width")
        height = struct_.get_value("height")
        ok, mapinfo = buf.map(Gst.MapFlags.READ)
        if ok:
            _ready_frames.put((width, height, bytes(mapinfo.data)))
            buf.unmap(mapinfo)
    return Gst.FlowReturn.OK


def _recv_exact(conn: socket.socket, n: int) -> "bytes | None":
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None  # peer closed - EOF, exit cleanly rather than linger
        buf += chunk
    return buf


def _drain_ready_frames():
    frames = []
    while True:
        try:
            frames.append(_ready_frames.get_nowait())
        except queue.Empty:
            break
    return frames


def main(socket_path: str) -> None:
    if os.path.exists(socket_path):
        os.remove(socket_path)

    # Bind+listen FIRST, before any GStreamer/pipeline setup - the client's
    # own connect-retry loop has a bounded timeout, and pipeline warmup
    # (loading the hardware decoder block, NvMMLiteOpen etc) can itself take
    # a few seconds. An earlier version of this file did the pipeline setup
    # first and lost that race outright: the client gave up with ENOENT
    # before this process ever got around to creating the socket file.
    # connect() succeeding doesn't require accept() to have run yet (the OS
    # backlog queue handles that), so binding early and accepting later,
    # after the pipeline is ready, is both correct and simple.
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(socket_path)
    srv.listen(1)

    pipeline = Gst.parse_launch(PIPELINE_DESC)
    appsrc = pipeline.get_by_name("src")
    appsink = pipeline.get_by_name("sink")
    appsink.connect("new-sample", _on_new_sample)

    def _shutdown(signum=None, frame=None):
        pipeline.set_state(Gst.State.NULL)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    pipeline.set_state(Gst.State.PLAYING)
    # Bounded wait, not CLOCK_TIME_NONE: nvv4l2decoder won't finish its async
    # transition to PLAYING until it has actually seen stream data, so
    # blocking indefinitely here before any buffer is pushed deadlocks.
    pipeline.get_state(5 * Gst.SECOND)

    pts = 0
    frame_duration = Gst.SECOND // 30

    conn = None
    try:
        conn, _ = srv.accept()
        while True:
            header = _recv_exact(conn, 4)
            if header is None:
                break
            (length,) = struct.unpack("!I", header)
            data = _recv_exact(conn, length)
            if data is None:
                break

            buf = Gst.Buffer.new_wrapped(data)
            buf.pts = pts
            buf.duration = frame_duration
            pts += frame_duration
            appsrc.emit("push-buffer", buf)

            frames = _drain_ready_frames()
            conn.sendall(struct.pack("!I", len(frames)))
            for width, height, raw in frames:
                conn.sendall(struct.pack("!III", width, height, len(raw)))
                conn.sendall(raw)
    finally:
        if conn is not None:
            conn.close()
        srv.close()
        if os.path.exists(socket_path):
            os.remove(socket_path)
        pipeline.set_state(Gst.State.NULL)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: hw_decode_helper.py <unix-socket-path>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
