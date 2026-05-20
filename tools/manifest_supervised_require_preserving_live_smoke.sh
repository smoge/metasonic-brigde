#!/usr/bin/env bash
#
# Opt-in operator smoke for the supervised
# --manifest-live-reload-demo require-preserving route.
#
# This script is intentionally NOT a default CI gate. It opens
# real PortAudio and binds a real UDP socket; it must run on a
# host with a working audio backend (ALSA / PipeWire / a real
# device, etc.). Default CI gates live in `just check-offline`
# and stay deterministic / device-free.
#
# Counterpart to tools/manifest_supervised_live_smoke.sh
# (stopped-audio) and tools/manifest_supervised_try_preserving_live_smoke.sh
# (try-preserving). The three wrappers are intentionally
# separate (not parametrized) so a regression on one route's
# marker set cannot mask the others', and so transcript /
# probe-log artifacts do not collide when multiple smokes run
# in sequence.
#
# What this smoke does:
#
#   1. Confirms the configured UDP port is currently free.
#   2. Launches `metasonic-bridge --manifest-live-reload-demo
#      require-preserving` against the configured manifest +
#      demo pair (default the blessed preserve-cutoff fixture,
#      where preserving commits — require-preserving and
#      try-preserving share this same happy path), with stdin
#      from a fifo so the wrapper can drive the two interactive
#      Enter prompts.
#   3. Waits for the first "press Enter to run the supervised
#      reload" prompt, injects an OSC write to /v0/lpf/0, then
#      sends Enter to trigger the supervised reload.
#   4. Waits for the "Send OSC to the surface for demo=..."
#      post-reload prompt, injects a second OSC write to
#      /v0/lpf/0, then sends Enter to drive cleanup.
#   5. Waits for demo exit, then runs two post-exit probes
#      against the OSC port:
#        * `ss -lun` snapshot (passive; no UDP listener for
#          the port);
#        * an active Python `socket.bind(('localhost', PORT))`
#          probe that exits 0 only on a successful rebind.
#
# Marker checks at the end verify the supervised
# require-preserving route's acceptance markers: supervised
# require-preserving route selected (specific route-line
# rendering, distinct from stopped-audio and try-preserving);
# real audio + ingress; pre-reload OSC accept; preserving phase
# started AND committed under the supervisor; post-reload
# ingress targets the new demo + OSC accept; cleanup releases
# resources. Plus a load-bearing negative marker: NO
# "stopped-audio phase" lines appear in the transcript. The
# direct path's try-preserving fallback would emit those — the
# require-preserving supervised path must never compose with
# stopped-audio. The script exits 0 only if every positive
# marker is observed and the negative marker holds.
#
# Configurable env vars (also accessible via `just
# manifest-supervised-require-preserving-live-smoke port=N`):
#
#   PORT       UDP port for OSC ingress (default 17003).
#              17003 instead of 17001/17002 so this smoke does
#              not collide with a concurrent stopped-audio or
#              try-preserving smoke or its leftover post-exit
#              state.
#   MANIFEST   Manifest fixture path (default
#              examples/manifests/preserve-cutoff.json — the
#              blessed fixture; preserving commits).
#   OLD_DEMO   Initial demo key (default preserve-cutoff-dark).
#   NEW_DEMO   Target demo key (default preserve-cutoff-bright).
#   WORK_DIR   Where to put transcript + probe-log artifacts
#              (default $TMPDIR or /tmp).
#
# Exit codes:
#   0  every acceptance marker observed, negative marker held
#   1  pre-flight failed, the demo did not produce the
#      expected output within the per-prompt timeout, the
#      post-exit probes failed, at least one positive marker
#      was missing, or the negative marker (no stopped-audio
#      phase) was violated
#
# This script does not assume any particular CI runner; it
# assumes you ran `stack build` first. See the justfile recipe
# for a `stack-build` dependency.

set -u

PORT="${PORT:-17003}"
MANIFEST="${MANIFEST:-examples/manifests/preserve-cutoff.json}"
OLD_DEMO="${OLD_DEMO:-preserve-cutoff-dark}"
NEW_DEMO="${NEW_DEMO:-preserve-cutoff-bright}"

WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}}"
TRANSCRIPT="$WORK_DIR/manifest-supervised-require-preserving-live-transcript.txt"
PROBE_LOG="$WORK_DIR/manifest-supervised-require-preserving-live-probe.txt"
STDIN_FIFO="$WORK_DIR/manifest-supervised-require-preserving-live-stdin"

# tools/send_osc.py is the project's existing OSC sender (used
# by the osc-send / osc-arbitration recipes too). Using it here
# avoids a dependency on liblo's oscsend, which is not
# universally installed.
SEND_OSC="tools/send_osc.py"

