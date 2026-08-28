////////////////////////////////////////////////////////////////////////////
// mayhem/fuzz_decode.c — libFuzzer harness for adpcm-xq's IMA-ADPCM decoder.
//
// Fuzzes adpcm_decode_block_ex() (adpcm-lib.c), the core decode entry point
// used by the CLI when converting a compressed ADPCM WAV block back to PCM.
// Pure in-process, byte-buffer-only: no file I/O, no network, no absolute
// paths — takes bytes straight from libFuzzer and decodes them.
//
// Input layout (fuzzer-controlled bytes only):
//   byte 0      : low bit selects channel count (0 => mono, 1 => stereo)
//   byte 1      : selects bits-per-sample in {2,3,4,5} (mod 4, offset by 2)
//   byte 2..    : the ADPCM block itself (per-channel 4-byte header +
//                 packed nibble/tribit/pentabit data), handed unmodified
//                 to adpcm_decode_block_ex()
//
// adpcm_decode_block_ex() sanitizes the header (index in [0,88], reserved
// byte must be 0) and internally dispatches to the bps==4 fast path
// (adpcm_decode_block) or the generic bit-packed path (bps in {2,3,5}), so a
// single harness exercises all four decode routines in adpcm-lib.c.
////////////////////////////////////////////////////////////////////////////

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

#include "adpcm-lib.h"

// Cap the amount of work a single exec can do — bounds runtime per input
// without narrowing what the decoder itself is asked to handle (the decode
// loop is a simple bounded walk over inbufsize, so there is no separate
// "hang" precondition to guard here, just a sane upper bound on iterations).
#define MAX_INBUF_SIZE (1 << 16)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 6)
        return 0;

    int channels = (data[0] & 1) ? 2 : 1;
    int bps = 2 + (data[1] % 4);   // 2, 3, 4, or 5

    const uint8_t *inbuf = data + 2;
    size_t inbufsize = size - 2;

    if (inbufsize > MAX_INBUF_SIZE)
        inbufsize = MAX_INBUF_SIZE;

    if (inbufsize < (size_t) channels * 4)
        return 0;

    int max_samples = adpcm_block_size_to_sample_count((int) inbufsize, channels, bps);

    if (max_samples <= 0)
        return 0;

    // Generous margin over the library's own sizing formula (which this
    // mirrors) so a rounding difference between bps paths never overflows.
    size_t outbuf_samples = (size_t) max_samples * (size_t) channels + 64;
    int16_t *outbuf = (int16_t *) malloc(outbuf_samples * sizeof(int16_t));

    if (!outbuf)
        return 0;

    adpcm_decode_block_ex(outbuf, inbuf, inbufsize, channels, bps);

    free(outbuf);
    return 0;
}
