////////////////////////////////////////////////////////////////////////////
// mayhem/kat/kat_probe.c — known-answer test for adpcm-lib's decoder.
//
// mayhem/test.sh's behavioral oracle. Decodes two fixed, hand-built ADPCM
// blocks (mono/4-bit and stereo/3-bit, exercising both the bps==4 fast path
// and the generic bit-packed path in adpcm-lib.c) and asserts the EXACT PCM
// sample values produced. Decode is pure integer arithmetic (no floating
// point anywhere on this path — see adpcm-lib.c), so these expected values
// are bit-exact and reproducible on any compiler/platform/optimization
// level; they were captured from a real run of this same code (not
// invented) — see mayhem/kat/README.md for how.
//
// Exits 0 iff BOTH known-answer checks pass exactly; exits 1 and prints a
// diagnostic otherwise. Built with the project's NORMAL (unsanitized) flags
// as part of the oracle build, so a program neutered to exit(0) immediately
// fails these assertions (nothing gets decoded/printed/compared).
////////////////////////////////////////////////////////////////////////////

#include <stdio.h>
#include <stdint.h>

#include "adpcm-lib.h"

static int check(const char *name, const int16_t *actual, const int16_t *expected, int n) {
    int i, fails = 0;

    for (i = 0; i < n; i++) {
        if (actual[i] != expected[i]) {
            fprintf(stderr, "KAT %s: sample %d mismatch: got %d, want %d\n", name, i, actual[i], expected[i]);
            fails++;
        }
    }

    if (fails) {
        fprintf(stderr, "KAT %s: FAIL (%d/%d samples wrong)\n", name, fails, n);
        return 0;
    }

    fprintf(stderr, "KAT %s: PASS (%d samples, all exact)\n", name, n);
    return 1;
}

int main(void) {
    int ok = 1;

    // KAT1: mono, 4-bit IMA-ADPCM (adpcm_decode_block fast path).
    // header: sample=16, index=42, reserved=0; then 8 bytes of packed nibbles.
    {
        static const uint8_t in1[] = {
            0x10, 0x00, 0x2A, 0x00,
            0x93, 0x5C, 0x71, 0xE4, 0x0F, 0x8A, 0x36, 0xD2
        };
        static const int16_t expected1[] = {
            16, 373, 235, -144, 417, 640, 1660, 2971, 679,
            -4005, -3336, -6379, -6932, -390, 5850, 9902, 1799
        };
        int16_t out1[32];
        int n1 = adpcm_decode_block_ex(out1, in1, sizeof(in1), 1, 4);

        if (n1 != 17) {
            fprintf(stderr, "KAT 1(mono,4bit): FAIL (expected 17 samples, got %d)\n", n1);
            ok = 0;
        } else {
            ok &= check("1(mono,4bit)", out1, expected1, 17);
        }
    }

    // KAT2: stereo, 3-bit ADPCM (generic bit-packed decode path).
    // header: ch0 sample=0 index=5; ch1 sample=-1 index=10; then packed data.
    {
        static const uint8_t in2[] = {
            0x00, 0x00, 0x05, 0x00,
            0xFF, 0xFF, 0x0A, 0x00,
            0x11, 0x22, 0x33, 0x44,
            0x55, 0x66, 0x77, 0x88
        };
        // interleaved L,R,L,R,... (11 composite samples => 22 int16s)
        static const int16_t expected2[] = {
            0, -1, 9, -14, 22, 7, 25, 20, 32, 49, 44,
            23, 31, -5, 28, -23, 35, 16, 33, 23, 35, 41
        };
        int16_t out2[64];
        int n2 = adpcm_decode_block_ex(out2, in2, sizeof(in2), 2, 3);

        if (n2 != 11) {
            fprintf(stderr, "KAT 2(stereo,3bit): FAIL (expected 11 composite samples, got %d)\n", n2);
            ok = 0;
        } else {
            ok &= check("2(stereo,3bit)", out2, expected2, 22);
        }
    }

    return ok ? 0 : 1;
}
