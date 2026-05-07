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

build: stack-build cpp-build