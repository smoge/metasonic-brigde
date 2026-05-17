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

build: stack-build cpp-build

push:
    git push -u bitbucket main
