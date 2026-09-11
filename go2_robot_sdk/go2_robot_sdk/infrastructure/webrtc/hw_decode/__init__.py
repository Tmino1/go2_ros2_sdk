"""
Hardware-accelerated H264 video decode for the WebRTC video track.

nix's Python/GStreamer stack cannot load the Jetson's real hardware H264
decoder (nvv4l2decoder) - see hw_decode_helper.py's module docstring for
the full story. This package bridges to it via a helper process running
under system Python instead, replacing aiortc's software-only decoder.
"""
from .hw_h264_decoder import HardwareH264Decoder, install_hardware_decoder

__all__ = ["HardwareH264Decoder", "install_hardware_decoder"]
