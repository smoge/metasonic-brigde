set shell := ["bash", "-cu"]

cpp_build_dir := "build-cpp"
cpp_exe := "rt_graph_smoke"
cpp_live_test_regex := "start_audio.*stop_audio|audio start/stop cycle|clear during a running audio stream|rebuild after clear with active stream|destroy after start_audio"

default:
    just --list

stack-build:
    stack build

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

osc-send value port="7000" host="127.0.0.1":
    python3 tools/send_osc.py --host {{host}} --port {{port}} --value {{value}}

stack-test:
    stack test

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
