#!/bin/sh
set -eu
native_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/call-audio-dsp-checks.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
"${CC:-clang}" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread ${DSP_SANITIZER_FLAGS:-} \
  -I "$native_root/Sources/CallAudioDSP/include" \
  "$native_root/Sources/CallAudioDSP/CallAudioDSP.c" \
  "$native_root/Tests/CallAudioDSPChecks/checks.c" \
  -o "$build_dir/checks"
"$build_dir/checks"
