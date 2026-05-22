#!/usr/bin/env python3
"""Phase 8e scripted operator pass for the smooth-cutoff fixture.

Drives one complete preserve-smooth-cutoff operator pass without
manual two-terminal choreography. The runner:

  - launches metasonic-bridge under PTY control
  - sends session-stdin commands in the documented order
  - sends OSC writes via UDP at marker-synchronized points
  - captures the full session output as a transcript
  - reports a soft summary of which expected markers appeared

This is transcript scaffolding, NOT pass validation. The operator
still listens to the audio and judges perceptual behavior (does the
cutoff glissando through the reload, do any clicks / dropouts
occur). The runner only removes hand sequencing so the operator can
focus on listening.

See notes/2026-05-22-e-scripted-operator-evidence-harness-design.md
for the contract and discipline.

Exit codes:
  0  - session completed; soft-marker gaps may be reported to stderr
  1  - infrastructure failure (launch, OSC send, prompt timeout,
       nonzero child exit, etc.)
"""

from __future__ import annotations

import os
import pty
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

# Reuse send_osc.build_float_message via import rather than
# subprocess-spawning the CLI for each write. Subprocess would add
# ~50ms of Python startup per packet and serialize awkwardly against
# the marker-synchronized send/wait loop.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from send_osc import build_float_message  # type: ignore  # noqa: E402


# ----- Configuration ---------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
TRANSCRIPT_PATH = Path("/tmp/metasonic-live-session-scripted-smooth-cutoff.log")

OSC_HOST = "127.0.0.1"
OSC_PORT = 17004
OSC_ADDRESS = "/v0/cutoff/1"

SESSION_CMD = [
    "stack", "exec", "--", "metasonic-bridge",
    "--session-osc-port", str(OSC_PORT),
    "--manifest-live-session", "examples/manifests/preserve-smooth-cutoff.json",
    "preserve-smooth-cutoff-dark",
    "--strategy", "require-preserving",
]

# Sweep values. Pre-reload sweep walks cutoff up; post-reload sweeps
# it back down toward the original. Out-of-range probe exercises the
# existing MoiiValueOutOfRange diagnostic on the smoother target.
PRE_RELOAD_SWEEP = [900.0, 1800.0, 2400.0]
POST_RELOAD_SWEEP = [2400.0, 1200.0, 600.0]
OUT_OF_RANGE_PROBE = 10000.0

# Audio dwell between in-range OSC accepts. This is NOT a
# synchronization sleep -- the accept-line wait already serializes
# the sends. This dwell gives the operator's ears time to register
# each step of the sweep before the next value arrives; without it
# the sweep collapses into one near-instantaneous transition and the
# perceptual judgment the operator is paired in to make becomes
# impossible. Skipped on the out-of-range probe (no audible change).
OSC_AUDIO_DWELL_S = 0.3

# Synchronization markers (substring match against the session stream).
PROMPT_MARKER = "Type a command, or <Enter> for status"
RELOAD_COMMITTED_MARKER = "supervised outcome: committed"
TERMINATING_MARKER = "Terminating session."

# Timeouts. Generous enough that ordinary startup + reload do not
# flake; tight enough that a real hang fails the run rather than
# blocking forever.
INITIAL_STARTUP_TIMEOUT = 30.0
COMMAND_TIMEOUT = 10.0
OSC_ACCEPT_TIMEOUT = 5.0
RELOAD_TIMEOUT = 15.0
SHUTDOWN_TIMEOUT = 10.0


# ----- Runner ----------------------------------------------------------------

class RunnerError(Exception):
    """Raised on infrastructure failures (launch / OSC / timeout / child
    nonzero exit). Soft-marker gaps do NOT raise this -- they are
    reported in the soft summary."""


