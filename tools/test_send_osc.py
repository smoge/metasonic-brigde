#!/usr/bin/env python3
"""Unit tests for tools/send_osc.py."""

from __future__ import annotations

import argparse
import contextlib
import io
import struct
import unittest

import send_osc


class SendOscTests(unittest.TestCase):
    def test_builds_float32_message(self) -> None:
        packet = send_osc.build_message("/v0/cutoff/0", "1500.0", "float")

        self.assertEqual(
            packet,
            b"/v0/cutoff/0\0\0\0\0"
            + b",f\0\0"
            + struct.pack(">f", 1500.0),
        )

    def test_builds_int32_message(self) -> None:
        packet = send_osc.build_message("/v0/cutoff/0", "42", "int")

        self.assertEqual(
            packet,
            b"/v0/cutoff/0\0\0\0\0"
            + b",i\0\0"
            + struct.pack(">i", 42),
        )

    def test_address_validation_rejects_bad_shapes(self) -> None:
        for address in ("v0/cutoff/0", "/v0//cutoff/0", "/v0/cutoff/0/"):
            with self.subTest(address=address):
                with self.assertRaises(argparse.ArgumentTypeError):
                    send_osc.osc_address(address)

    def test_address_validation_rejects_non_ascii(self) -> None:
        with self.assertRaises(argparse.ArgumentTypeError):
            send_osc.osc_address("/v0/café/0")

    def test_parse_args_accepts_value_sequences(self) -> None:
        args = send_osc.parse_args(
            [
                "--address", "/v0/cutoff/0",
                "--type", "float",
                "--value", "1000",
                "--value", "2000",
                "--repeat", "3",
                "--interval", "0.01",
            ]
        )

        self.assertEqual(args.address, "/v0/cutoff/0")
        self.assertEqual(args.type, "float")
        self.assertEqual(args.value, ["1000", "2000"])
        self.assertEqual(args.repeat, 3)
        self.assertEqual(args.interval, 0.01)

    def test_invalid_int_value_fails_before_socket_open(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = send_osc.main(
                [
                    "--address", "/v0/cutoff/0",
                    "--type", "int",
                    "--value", "3.14",
                ]
            )

        self.assertEqual(code, 2)
        self.assertIn("--type int values must be integers", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
