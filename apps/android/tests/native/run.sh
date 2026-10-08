#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/movieclaw-native-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
compiler="${CXX:-g++}"
flags=(-std=c++17 -g -pthread -fno-omit-frame-pointer -fsanitize=address,undefined -I android/tests/native/stubs -I android/app/src/main/cpp/mpv_include)
for name in mpv_lifecycle iso_lifecycle; do
    "$compiler" "${flags[@]}" "android/tests/native/${name}_test.cpp" -ldl -o "$build_dir/$name"
    "$build_dir/$name"
done
