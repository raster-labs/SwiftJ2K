R3 independent HT refinement fixtures

These Apache-2.0 synthetic-input fixtures were generated with installed,
unmodified Kakadu 8.4.1. The retained manifest records full commands, binary
hashes, source hash, codestream hashes, outputs and logs.

Generation follows ITU-T T.803 (02/2024) C.1.10: rate-truncate reversibly
transformed Part1 data, then transcode to HT preserving truncation boundaries.
Input is ../Lossless/g16_64x64_random.pgm, 64x64 unsigned16, zero DWT levels,
8x8 code-blocks, one layer, rates4/8/12 bits per pixel. Kakadu's Part1 and HT
decoded sample arrays match exactly. These are lossy data despite a reversible
transform; they are not expected to reproduce all original input samples.

CodexR3IndependentHTTests inspects actual nonempty refinement segments:
rate4:59/64 blocks; rate8:64/64; rate12:64/64. Both SigProp-only and
SigProp+MagRef segments occur. With matching r=1/2 coefficient reconstruction,
the shared HT decoder matches all4096 independent samples in every fixture.
Removing refinement changes1287/2444/3969 reconstructed samples respectively.
The public reversible volume path chooses r=0 and is separately checked for
decode/transcode sample consistency. T.800 E.1 permits this reconstruction
parameter choice. The original r0-versus-Kakadu comparison failed and remains
in the takeover evidence; that comparison was an oracle-policy mismatch.

The test changes only dimensional main-header syntax to depth1 and refuses
nonzero DWT levels. Part1 and Part10 reversible axis order differs, so an
arbitrary nonzero-DWT dimensional lift is not an exact-sample oracle.
These fixtures establish narrow independent HT-core refinement evidence.
They do not establish an independent Part10 decoder, direct combined Part10+15
interoperability, direct full38 Part2 output, or multiple active HT sets.

Reproduce into a new directory:
python3 Scripts/generate-r3-ht-fixtures.py refinement --output /tmp/new-r3-ht
Use --tools to identify a Kakadu executable directory if it is not on PATH.

Primary references:
https://www.itu.int/rec/dologin_pub.asp?id=T-REC-T.803-202402-I%21%21PDF-E&lang=e&type=items
https://www.itu.int/rec/dologin_pub.asp?id=T-REC-T.814-201906-I%21%21PDF-E&lang=e&type=items
https://www.itu.int/rec/dologin_pub.asp?id=T-REC-T.800-201511-S%21%21PDF-E&lang=e&type=items
