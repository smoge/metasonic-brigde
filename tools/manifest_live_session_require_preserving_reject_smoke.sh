#!/usr/bin/env bash
#
# Opt-in operator smoke for the supervised
# --manifest-live-session (require-preserving) /reject/ branch.
#
# Sibling of tools/manifest_live_session_require_preserving_smoke.sh.
# The happy-path wrapper drives a fixture where preserving COMMITS;
# this one drives the reject-preserving-delay fixture where
# preserving REJECTS, exercising the
# 'SupervisedReloadRequestRejected' branch of the live-session
# shell end-to-end on real PortAudio + real OSC.
#
# Why this wrapper exists:
#
# The 2026-05-21-a reject-path operator-pressure pass surfaced a
# 13 KB Show-derived cause-line dump that buried the resource
# timeline below the fold; commit 13f3a8e fixed it with a compact
# kebab renderer ('renderPreservingHostStackIssueTag' etc.) and
# eleven F-1 leak guards in AppManifestLiveReloadDemoRender. This
# wrapper pins the resulting compact operator narrative so a
# future refactor of the cause-line render path cannot silently
# regress the readability without breaking this smoke. (Deferred
# until 13f3a8e landed for exactly that reason.)
#
# This script is intentionally NOT a default CI gate. It opens
# real PortAudio and binds a real UDP socket; it must run on a
# host with a working audio backend (ALSA / PipeWire / a real
# device, etc.). Default CI gates live in `just check-offline`
# and stay deterministic / device-free.
#
# What this smoke does:
#
#   1. Confirms the configured UDP port is currently free.
#   2. Launches `metasonic-bridge --manifest-live-session
#      MANIFEST OLD_DEMO --strategy require-preserving` against
#      the reject-preserving-delay fixture, with stdin from a
#      fifo so the wrapper can drive the interactive command
#      loop. The fixture's voice template carries a KDelay
#      ('PreserveUnsupported') node, so any preserving hot-swap
#      with the voice live is rejected.
#   3. Waits for the first "Type a command" prompt, injects an
#      OSC write to /v0/lpf/0 (proves the auto-started voice is
#      live and ingress is wired), then sends a `demo:NEW_KEY`
#      command to trigger the supervised reload.
#   4. Waits for the "supervised outcome: request-rejected"
#      line and the next "Type a command" prompt, injects a
#      second OSC write to /v0/lpf/0 (proves ingress survives
#      the rejection), then sends an empty line for a status
#      snapshot (so the transcript records that current plan is
#      still OLD_DEMO, not NEW_DEMO).
#   5. Closes stdin (Ctrl-D equivalent) to exit the session.
#   6. Waits for exit, then runs two post-exit probes against
#      the OSC port: ss snapshot + active bind probe.
#
# Marker checks at the end verify the request-rejected branch:
# the four reload-event lines (preserving phase started,
# resume-old-ingress started/succeeded, preserving phase
# rejected), the compact 'cause:' line that 13f3a8e produces,
# the three resource-timeline lines (stack stayed live, no
# supervisor rebuild, serving OLD plan), the post-reject status
# snapshot shows current plan is still OLD_DEMO, and the
# pre/post OSC writes both land. Plus three NEGATIVE markers:
#
#   * no "supervised outcome: committed" — would mean the swap
#     committed instead of rejecting (fixture broken or the
#     PreserveUnsupported classification regressed);
#   * no "preserving phase committed" — same;
#   * no "stopped-audio phase" — require-preserving never
#     composes with stopped-audio fallback;
#   * no "TemplateGraph" / "RuntimeNode" substring — F-1 leak
#     guard at runtime, pairs with the unit-level leak tests in
#     AppManifestLiveReloadDemoRender.
#
# Configurable env vars (also accessible via `just
# manifest-live-session-require-preserving-reject-smoke port=N`):
#
#   PORT       UDP port for OSC ingress (default 17005).
#              17005 instead of 17001/.../17004 so this smoke
#              does not collide with the other live-session /
#              live-reload-demo smokes on those ports.
#   MANIFEST   Manifest fixture path (default
#              examples/manifests/reject-preserving-delay.json).
#   OLD_DEMO   Initial demo key
#              (default reject-preserving-delay-dark).
#   NEW_DEMO   Target demo key fed via `demo:NEW_DEMO`
#              (default reject-preserving-delay-bright).
#   WORK_DIR   Where to put transcript + probe-log artifacts
#              (default $TMPDIR or /tmp).
#
# Exit codes:
#   0  every acceptance marker observed, every negative marker
#      held
#   1  pre-flight failed, the session did not produce the
#      expected output within the per-prompt timeout, the
#      post-exit probes failed, at least one positive marker
#      was missing, or any negative marker was violated

set -u

PORT="${PORT:-17005}"
MANIFEST="${MANIFEST:-examples/manifests/reject-preserving-delay.json}"
OLD_DEMO="${OLD_DEMO:-reject-preserving-delay-dark}"
NEW_DEMO="${NEW_DEMO:-reject-preserving-delay-bright}"

WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}}"
TRANSCRIPT="$WORK_DIR/manifest-live-session-require-preserving-reject-transcript.txt"
PROBE_LOG="$WORK_DIR/manifest-live-session-require-preserving-reject-probe.txt"
STDIN_FIFO="$WORK_DIR/manifest-live-session-require-preserving-reject-stdin"

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
=== manifest-live-session-require-preserving-reject-smoke ===
port:         $PORT
manifest:     $MANIFEST
initial demo: $OLD_DEMO
target demo:  $NEW_DEMO
strategy:     require-preserving (reject branch)
transcript:   $TRANSCRIPT
probe log:    $PROBE_LOG
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
# reader is already attached and this open does not block. Same
# load-bearing detail as the happy-path wrapper: write-only fd
# lets a single `exec 3<&-` cleanly close the only writer and
# signal EOF; a read-write open would deadlock on `wait`.
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

# Pre-reload OSC: proves the auto-started voice is live and OSC
# ingress is wired.
if python3 "$SEND_OSC" --port "$PORT" --address /v0/lpf/0 --value 1800.0 >/dev/null; then
  echo "[smoke] pre-reload OSC sent (/v0/lpf/0 = 1800.0)"
else
  echo "[smoke] FAIL: pre-reload OSC send failed"
  exit 1
fi
sleep 1

# Trigger the supervised reload — this is the one we expect to
# reject (the fixture's KDelay voice is preserve-unsupported).
printf 'demo:%s\n' "$NEW_DEMO" >&3
echo "[smoke] sent 'demo:$NEW_DEMO' (expected: request-rejected)"

# Wait for the supervised outcome line + next prompt.
echo "[smoke] waiting for supervised request-rejected outcome + next prompt (up to 120s)..."
for i in $(seq 1 120); do
  sleep 1
  if grep -q "supervised outcome: request-rejected" "$TRANSCRIPT" 2>/dev/null; then
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
    echo "[smoke] FAIL: timeout waiting for supervised request-rejected outcome + next prompt"
    exit 1
  fi
done

# Post-reject OSC: proves ingress survives the rejection — the
# old voice and OSC binding are still alive on the OLD demo.
if python3 "$SEND_OSC" --port "$PORT" --address /v0/lpf/0 --value 900.0 >/dev/null; then
  echo "[smoke] post-reject OSC sent (/v0/lpf/0 = 900.0)"
else
  echo "[smoke] FAIL: post-reject OSC send failed"
  exit 1
fi
sleep 1

# Trigger a status snapshot (empty line) so the transcript
# records that current plan is STILL the OLD demo, not the new.
printf '\n' >&3
echo "[smoke] sent <Enter> (triggers status snapshot)"

echo "[smoke] waiting for status snapshot (up to 60s)..."
for i in $(seq 1 60); do
  sleep 1
  if grep -q "current plan demo: $OLD_DEMO" "$TRANSCRIPT" 2>/dev/null; then
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
check_marker "3.  pre-reload OSC accept (/v0/lpf/0 value=1800)" \
  "$TRANSCRIPT" 'osc accept: /v0/lpf/0 name="cutoff" value=1800'
check_marker "4a. supervised outcome request-rejected" \
  "$TRANSCRIPT" "supervised outcome: request-rejected (stack still on previous plan)"
check_marker "4b. preserving phase started" \
  "$TRANSCRIPT" "preserving phase started"
check_marker "4c. resume old ingress: started" \
  "$TRANSCRIPT" "resume old ingress: started"
check_marker "4d. resume old ingress: succeeded" \
  "$TRANSCRIPT" "resume old ingress: succeeded"
check_marker "4e. preserving phase rejected (old owner still installed)" \
  "$TRANSCRIPT" "preserving phase rejected: reload-rejected (old owner still installed)"
check_marker "4f. compact cause line (in-window: reload-rejected)" \
  "$TRANSCRIPT" "cause: in-window: reload-rejected (old owner still installed)"
check_marker "4g. resource timeline: request rejected; stack stayed live" \
  "$TRANSCRIPT" "request rejected; stack stayed live"
check_marker "4h. resource timeline: no supervisor rebuild" \
  "$TRANSCRIPT" "no supervisor rebuild"
check_marker "4i. resource timeline: serving plan still OLD demo" \
  "$TRANSCRIPT" "serving plan: $OLD_DEMO"
check_absent_marker "4j. no supervised committed outcome (would mean fixture broken / classification regressed)" \
  "$TRANSCRIPT" "supervised outcome: committed"
check_absent_marker "4k. no preserving phase committed (would contradict the rejection)" \
  "$TRANSCRIPT" "preserving phase committed"
check_absent_marker "4l. no stopped-audio phase (require-preserving never composes with fallback)" \
  "$TRANSCRIPT" "stopped-audio phase"
check_absent_marker "4m. no TemplateGraph leak in transcript (F-1 runtime guard)" \
  "$TRANSCRIPT" "TemplateGraph"
check_absent_marker "4n. no RuntimeNode leak in transcript (F-1 runtime guard)" \
  "$TRANSCRIPT" "RuntimeNode"
check_marker "5a. post-reject status shows current plan STILL OLD demo" \
  "$TRANSCRIPT" "current plan demo: $OLD_DEMO"
check_marker "5b. post-reject OSC accept (/v0/lpf/0 value=900)" \
  "$TRANSCRIPT" 'osc accept: /v0/lpf/0 name="cutoff" value=900'
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
