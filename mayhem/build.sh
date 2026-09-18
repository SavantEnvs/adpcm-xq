#!/usr/bin/env bash
#
# mayhem/build.sh — build the adpcm-xq-buggy-mhh-run-16 backport target + oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS         -g -gdwarf-3
#   SRC                 /mayhem (the repo source)
#
# adpcm-xq is a small, upstream-CMake-only C project (adpcm-lib.c + adpcm-dns.c = the
# library, adpcm-xq.c = CLI). The mayhemheroes anchor run (adpcm-xq/adpcm-xq/16) fuzzed the
# CLI BINARY DIRECTLY — `cmd: /adpcm-xq @@ out.wav`, built with plain `gcc *.c -o adpcm-xq -lm`
# (no sanitizers). This backport reproduces the SAME input interface (whole CLI, file-argument
# driven), just built with ASan+UBSan so the same crashers halt loudly instead of silently
# corrupting memory / continuing past UB. Reconstructing the original decode-only libFuzzer
# harness would NOT reproduce these bugs — they are in the CLI's WAV-header arithmetic
# (adpcm-xq.c), never reached by that in-process harness (input-interface caveat, BACKPORT.md).
#
# This build produces:
#   1. /mayhem/adpcm-xq-buggy-mhh-run-16   — sanitized CLI binary (adpcm-xq.c + adpcm-lib.c +
#                                            adpcm-dns.c), the fuzzed target.
#   2. $SRC/build-oracle/adpcm-xq          — the real CLI, built with upstream's own CMake, NORMAL
#                                            (unsanitized) flags — the honest functional oracle.
#   3. /mayhem/kat_probe                   — unsanitized known-answer probe (mayhem/kat/kat_probe.c)
#                                            linked directly against the unsanitized library sources.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"

# -----------------------------------------------------------------------------------
# 1) The backport target: the CLI itself, sanitized. Mayhem drives it exactly like the
#    original harness did (file-argument in, file-argument out), so it needs SanCov
#    instrumentation but no libFuzzer runtime — a plain sanitized native binary. LSan is
#    disabled at build time (mayhem/lsan_off.c, SPEC.md §6.2 item 15) — ASan/UBSan stay
#    fully active, only leak detection is off. The hook is plain C (not lsan_off.cc),
#    so the whole target links via $CC, not $CXX — see mayhem/lsan_off.c for why (a
#    C++-linked binary lost one of the two original crashers).
# -----------------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
    -I"$SRC" "$SRC/adpcm-xq.c" "$SRC/adpcm-lib.c" "$SRC/adpcm-dns.c" \
    "$SRC/mayhem/lsan_off.c" -lm \
    -o /mayhem/adpcm-xq-buggy-mhh-run-16

[ -x /mayhem/adpcm-xq-buggy-mhh-run-16 ] || { echo "adpcm-xq-buggy-mhh-run-16 missing after build" >&2; exit 1; }

# -----------------------------------------------------------------------------------
# 2) Oracle build: upstream's OWN CMake build, NORMAL (unsanitized) flags, a separate
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
# 3) KAT probe (mayhem/kat/kat_probe.c): unsanitized, linked straight against the
#    unsanitized library sources — the known-answer oracle mayhem/test.sh runs first.
# -----------------------------------------------------------------------------------
$CC -O2 -I"$SRC" -o /mayhem/kat_probe \
    "$SRC/mayhem/kat/kat_probe.c" "$SRC/adpcm-lib.c" "$SRC/adpcm-dns.c" -lm

[ -x /mayhem/kat_probe ] || { echo "kat_probe missing after build" >&2; exit 1; }
file /mayhem/kat_probe | grep -q 'dynamically linked' \
    || { echo "kat_probe is not dynamically linked (regression guard tripped)" >&2; exit 1; }

echo "build.sh: OK — adpcm-xq-buggy-mhh-run-16, build-oracle/adpcm-xq, kat_probe all built"
