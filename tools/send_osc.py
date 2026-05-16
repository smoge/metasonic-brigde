#!/usr/bin/env python3
"""Send OSC control packets to a MetaSonic UDP listener."""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time


def positive_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("port must be an integer") from exc
    if port < 1 or port > 65535:
        raise argparse.ArgumentTypeError("port must be in 1..65535")
    return port


def positive_repeat(value: str) -> int:
    try:
        repeat = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("repeat must be an integer") from exc
    if repeat < 1:
        raise argparse.ArgumentTypeError("repeat must be >= 1")
    return repeat


def non_negative_interval(value: str) -> float:
    try:
        interval = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("interval must be a number") from exc
    if interval < 0:
        raise argparse.ArgumentTypeError("interval must be >= 0")
    return interval


def osc_address(value: str) -> str:
    if not value.startswith("/"):
        raise argparse.ArgumentTypeError("OSC address must start with '/'")
    if "//" in value or value.endswith("/"):
        raise argparse.ArgumentTypeError("OSC address has an empty path segment")
    try:
        value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise argparse.ArgumentTypeError("OSC address must be ASCII") from exc
    return value


def osc_string(value: str) -> bytes:
    raw = value.encode("ascii") + b"\0"
    return raw + (b"\0" * ((4 - (len(raw) % 4)) % 4))


def build_float_message(address: str, value: float) -> bytes:
    return osc_string(address) + osc_string(",f") + struct.pack(">f", value)


def build_int_message(address: str, value: int) -> bytes:
    return osc_string(address) + osc_string(",i") + struct.pack(">i", value)


def parse_int_value(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise ValueError("--type int values must be integers") from exc
    if parsed < -(2**31) or parsed > 2**31 - 1:
        raise ValueError("--type int values must fit signed int32")
    return parsed


def parse_float_value(value: str) -> float:
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError("--type float values must be numbers") from exc


def build_message(address: str, value: str, value_type: str) -> bytes:
    parsed = parse_numeric_value(value, value_type)
    return build_parsed_message(address, parsed, value_type)


def parse_numeric_value(value: str, value_type: str) -> float | int:
    if value_type == "float":
        return parse_float_value(value)
    if value_type == "int":
        return parse_int_value(value)
    raise AssertionError(f"unsupported OSC value type: {value_type}")


def build_parsed_message(address: str, value: float | int, value_type: str) -> bytes:
    if value_type == "float":
        return build_float_message(address, float(value))
    if value_type == "int":
        return build_int_message(address, int(value))
    raise AssertionError(f"unsupported OSC value type: {value_type}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send one or more OSC numeric messages to a UDP listener."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=positive_port, default=7000)
    parser.add_argument("--address", type=osc_address, default="/v0/outgain/0")
    parser.add_argument(
        "--value",
        action="append",
        required=True,
        help="numeric value to send; repeat the flag to send a sequence",
    )
    parser.add_argument(
        "--type",
        choices=("float", "int"),
        default="float",
        help="OSC argument type tag to emit (default: float)",
    )
    parser.add_argument(
        "--repeat",
        type=positive_repeat,
        default=1,
        help="repeat the full value sequence this many times",
    )
    parser.add_argument(
        "--interval",
        type=non_negative_interval,
        default=0.0,
        help="seconds to sleep between packets",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="print one line per sent packet",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        values = [
            (value, parse_numeric_value(value, args.type))
            for value in args.value
        ]
    except ValueError as exc:
        print(f"send_osc.py: error: {exc}", file=sys.stderr)
        return 2

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        packet_index = 0
        for _ in range(args.repeat):
            for original, value in values:
                if packet_index > 0 and args.interval > 0:
                    time.sleep(args.interval)
                packet = build_parsed_message(args.address, value, args.type)
                sock.sendto(packet, (args.host, args.port))
                if args.verbose:
                    print(
                        f"sent {args.type} {original} "
                        f"to {args.host}:{args.port} {args.address}"
                    )
                packet_index += 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
