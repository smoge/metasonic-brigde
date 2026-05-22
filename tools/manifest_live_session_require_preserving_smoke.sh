#!/usr/bin/env bash
#
# Opt-in operator smoke for the supervised
# --manifest-live-session (require-preserving) route.
#
# This script is intentionally NOT a default CI gate. It opens
# real PortAudio and binds a real UDP socket; it must run on a
# host with a working audio backend (ALSA / PipeWire / a real
# device, etc.). Default CI gates live in `just check-offline`
# and stay deterministic / device-free.
#
# Counterpart to the three live-reload-demo wrappers (stopped-
# audio / try-preserving / require-preserving) but exercising
# the Phase 8 v0 live-session shell instead of the two-shot
# OLD/NEW reload demo. The session shell:
#
#   * opens audio + OSC ingress on DEMO through the supervised
#     lifecycle;
#   * reads stdin commands: `demo:KEY` triggers a supervised
#     reload, `<Enter>` prints a status snapshot, `<Ctrl-D>`
#     exits;
#   * defaults to the require-preserving strategy
#     (preserving-only — no stopped-audio fallback composition).
#
# What this smoke does:
#
#   1. Confirms the configured UDP port is currently free.
#   2. Launches `metasonic-bridge --manifest-live-session
#      MANIFEST DEMO --strategy require-preserving` against the
#      configured fixture (default the blessed preserve-cutoff
#      manifest, where preserving commits without fallback),
#      with stdin from a fifo so the wrapper can drive the
#      interactive command loop.
#   3. Waits for the first "Type a command" prompt, injects an
#      OSC write to /v0/lpf/0, then sends a `demo:NEW_KEY`
#      command to trigger the supervised reload.
#   4. Waits for the "supervised outcome: committed" line and
#      the next "Type a command" prompt, injects a second OSC
#      write to /v0/lpf/0, then sends an empty line to drive a
#      status snapshot (so the transcript records the
#      post-reload ingress on the new demo).
#   5. Closes stdin (Ctrl-D equivalent) to exit the session.
#   6. Waits for exit, then runs two post-exit probes against
#      the OSC port:
#        * `ss -lun` snapshot (passive; no UDP listener for
#          the port);
#        * an active Python `socket.bind(('localhost', PORT))`
#          probe that exits 0 only on a successful rebind.
#
# Marker checks at the end verify the supervised
# require-preserving session's acceptance markers: route line,
# real audio + ingress, pre-reload OSC accept, preserving phase
# started AND committed under the supervisor, supervised
# outcome committed, post-reload status shows ingress on the
# new demo, post-reload OSC accept, exit + cleanup probes. Plus
# a load-bearing NEGATIVE marker: NO "stopped-audio phase"
# lines appear in the transcript — proving the
# require-preserving session never composes with stopped-audio
# fallback. The script exits 0 only if every positive marker is
# observed and the negative marker holds.
#
# Configurable env vars (also accessible via `just
# manifest-live-session-require-preserving-smoke port=N`):
#
#   PORT       UDP port for OSC ingress (default 17004).
#              17004 instead of 17001/17002/17003 so this smoke
#              does not collide with a concurrent live-reload-
#              demo smoke on those ports.
#   MANIFEST   Manifest fixture path (default
#              examples/manifests/preserve-cutoff.json).
#   OLD_DEMO   Initial demo key (default preserve-cutoff-dark).
#   NEW_DEMO   Target demo key fed via `demo:NEW_DEMO`
#              (default preserve-cutoff-bright).
#   WORK_DIR   Where to put transcript + probe-log artifacts
#              (default $TMPDIR or /tmp).
#
# Exit codes:
#   0  every acceptance marker observed, negative marker held
#   1  pre-flight failed, the session did not produce the
#      expected output within the per-prompt timeout, the
#      post-exit probes failed, at least one positive marker
#      was missing, or the negative marker (no stopped-audio
#      phase) was violated

set -u

PORT="${PORT:-17004}"
MANIFEST="${MANIFEST:-examples/manifests/preserve-cutoff.json}"
OLD_DEMO="${OLD_DEMO:-preserve-cutoff-dark}"
NEW_DEMO="${NEW_DEMO:-preserve-cutoff-bright}"

WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}}"
TRANSCRIPT="$WORK_DIR/manifest-live-session-require-preserving-transcript.txt"
PROBE_LOG="$WORK_DIR/manifest-live-session-require-preserving-probe.txt"
STDIN_FIFO="$WORK_DIR/manifest-live-session-require-preserving-stdin"

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

cat <<EOF
=== manifest-live-session-require-preserving-smoke ===
port:        $PORT
manifest:    $MANIFEST
initial demo: $OLD_DEMO
target demo:  $NEW_DEMO
strategy:    require-preserving
transcript:  $TRANSCRIPT
probe log:   $PROBE_LOG
EOF

if ! command -v ss >/dev/null 2>&1; then
  echo "[smoke] FAIL: 'ss' not found in PATH; marker 6b requires the iproute2 'ss' utility"
  exit 1
fi

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
  --manifest-live-session "$MANIFEST" "$OLD_DEMO" \
  --strategy require-preserving \
  < "$STDIN_FIFO" \
  > "$TRANSCRIPT" 2>&1 &
DEMO_PID=$!

