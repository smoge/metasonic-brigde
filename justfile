set shell := ["bash", "-cu"]

cpp_build_dir := "build-cpp"
cpp_exe := "rt_graph_smoke"
cpp_live_test_regex := "start_audio.*stop_audio|audio start/stop cycle|clear during a running audio stream|rebuild after clear with active stream|destroy after start_audio"

default:
    just --list

stack-build:
    stack build

# AddressSanitizer + UBSan diagnostic build, isolated from the
# default .stack-work cache. Switching the asan flag in and out of
# the same .stack-work corrupted the link step: stale ASan-
# instrumented cxx-source .o files survived into a later
# unsanitized link and surfaced as undefined __asan_* references.
# Pinning the diagnostic lane to .stack-work-asan keeps both
# caches consistent and removes the need for stack clean between
# runs. .stack-work-asan/ is ignored like the default .stack-work/
# cache.
stack-build-asan:
    stack build --work-dir .stack-work-asan --flag metasonic-bridge:asan

metasonic name="":
    stack exec -- metasonic-bridge {{name}}

metasonic-inspect name="":
    stack exec -- metasonic-bridge --inspect {{name}}

metasonic-inspect-only name="":
    stack exec -- metasonic-bridge --inspect-only {{name}}

metasonic-help:
    stack exec -- metasonic-bridge --help

midi-list:
    stack exec -- metasonic-bridge --midi-list

plugin-list:
    stack exec -- metasonic-bridge --plugin-list

snapshot-check:
    stack exec -- metasonic-bridge --snapshot-check

midi-poly:
    stack exec -- metasonic-bridge midi-poly

midi-poly-device device:
    stack exec -- metasonic-bridge --midi-device {{device}} midi-poly

session-midi-smoke seconds="10":
    stack exec -- metasonic-bridge --session-midi-smoke {{seconds}}

session-midi-smoke-device device seconds="10":
    stack exec -- metasonic-bridge --midi-device {{device}} --session-midi-smoke {{seconds}}

session-osc-arbitration-smoke seconds="10" port="7001":
    stack exec -- metasonic-bridge --session-osc-port {{port}} --session-osc-arbitration-smoke {{seconds}}

session-osc-arbitration-send-claimed value port="7001":
    python3 tools/send_osc.py --port {{port}} --address /v0/lpf/0 --value {{value}}

session-osc-arbitration-send-allowed value port="7001":
    python3 tools/send_osc.py --port {{port}} --address /v1/lpf/0 --value {{value}}

osc-listen port="7000":
    stack exec -- metasonic-bridge --osc-listen {{port}}

osc-send value port="7000" host="127.0.0.1" address="/v0/outgain/0":
    python3 tools/send_osc.py --host {{host}} --port {{port}} --address {{address}} --value {{value}}

osc-tool-test:
    python3 tools/test_send_osc.py

stack-test:
    stack test

# Explicit serial-default escape hatch. Tasty's default parallelism
# (numCapabilities) is normally fine after the lock-narrowing work
# in 5a66054 + the MIDI lifetime fix in e5ed3d9 + ASan validation
# (see notes/2026-05-17-c-default-test-lane-relaxed.md). Use this
# recipe if you want to bisect a new heap-corruption signal against
# parallelism specifically, or as the safe lane when adding tests
# that drive process-global C state the remaining FFI locks do not
# cover (PortAudio lifecycle, ScheduleWorkerPool teardown).
stack-test-serial:
    stack test --test-arguments '--num-threads=1'

# Run the full suite under AddressSanitizer + UBSan with parallel
# Tasty enabled. Used as the diagnostic lane against the two
# still-unproven FFI-lock suspects (PortAudio lifecycle,
# ScheduleWorkerPool teardown). detect_leaks=0 keeps GHC's GC
# retention from generating noise; fast_unwind_on_malloc=0 trades
# speed for accurate allocation-site stacks at corruption time.
# Uses the isolated .stack-work-asan cache so it never contaminates
# the default build (see stack-build-asan for the rationale).
stack-test-parallel-asan:
    ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:fast_unwind_on_malloc=0:print_stacktrace=1 \
    UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
    stack test --work-dir .stack-work-asan --flag metasonic-bridge:asan

notes-html:
    ./tools/render_notes_html.sh

cpp-configure:
    cmake -S . -B {{cpp_build_dir}} -G Ninja \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

cpp-build: cpp-configure
    cmake --build {{cpp_build_dir}}