cleanup() {
  if [ -n "${DEMO_PID:-}" ] && kill -0 "$DEMO_PID" 2>/dev/null; then
    kill -TERM "$DEMO_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$DEMO_PID" 2>/dev/null || true
  fi
  exec 3<&- 2>/dev/null || true
  rm -f "$STDIN_FIFO"
}
trap cleanup EXIT

rm -f "$STDIN_FIFO" "$TRANSCRIPT" "$PROBE_LOG"
mkfifo "$STDIN_FIFO"

# Open the fifo read+write so the producer side does not block
# waiting for a reader; the demo opens it for reading only
# after stack exec finishes its startup, which can be several
# hundred milliseconds.
exec 3<>"$STDIN_FIFO"

cat <<EOF
=== manifest-supervised-require-preserving-live-smoke ===
port:        $PORT
manifest:    $MANIFEST
old demo:    $OLD_DEMO
new demo:    $NEW_DEMO
transcript:  $TRANSCRIPT
probe log:   $PROBE_LOG
EOF

# Pre-flight: the iproute2 'ss' utility is required for the
# passive snapshot probe (marker 6b). Without this check, a
# missing 'ss' would silently make `ss -lun | grep -q ...` look
# like "no listener" and falsely pass the marker — the active
# bind probe would still cover the real cleanup proof, but the
# script and docs both promise two independent probes.
if ! command -v ss >/dev/null 2>&1; then
  echo "[smoke] FAIL: 'ss' not found in PATH; marker 6b requires the iproute2 'ss' utility"
  exit 1
fi

# Pre-flight: the configured port must be free.
if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind(('localhost', $PORT))
except OSError as e:
    print('pre-flight: port already in use:', e)
    sys.exit(1)
s.close()
"; then
  echo "[smoke] pre-flight: port $PORT is free"
else
  echo "[smoke] FAIL: port $PORT is already in use; pick another with PORT=N"
  exit 1
fi

stdbuf -oL -eL stack exec -- metasonic-bridge \
  --session-osc-port "$PORT" \
  --manifest-live-reload-demo require-preserving \
  "$MANIFEST" \
  "$OLD_DEMO" "$NEW_DEMO" \
  < "$STDIN_FIFO" \
  > "$TRANSCRIPT" 2>&1 &
DEMO_PID=$!

echo "[smoke] demo PID=$DEMO_PID, port=$PORT"

# Wait for the first interactive prompt. Bumped to 120s for
# cold-cache stack-exec startup + PortAudio enumeration.
echo "[smoke] waiting for first prompt (up to 120s)..."
for i in $(seq 1 120); do
  sleep 1
  if grep -q "press Enter to run the supervised reload" "$TRANSCRIPT" 2>/dev/null; then
    echo "[smoke] first prompt observed at t=${i}s"
    break
  fi
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    echo "[smoke] FAIL: demo exited before first prompt"
    echo "=== partial transcript ==="
    cat "$TRANSCRIPT" || true
    echo "=== end ==="
    exit 1
  fi
  if [ "$i" -eq 120 ]; then
    echo "[smoke] FAIL: timeout waiting for first prompt"
    exit 1
  fi
done

# Inject pre-reload OSC. Numeric values picked to be
# distinguishable in the post-run grep.
if python3 "$SEND_OSC" --port "$PORT" --address /v0/lpf/0 --value 0.75 >/dev/null; then
  echo "[smoke] pre-reload OSC sent (/v0/lpf/0 = 0.75)"
else
  echo "[smoke] FAIL: pre-reload OSC send failed"
  exit 1
fi
sleep 1

printf '\n' >&3
echo "[smoke] sent first Enter (triggers supervised reload)"

# Wait for the second prompt.
echo "[smoke] waiting for second prompt (up to 120s)..."
for i in $(seq 1 120); do
  sleep 1
  if grep -q "Send OSC to the surface for demo=" "$TRANSCRIPT" 2>/dev/null; then
    echo "[smoke] second prompt observed at t=${i}s"
    break
  fi
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    echo "[smoke] FAIL: demo exited before second prompt"
    exit 1
  fi
  if [ "$i" -eq 120 ]; then
    echo "[smoke] FAIL: timeout waiting for second prompt"
    exit 1
  fi
done

# Inject post-reload OSC against the new manifest target.
if python3 "$SEND_OSC" --port "$PORT" --address /v0/lpf/0 --value 0.25 >/dev/null; then
  echo "[smoke] post-reload OSC sent (/v0/lpf/0 = 0.25)"
else
  echo "[smoke] FAIL: post-reload OSC send failed"
  exit 1
fi
sleep 1

printf '\n' >&3
echo "[smoke] sent second Enter (triggers cleanup)"

# Demo should exit cleanly within a few seconds after the
# second Enter.
wait "$DEMO_PID"
DEMO_EXIT=$?
echo "[smoke] demo exit=$DEMO_EXIT" | tee -a "$PROBE_LOG"