# Open the fifo write-only AFTER backgrounding the session so the
# reader is already attached and this open does not block. Using a
# write-only fd here (vs. an `<>` read-write fd as in the other
# wrappers) is load-bearing: the session shell exits on EOF, and a
# read-write open keeps the kernel-level writer-count != 0 even
# after we `exec 3<&-`, so the read side never sees EOF and the
# wrapper deadlocks on `wait $DEMO_PID`. Write-only lets a single
# `exec 3<&-` cleanly close the only writer and signal EOF.
exec 3>"$STDIN_FIFO"

echo "[smoke] demo PID=$DEMO_PID, port=$PORT"

# Wait for the first interactive prompt.
echo "[smoke] waiting for first prompt (up to 120s)..."
for i in $(seq 1 120); do
  sleep 1
  if grep -q "Type a command" "$TRANSCRIPT" 2>/dev/null; then
    echo "[smoke] first prompt observed at t=${i}s"
    break
  fi
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    echo "[smoke] FAIL: session exited before first prompt"
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

# Pre-reload OSC.
if python3 "$SEND_OSC" --port "$PORT" --address /v0/lpf/0 --value 1800.0 >/dev/null; then
  echo "[smoke] pre-reload OSC sent (/v0/lpf/0 = 1800.0)"
else
  echo "[smoke] FAIL: pre-reload OSC send failed"
  exit 1
fi
sleep 1

# Trigger supervised reload via stdin command.
printf 'demo:%s\n' "$NEW_DEMO" >&3
echo "[smoke] sent 'demo:$NEW_DEMO' (triggers supervised reload)"

# Wait for the supervised outcome line + next prompt.
echo "[smoke] waiting for supervised outcome + next prompt (up to 120s)..."
for i in $(seq 1 120); do
  sleep 1
  if grep -q "supervised outcome: committed" "$TRANSCRIPT" 2>/dev/null; then
    # Wait for the next prompt after the outcome before sending
    # the next command (the prompt comes after the events list).
    if grep -c "Type a command" "$TRANSCRIPT" | grep -q "[2-9]"; then
      echo "[smoke] outcome + next prompt observed at t=${i}s"
      break
    fi
  fi
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    echo "[smoke] FAIL: session exited before second prompt"
    exit 1
  fi
  if [ "$i" -eq 120 ]; then
    echo "[smoke] FAIL: timeout waiting for supervised outcome + next prompt"
    exit 1
  fi
done

# Post-reload OSC against the new manifest target.
if python3 "$SEND_OSC" --port "$PORT" --address /v0/lpf/0 --value 900.0 >/dev/null; then
  echo "[smoke] post-reload OSC sent (/v0/lpf/0 = 900.0)"
else
  echo "[smoke] FAIL: post-reload OSC send failed"
  exit 1
fi
sleep 1

# Trigger a status snapshot (empty line) so the transcript
# records the post-reload ingress on the new demo.
printf '\n' >&3
echo "[smoke] sent <Enter> (triggers status snapshot)"

# Wait for the status snapshot to land in the transcript.
echo "[smoke] waiting for status snapshot (up to 60s)..."
for i in $(seq 1 60); do
  sleep 1
  if grep -q "current plan demo: $NEW_DEMO" "$TRANSCRIPT" 2>/dev/null; then
    echo "[smoke] status snapshot observed at t=${i}s"
    break
  fi
  if ! kill -0 "$DEMO_PID" 2>/dev/null; then
    echo "[smoke] FAIL: session exited before status snapshot"
    exit 1
  fi
  if [ "$i" -eq 60 ]; then
    echo "[smoke] FAIL: timeout waiting for status snapshot"
    exit 1
  fi
done

# Close stdin (EOF) to exit the session.
exec 3<&-
echo "[smoke] closed stdin (EOF triggers clean exit)"

wait "$DEMO_PID"
DEMO_EXIT=$?
echo "[smoke] session exit=$DEMO_EXIT" | tee -a "$PROBE_LOG"

sleep 1

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

# Marker checks.
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

check_marker "1.  supervised require-preserving session route" \
  "$TRANSCRIPT" "route:         supervised (require-preserving; reloadSupervised + HostStackFactory)"
check_marker "2a. audio running" \
  "$TRANSCRIPT" "audio running: yes"
check_marker "2b. OSC ingress bound on configured port" \
  "$TRANSCRIPT" "oscPort=$PORT"
check_marker "3.  pre-reload OSC accept (value=1800.0)" \
  "$TRANSCRIPT" "value=1800.0"
check_marker "4a. supervised outcome committed" \
  "$TRANSCRIPT" "supervised outcome: committed (new plan installed)"
check_marker "4b. preserving phase started" \
  "$TRANSCRIPT" "preserving phase started"
check_marker "4c. preserving phase committed" \
  "$TRANSCRIPT" "preserving phase committed"
check_absent_marker "4d. no stopped-audio phase (no fallback composition)" \
  "$TRANSCRIPT" "stopped-audio phase"
check_marker "5a. post-reload status shows current plan = new demo" \
  "$TRANSCRIPT" "current plan demo: $NEW_DEMO"
check_marker "5b. post-reload OSC accept (value=900.0)" \
  "$TRANSCRIPT" "value=900.0"
check_marker "6a. session exit 0" \
  "$PROBE_LOG" "session exit=0"
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
