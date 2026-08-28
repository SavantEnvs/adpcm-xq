#!/usr/bin/env bash
#
# mayhem/build.sh — build the adpcm-xq fuzz harness + oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS         -g -gdwarf-3
#   SRC                 /mayhem (the repo source)
#
# adpcm-xq is a small, upstream-CMake-only C project (adpcm-lib.c + adpcm-dns.c = the
# library, adpcm-xq.c = CLI). This build produces three artifacts:
#   1. /mayhem/fuzz_decode              — sanitized in-process libFuzzer target over
#                                          adpcm_decode_block_ex() (adpcm-lib.c/adpcm-dns.c
#                                          compiled with -fsanitize=fuzzer-no-link so the
#                                          LIBRARY itself is instrumented, not just the harness TU).
#   2. /mayhem/fuzz_decode-standalone   — same harness linked against $STANDALONE_FUZZ_MAIN
#                                          (one-shot reproducer, no libFuzzer runtime).
#   3. $SRC/build-oracle/adpcm-xq       — the real CLI, built with upstream's own CMake, NORMAL
#                                          (unsanitized) flags — the honest functional oracle.
#   4. /mayhem/kat_probe                — unsanitized known-answer probe (mayhem/kat/kat_probe.c)
#                                          linked directly against the unsanitized library sources.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

WORK="$SRC/mayhem-build"
mkdir -p "$WORK"

# -----------------------------------------------------------------------------------
# 1) Sanitized library objects. -fsanitize=fuzzer-no-link is appended UNCONDITIONALLY
#    (even when $SANITIZER_FLAGS is empty, i.e. the no-sanitizer build) so the library
#    always carries SanCov instrumentation — without this the harness TU is covered but
#    the actual decode logic in adpcm-lib.c/adpcm-dns.c records 0 edges under Mayhem.
# -----------------------------------------------------------------------------------
$CC -c $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
    -I"$SRC" "$SRC/adpcm-lib.c" -o "$WORK/adpcm-lib.sanitized.o"
$CC -c $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
    -I"$SRC" "$SRC/adpcm-dns.c" -o "$WORK/adpcm-dns.sanitized.o"

# -----------------------------------------------------------------------------------
# 2) The libFuzzer harness (fuzz_decode) — in-process, byte-buffer only, no file I/O.
# -----------------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE \
    -I"$SRC" "$SRC/mayhem/fuzz_decode.c" \
    "$WORK/adpcm-lib.sanitized.o" "$WORK/adpcm-dns.sanitized.o" -lm \
    -o /mayhem/fuzz_decode

# -----------------------------------------------------------------------------------
# 3) Standalone (non-fuzzer) reproducer: same harness, LLVM's run-once driver instead
#    of the libFuzzer runtime. One input file, runs once, natural crash, no libFuzzer.
# -----------------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
    "$STANDALONE_FUZZ_MAIN" \
    -I"$SRC" "$SRC/mayhem/fuzz_decode.c" \
    "$WORK/adpcm-lib.sanitized.o" "$WORK/adpcm-dns.sanitized.o" -lm \
    -o /mayhem/fuzz_decode-standalone

# -----------------------------------------------------------------------------------
# 4) Oracle build: upstream's OWN CMake build, NORMAL (unsanitized) flags, a separate
#    tree from the sanitized fuzz build above so both coexist with no clean/stash dance.
#    This is what mayhem/test.sh actually runs against.
# -----------------------------------------------------------------------------------
cmake -S "$SRC" -B "$SRC/build-oracle" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC"
cmake --build "$SRC/build-oracle" -j"$MAYHEM_JOBS"

[ -x "$SRC/build-oracle/adpcm-xq" ] || { echo "oracle CLI binary missing after build" >&2; exit 1; }
file "$SRC/build-oracle/adpcm-xq" | grep -q 'dynamically linked' \
    || { echo "oracle CLI is not dynamically linked (regression guard tripped)" >&2; exit 1; }

# -----------------------------------------------------------------------------------
# 5) KAT probe (mayhem/kat/kat_probe.c): unsanitized, linked straight against the
#    unsanitized library sources — the known-answer oracle mayhem/test.sh runs first.
# -----------------------------------------------------------------------------------
$CC -O2 -I"$SRC" -o /mayhem/kat_probe \
    "$SRC/mayhem/kat/kat_probe.c" "$SRC/adpcm-lib.c" "$SRC/adpcm-dns.c" -lm

[ -x /mayhem/kat_probe ] || { echo "kat_probe missing after build" >&2; exit 1; }
file /mayhem/kat_probe | grep -q 'dynamically linked' \
    || { echo "kat_probe is not dynamically linked (regression guard tripped)" >&2; exit 1; }

echo "build.sh: OK — fuzz_decode, fuzz_decode-standalone, build-oracle/adpcm-xq, kat_probe all built"
