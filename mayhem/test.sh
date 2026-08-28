#!/usr/bin/env bash
#
# mayhem/test.sh — RUN adpcm-xq's functional oracle (already built by mayhem/build.sh).
# exit 0 = pass.
#
# adpcm-xq ships NO upstream test suite (verified: no tests/, no CI test target, no
# fixtures — just CMakeLists.txt + a CLI + the library). So this is a self-authored
# KNOWN-ANSWER oracle (the second option in the porting brief's §4), built from THREE
# unconditional assertions against fixed inputs -> exact expected values:
#
#   1+2. mayhem/kat/kat_probe.c: decodes two fixed, hand-built ADPCM blocks (mono/4-bit
#        and stereo/3-bit — covering both the bps==4 fast path and the generic
#        bit-packed path in adpcm-lib.c) and asserts the EXACT PCM sample sequence.
#        Decode is pure integer arithmetic (no floating point anywhere on this path),
#        so the expected values are bit-exact and reproducible on any
#        compiler/platform/optimization level.
#   3.   The REAL, dynamically-linked CLI binary ($SRC/build-oracle/adpcm-xq) decodes a
#        fixed, committed ADPCM WAV fixture (mayhem/kat/encoded.wav) and the resulting
#        PCM WAV's sha256 is asserted against a golden hash captured from a real run of
#        this exact code. This exercises WAV parsing + CLI argument handling + the
#        decode-to-file path, not just the library call.
#
# All three checks run through code the sabotage/anti-reward-hack neuter (LD_PRELOAD
# _exit(0) on every non-system executable) directly defeats: kat_probe never gets to
# print/compare, and the CLI never writes the decoded WAV — so a neutered program FAILS
# this oracle, satisfying SPEC §6.3.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0
FAILED=0

# ---- Checks 1+2: kat_probe (unconditional — a missing binary is a FAILURE, never skip) ----
if [ ! -x /mayhem/kat_probe ]; then
  echo "test.sh: /mayhem/kat_probe missing — build.sh should have produced it" >&2
  emit_ctrf "adpcm-xq-kat" 0 3
  exit 1
fi

KAT_OUT="$(/mayhem/kat_probe 2>&1)"
KAT_RC=$?
echo "$KAT_OUT"

kat_pass=$(printf '%s\n' "$KAT_OUT" | grep -c '^KAT [0-9](.*): PASS' || true)
kat_fail=$(printf '%s\n' "$KAT_OUT" | grep -c '^KAT [0-9](.*): FAIL' || true)
PASSED=$((PASSED + kat_pass))
FAILED=$((FAILED + kat_fail))

# kat_probe always emits exactly 2 "KAT N(...): PASS|FAIL" lines on a normal run (one
# per known-answer check) — if fewer than 2 total lines appeared (crash, or the neuter
# shim's _exit(0) firing before either check runs), unconditionally count the missing
# ones as failures rather than silently skipping them.
kat_total=$((kat_pass + kat_fail))
if [ "$kat_total" -lt 2 ]; then
  missing=$((2 - kat_total))
  echo "test.sh: kat_probe (exit $KAT_RC) only reported $kat_total/2 known-answer checks" >&2
  FAILED=$((FAILED + missing))
fi

# ---- Check 3: real CLI decode of a fixed, committed ADPCM WAV fixture ----
CLI="$SRC/build-oracle/adpcm-xq"
FIXTURE="$SRC/mayhem/kat/encoded.wav"
OUT="/tmp/adpcm-xq-test-decoded.wav"
EXPECTED_SHA256="356a2cc25ec40558eae70c044201084b28927d570beb37a7d6fe0fd8016e0272"

if [ ! -x "$CLI" ]; then
  echo "test.sh: $CLI missing — build.sh should have produced it" >&2
  FAILED=$((FAILED + 1))
elif [ ! -f "$FIXTURE" ]; then
  echo "test.sh: $FIXTURE missing" >&2
  FAILED=$((FAILED + 1))
else
  rm -f "$OUT"
  "$CLI" -y -d "$FIXTURE" "$OUT" >/tmp/adpcm-xq-cli.log 2>&1
  ACTUAL_SHA256="$(sha256sum "$OUT" 2>/dev/null | awk '{print $1}')"

  if [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ]; then
    echo "KAT 3(cli-decode): PASS (sha256 of decoded PCM matches golden $EXPECTED_SHA256)"
    PASSED=$((PASSED + 1))
  else
    echo "KAT 3(cli-decode): FAIL (sha256 got '${ACTUAL_SHA256:-<missing>}', want $EXPECTED_SHA256)" >&2
    cat /tmp/adpcm-xq-cli.log >&2
    FAILED=$((FAILED + 1))
  fi
fi

emit_ctrf "adpcm-xq-kat" "$PASSED" "$FAILED"
