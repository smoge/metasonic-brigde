set shell := ["bash", "-cu"]

cpp_build_dir := "build-cpp"
cpp_exe := "rt_graph_smoke"

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

stack-test:
    stack test

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