class Runner:
    def __init__(self, transcript_path: Path) -> None:
        self.transcript_path = transcript_path
        self.transcript_file = None  # opened in __enter__
        self.master_fd = -1
        self.proc: subprocess.Popen | None = None
        self.osc_sock: socket.socket | None = None
        self.recent = ""  # rolling buffer of recent output for substring search

    def __enter__(self) -> "Runner":
        self.transcript_file = self.transcript_path.open("w", buffering=1)
        self.osc_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        return self

    def __exit__(self, *_exc_info) -> None:
        if self.proc is not None and self.proc.poll() is None:
            # Last-resort cleanup if the operator interrupts mid-run.
            try:
                self.proc.terminate()
                self.proc.wait(timeout=3.0)
            except (subprocess.TimeoutExpired, ProcessLookupError):
                try:
                    self.proc.kill()
                except ProcessLookupError:
                    pass
        if self.master_fd >= 0:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
        if self.osc_sock is not None:
            self.osc_sock.close()
        if self.transcript_file is not None:
            self.transcript_file.close()

    def launch_session(self) -> None:
        master_fd, slave_fd = pty.openpty()
        try:
            self.proc = subprocess.Popen(
                SESSION_CMD,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd=str(REPO_ROOT),
                close_fds=True,
                start_new_session=True,
            )
        except OSError as exc:
            os.close(master_fd)
            os.close(slave_fd)
            raise RunnerError(f"failed to launch session: {exc}") from exc
        os.close(slave_fd)
        self.master_fd = master_fd

    def consume_until(self, substring: str, timeout_s: float) -> None:
        """Read from the session PTY until `substring` appears in the
        recent output buffer. Mirrors all bytes to the transcript file
        and to stdout (so the operator sees the session live while
        audio is paired)."""
        deadline = time.monotonic() + timeout_s
        while True:
            # Check the retained buffer first. A prior consume_until
            # may have left bytes after its matched marker (e.g. the
            # next prompt arrived in the same PTY read as the
            # supervisor-committed line); if the substring is already
            # here, we must not block on select() waiting for fresh
            # bytes that have already streamed past.
            marker_at = self.recent.find(substring)
            if marker_at >= 0:
                self.recent = self.recent[marker_at + len(substring):]
                return

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RunnerError(
                    f"timed out after {timeout_s:.1f}s waiting for marker "
                    f"{substring!r}"
                )
            rd, _, _ = select.select([self.master_fd], [], [], min(remaining, 0.5))
            if not rd:
                continue
            try:
                chunk = os.read(self.master_fd, 4096)
            except OSError as exc:
                raise RunnerError(
                    f"PTY read failed waiting for {substring!r}: {exc}"
                ) from exc
            if not chunk:
                raise RunnerError(
                    f"session output EOF before marker {substring!r}"
                )
            text = chunk.decode("utf-8", errors="replace")
            self.transcript_file.write(text)
            sys.stdout.write(text)
            sys.stdout.flush()
            # Keep last 16KB for substring search. With a 4KB read
            # size, a 4KB cap would drop the previous read's suffix
            # whenever a fresh 4KB chunk arrived, so a marker that
            # straddled the boundary would silently disappear. 16KB
            # gives several read-sizes of headroom, comfortably more
            # than any expected marker length, while staying trivial
            # in memory.
            self.recent = (self.recent + text)[-16384:]
            # The loop iteration re-checks self.recent at the top, so
            # the match-after-read case is handled there.

    def send_session_line(self, line: str) -> None:
        try:
            os.write(self.master_fd, (line + "\n").encode("utf-8"))
        except OSError as exc:
            raise RunnerError(
                f"failed to send session line {line!r}: {exc}"
            ) from exc

    def send_osc(self, value: float) -> None:
        try:
            packet = build_float_message(OSC_ADDRESS, value)
            self.osc_sock.sendto(packet, (OSC_HOST, OSC_PORT))
        except OSError as exc:
            raise RunnerError(
                f"failed to send OSC value={value} to "
                f"{OSC_HOST}:{OSC_PORT}: {exc}"
            ) from exc

    def wait_for_child_exit(self, timeout_s: float) -> int:
        try:
            return self.proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired as exc:
            raise RunnerError(
                f"session did not exit within {timeout_s:.1f}s of shutdown"
            ) from exc


# ----- Marker convenience wrappers ------------------------------------------

def osc_accept_marker(value: float) -> str:
    # The 8b accept-line renderer trims trailing zeros and dot, so
    # integer-valued doubles render as ints. Format the expected
    # substring the same way so the wait matches the actual output.
    if value == int(value):
        value_str = str(int(value))
    else:
        value_str = format(value, "g")
    return f'osc accept: {OSC_ADDRESS} name="cutoff" value={value_str}'


def osc_reject_marker(value: float) -> str:
    # The reject diagnostic shows the raw float (with decimal),
    # distinct from the polished accept renderer.
    return f"osc reject (out-of-range): tag=cutoff/1 value={value}"


# ----- Pass orchestration ---------------------------------------------------

EXPECTED_SOFT_MARKERS = [
    '/v0/cutoff/1  (name="cutoff", default=600.0, range=[200.0, 6000.0], cc=74)',
    "supervised outcome: committed",
    "controls for preserve-smooth-cutoff-bright (pattern):",
    "osc reject (out-of-range): tag=cutoff/1",
    "Terminating session.",
]


