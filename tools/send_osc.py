#!/usr/bin/env python3
"""Send one OSC float32 control packet to MetaSonic's loopback listener."""

from __future__ import annotations

import argparse
import socket
import struct


def osc_string(value: str) -> bytes:
    raw = value.encode("ascii") + b"\0"
    return raw + (b"\0" * ((4 - (len(raw) % 4)) % 4))


def build_float_message(address: str, value: float) -> bytes:
    return osc_string(address) + osc_string(",f") + struct.pack(">f", value)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Send one OSC float32 message to a UDP listener."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7000)
    parser.add_argument("--address", default="/v0/outgain/0")
    parser.add_argument("--value", type=float, required=True)
    args = parser.parse_args()

    packet = build_float_message(args.address, args.value)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(packet, (args.host, args.port))


if __name__ == "__main__":
    main()