cpp-lsp: cpp-configure
    test -f {{cpp_build_dir}}/compile_commands.json
    ln -sf {{cpp_build_dir}}/compile_commands.json compile_commands.json

cpp-run: cpp-build
    ./{{cpp_build_dir}}/{{cpp_exe}}

cpp-test: cpp-build
    ctest --test-dir {{cpp_build_dir}} --output-on-failure

cpp-test-offline: cpp-build
    ctest --test-dir {{cpp_build_dir}} --output-on-failure -E "{{cpp_live_test_regex}}"

cpp-test-live: cpp-build
    ctest --test-dir {{cpp_build_dir}} --output-on-failure -R "{{cpp_live_test_regex}}"

check-offline:
    git diff --check
    just stack-test
    just cpp-test-offline

# Opt-in live operator smoke for the supervised
# --manifest-live-reload-demo stopped-audio-only route. Drives
# the audible reload end-to-end against the committed
# preserve-cutoff fixture, injects OSC pre- and post-reload,
# runs post-exit `ss` + active Python bind probes, and verifies
# the six acceptance markers from
# notes/2026-05-19-b-manifest-host-reload-smoke-runbook.md.
#
# This is a LIVE / DEVICE smoke. It opens real PortAudio and
# binds a real UDP socket. It is INTENTIONALLY NOT a member of
# `check-offline` or any default CI gate — default gates stay
# deterministic and device-free. Run this manually on a host
# with a working audio backend when verifying the supervised
# stopped-audio route (e.g. as the no-regression confirmation
# run after touching shared supervisor / adapter code, paired
# with `manifest-supervised-try-preserving-live-smoke` for the
# try-preserving route).
#
# Default port is 17001 to avoid colliding with the everyday
# 7001 workspace if a smoke gets stuck. Override with
# `just manifest-supervised-live-smoke port=N`.
#
# Other parameters (manifest fixture, old/new demo keys, work
# dir for artifacts) are env-var configurable in the wrapper
# script; see tools/manifest_supervised_live_smoke.sh.
manifest-supervised-live-smoke port="17001": stack-build
    PORT={{port}} ./tools/manifest_supervised_live_smoke.sh

# Opt-in live operator smoke for the supervised
# --manifest-live-reload-demo try-preserving route. Drives the
# audible reload end-to-end against the committed
# preserve-cutoff fixture, where preserving commits without
# stopped-audio fallback. Injects OSC pre- and post-reload,
# runs post-exit `ss` + active Python bind probes, and verifies
# the try-preserving acceptance markers.
#
# Same shape as `manifest-supervised-live-smoke`, but exercises
# the supervised stack with `realTryPreservingHostStackOps`
# (composes preserving + stopped-audio fallback) instead of
# `realStoppedAudioHostStackOps`. Marker checks swap the two
# stopped-audio-phase markers for the corresponding preserving-
# phase markers; the route-line marker pins the distinct route
# rendering.
#
# Like the stopped-audio counterpart, this is a LIVE / DEVICE
# smoke and is INTENTIONALLY NOT a member of `check-offline` or
# any default CI gate.
#
# Default port is 17002 (vs 17001 for stopped-audio) so the two
# smokes do not collide if run in sequence and a stale post-exit
# state on one port does not affect the other. Override with
# `just manifest-supervised-try-preserving-live-smoke port=N`.
#
# Other parameters (manifest fixture, old/new demo keys, work
# dir for artifacts) are env-var configurable in the wrapper
# script; see tools/manifest_supervised_try_preserving_live_smoke.sh.
manifest-supervised-try-preserving-live-smoke port="17002": stack-build
    PORT={{port}} ./tools/manifest_supervised_try_preserving_live_smoke.sh