def drive_pass(runner: Runner) -> None:
    """Execute the smooth-cutoff complete-pass sequence per the 8e
    design note: nine steps, all synchronous on observable markers."""
    # Step 0: wait for the initial prompt (session ready for stdin).
    runner.consume_until(PROMPT_MARKER, INITIAL_STARTUP_TIMEOUT)

    # Step 1: demos.
    runner.send_session_line("demos")
    runner.consume_until(PROMPT_MARKER, COMMAND_TIMEOUT)

    # Step 2: controls (pre-reload).
    runner.send_session_line("controls")
    runner.consume_until(PROMPT_MARKER, COMMAND_TIMEOUT)

    # Step 3: pre-reload OSC sweep. Wait for the matching accept line
    # after each value so the next write isn't sent before the current
    # one is observably acknowledged. Dwell briefly after each accept
    # so the operator hears the step rather than a collapsed
    # transition (see OSC_AUDIO_DWELL_S).
    for value in PRE_RELOAD_SWEEP:
        runner.send_osc(value)
        runner.consume_until(osc_accept_marker(value), OSC_ACCEPT_TIMEOUT)
        time.sleep(OSC_AUDIO_DWELL_S)

    # Step 4: reload to bright.
    runner.send_session_line("demo preserve-smooth-cutoff-bright")
    runner.consume_until(RELOAD_COMMITTED_MARKER, RELOAD_TIMEOUT)
    runner.consume_until(PROMPT_MARKER, COMMAND_TIMEOUT)

    # Step 5: controls (post-reload).
    runner.send_session_line("controls")
    runner.consume_until(PROMPT_MARKER, COMMAND_TIMEOUT)

    # Step 6: post-reload OSC sweep. Same dwell discipline as step 3.
    for value in POST_RELOAD_SWEEP:
        runner.send_osc(value)
        runner.consume_until(osc_accept_marker(value), OSC_ACCEPT_TIMEOUT)
        time.sleep(OSC_AUDIO_DWELL_S)

    # Step 7: out-of-range probe.
    runner.send_osc(OUT_OF_RANGE_PROBE)
    runner.consume_until(osc_reject_marker(OUT_OF_RANGE_PROBE), OSC_ACCEPT_TIMEOUT)

    # Step 8: status.
    runner.send_session_line("status")
    runner.consume_until(PROMPT_MARKER, COMMAND_TIMEOUT)

    # Step 9: quit.
    runner.send_session_line("quit")
    runner.consume_until(TERMINATING_MARKER, SHUTDOWN_TIMEOUT)


def soft_summary(transcript_path: Path) -> list[str]:
    """Scan the captured transcript for the expected soft markers.
    Returns the list of markers that were NOT found."""
    contents = transcript_path.read_text(errors="replace")
    return [m for m in EXPECTED_SOFT_MARKERS if m not in contents]


# ----- Main -----------------------------------------------------------------

def main() -> int:
    fixture = REPO_ROOT / "examples/manifests/preserve-smooth-cutoff.json"
    if not fixture.is_file():
        print(
            f"run_live_session_pass.py: error: missing fixture {fixture}",
            file=sys.stderr,
        )
        return 1

    print(f"scripted operator pass -> {TRANSCRIPT_PATH}", file=sys.stderr)

    with Runner(TRANSCRIPT_PATH) as runner:
        try:
            runner.launch_session()
            drive_pass(runner)
            exit_code = runner.wait_for_child_exit(SHUTDOWN_TIMEOUT)
            # Write a runner footer so the transcript is self-contained
            # (the equivalent of script(1)'s "Script done" line under
            # direct PTY mode -- the design note expects parity here).
            footer = (
                f"\n=== runner: session exited with code {exit_code} "
                f"at {time.strftime('%Y-%m-%d %H:%M:%S%z')} ===\n"
            )
            runner.transcript_file.write(footer)
            sys.stdout.write(footer)
            sys.stdout.flush()
            if exit_code != 0:
                print(
                    f"session child exited nonzero: {exit_code}",
                    file=sys.stderr,
                )
                return 1
        except RunnerError as exc:
            print(f"harness failure: {exc}", file=sys.stderr)
            return 1

    # Soft-marker summary. Missing markers print to stderr but do NOT
    # fail the run (per the 8e design note: soft check, not hard gate).
    missing = soft_summary(TRANSCRIPT_PATH)
    if missing:
        print("soft summary: missing markers in transcript:", file=sys.stderr)
        for m in missing:
            print(f"  - {m!r}", file=sys.stderr)
    else:
        print("soft summary: all expected markers seen", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