# Post-exit probes.
sleep 1

# Capture ss's output and exit code separately, then grep the
# captured text. A bare `ss -lun | grep -q ...` would mask an
# `ss` failure as "no listener" — grep just sees an empty
# stream and exits 1, which the original code interpreted as
# "snapshot clean." With the snapshot captured, we surface a
# nonzero `ss` exit as its own failure before we trust the
# grep result.
SS_SNAPSHOT="$(ss -lun)"
SS_RC=$?
if [ "$SS_RC" -ne 0 ]; then
  echo "[smoke] FAIL: 'ss -lun' exited $SS_RC" | tee -a "$PROBE_LOG"
  exit 1
fi
if printf '%s\n' "$SS_SNAPSHOT" | grep -q ":$PORT "; then
  echo "[smoke] FAIL: ss snapshot shows UDP listener still bound on port $PORT" | tee -a "$PROBE_LOG"
  printf '%s\n' "$SS_SNAPSHOT" | grep ":$PORT " | head -3 | tee -a "$PROBE_LOG"
  exit 1
else
  echo "[smoke] ss snapshot: no UDP listener on port $PORT" | tee -a "$PROBE_LOG"
fi

# Active bind probe — load-bearing because an oscsend send
# does NOT prove the socket released; UDP datagrams to an
# unbound port still succeed at the network layer and the OS
# drops them silently.
if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind(('localhost', $PORT))
except OSError as e:
    print('active bind probe: port $PORT bind failed:', repr(e))
    sys.exit(1)
s.close()
print('active bind probe: port $PORT rebound successfully')
" 2>&1 | tee -a "$PROBE_LOG"; then
  :
else
  echo "[smoke] FAIL: active bind probe failed" | tee -a "$PROBE_LOG"
  exit 1
fi

# Marker checks. Each row maps to one of the acceptance markers
# (or a sub-fact for compound markers). Exit non-zero if any
# positive marker is missing or the negative marker is violated.
echo ""
echo "=== marker checks ==="
MISSING=0
check_marker() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if grep -q "$pattern" "$file"; then
    printf "  [ok]   %s\n" "$name"
  else
    printf "  [MISS] %s\n         (looked for %q in %s)\n" \
      "$name" "$pattern" "$file"
    MISSING=1
  fi
}

# Negative-marker variant: asserts the pattern is ABSENT. Used
# to prove the require-preserving supervised path never composes
# with stopped-audio fallback.
check_absent_marker() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if grep -q "$pattern" "$file"; then
    printf "  [BAD]  %s\n         (unexpected %q in %s)\n" \
      "$name" "$pattern" "$file"
    MISSING=1
  else
    printf "  [ok]   %s\n" "$name"
  fi
}

check_marker "1.  supervised require-preserving route selected" \
  "$TRANSCRIPT" "route: supervised (require-preserving; reloadSupervised + HostStackFactory)"
check_marker "2a. audio running" \
  "$TRANSCRIPT" "audio running: yes"
check_marker "2b. OSC ingress bound on configured port" \
  "$TRANSCRIPT" "oscPort=$PORT"
check_marker "3.  pre-reload OSC accept (value=0.75)" \
  "$TRANSCRIPT" "value=0.75"
check_marker "4a. supervised outcome committed" \
  "$TRANSCRIPT" "supervised outcome: committed (new plan installed)"
check_marker "4b. preserving phase started" \
  "$TRANSCRIPT" "preserving phase started"
check_marker "4c. preserving phase committed" \
  "$TRANSCRIPT" "preserving phase committed"
check_absent_marker "4d. no stopped-audio phase (no fallback composition)" \
  "$TRANSCRIPT" "stopped-audio phase"
check_marker "5a. post-reload ingress on new demo" \
  "$TRANSCRIPT" "OSC ingress: open demo=$NEW_DEMO"
check_marker "5b. post-reload OSC accept (value=0.25)" \
  "$TRANSCRIPT" "value=0.25"
check_marker "6a. demo exit 0" \
  "$PROBE_LOG" "demo exit=0"
check_marker "6b. ss snapshot clean (no listener)" \
  "$PROBE_LOG" "no UDP listener on port $PORT"
check_marker "6c. active bind probe rebound port" \
  "$PROBE_LOG" "rebound successfully"

echo ""
if [ "$MISSING" -eq 0 ]; then
  echo "=== SMOKE PASSED ==="
  echo "All acceptance markers observed."
  echo "  transcript: $TRANSCRIPT"
  echo "  probe log:  $PROBE_LOG"
  exit 0
else
  echo "=== SMOKE FAILED ==="
  echo "Missing markers above. Inspect:"
  echo "  transcript: $TRANSCRIPT"
  echo "  probe log:  $PROBE_LOG"
  exit 1
fi