# Opt-in live operator smoke for the supervised
# --manifest-live-reload-demo require-preserving route. Drives
# the audible reload end-to-end against the committed
# preserve-cutoff fixture (preserving commits on it, same as the
# try-preserving smoke). Injects OSC pre- and post-reload, runs
# post-exit `ss` + active Python bind probes, and verifies the
# require-preserving acceptance markers — including a load-
# bearing negative marker that no "stopped-audio phase" lines
# appear in the transcript, proving the require-preserving
# supervised path does not compose with stopped-audio fallback.
#
# Same shape as the stopped-audio and try-preserving smokes,
# but exercises the supervised stack with
# `realPreservingHostStackOps` (preserving-only) instead of
# `realStoppedAudioHostStackOps` or
# `realTryPreservingHostStackOps`.
#
# Like the other two counterparts, this is a LIVE / DEVICE
# smoke and is INTENTIONALLY NOT a member of `check-offline` or
# any default CI gate.
#
# Default port is 17003 (vs 17001 for stopped-audio and 17002
# for try-preserving) so the three smokes do not collide if run
# in sequence and a stale post-exit state on one port does not
# affect the others. Override with
# `just manifest-supervised-require-preserving-live-smoke port=N`.
#
# Other parameters (manifest fixture, old/new demo keys, work
# dir for artifacts) are env-var configurable in the wrapper
# script; see tools/manifest_supervised_require_preserving_live_smoke.sh.
manifest-supervised-require-preserving-live-smoke port="17003": stack-build
    PORT={{port}} ./tools/manifest_supervised_require_preserving_live_smoke.sh

# Opt-in live operator smoke for the Phase 8 v0 manifest-backed
# live session shell, driven against the require-preserving
# supervised route. Distinct from the three live-reload-demo
# wrappers above: this exercises the open-ended session shell
# (`--manifest-live-session MANIFEST DEMO --strategy
# require-preserving`) instead of the two-shot OLD/NEW
# live-reload demo. Same marker shape (audio + ingress +
# pre/post-reload OSC + clean exit + bind probes) plus a
# session-specific status-snapshot marker that exercises the
# stdin <Enter> = status command, and the same load-bearing
# negative marker (no "stopped-audio phase" lines) the
# require-preserving demo wrapper carries.
#
# Like the other live-audio wrappers, this is a LIVE / DEVICE
# smoke and is INTENTIONALLY NOT a member of `check-offline` or
# any default CI gate.
#
# Default port is 17004 (vs 17001-17003 for the three demo
# wrappers) so the four smokes do not collide if run in
# sequence and a stale post-exit state on one port does not
# affect the others. Override with
# `just manifest-live-session-require-preserving-smoke port=N`.
#
# Other parameters (manifest fixture, initial/target demo keys,
# work dir for artifacts) are env-var configurable in the
# wrapper script; see
# tools/manifest_live_session_require_preserving_smoke.sh.
manifest-live-session-require-preserving-smoke port="17004": stack-build
    PORT={{port}} ./tools/manifest_live_session_require_preserving_smoke.sh

# Live-audio operator smoke for the supervised
# --manifest-live-session (require-preserving) /reject/ branch.
# Sibling of the smoke above. Drives the reject-preserving-smooth
# fixture (KSmooth voice template, preserve-unsupported) so the
# supervised hot-swap rejects instead of committing; pins the
# resulting request-rejected operator narrative end-to-end —
# including the four reload-event lines (preserving started,
# resume-old-ingress started/succeeded, preserving rejected), the
# compact 'cause:' line that 13f3a8e introduced, and the
# resource-timeline section that 5cc1eda introduced. The negative
# markers also pin the F-1 leak guard at runtime: no
# 'TemplateGraph' / 'RuntimeNode' substring in the transcript.
#
# Like the other live-audio wrappers, this is a LIVE / DEVICE
# smoke and is INTENTIONALLY NOT a member of `check-offline` or
# any default CI gate.
#
# Default port is 17005 so this smoke does not collide with the
# four other live wrappers on 17001-17004. Override with
# `just manifest-live-session-require-preserving-reject-smoke port=N`.
#
# Other parameters (manifest fixture, initial/target demo keys,
# work dir for artifacts) are env-var configurable in the
# wrapper script; see
# tools/manifest_live_session_require_preserving_reject_smoke.sh.
manifest-live-session-require-preserving-reject-smoke port="17005": stack-build
    PORT={{port}} ./tools/manifest_live_session_require_preserving_reject_smoke.sh

# §4.B kernel microbench. Configures and builds in a separate
# RelWithDebInfo tree so the numbers aren't dominated by
# libstdc++ assertion overhead from the Debug `cpp-build`.
cpp_bench_dir := "build-cpp-release"

cpp-bench-configure:
    cmake -S . -B {{cpp_bench_dir}} -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DMETASONIC_BUILD_TESTS=OFF

cpp-bench-build: cpp-bench-configure
    cmake --build {{cpp_bench_dir}} --target rt_graph_bench

cpp-bench: cpp-bench-build
    ./{{cpp_bench_dir}}/rt_graph_bench


lsp: cpp-lsp
    stack ide targets >/dev/null

build: stack-build cpp-build

push:
    git push -u bitbucket main
