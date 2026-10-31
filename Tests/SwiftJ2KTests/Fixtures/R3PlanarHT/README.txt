R3 independent planar HT fixtures

Synthetic Apache-2.0 source PGM files are in ../Lossless. Unmodified Kakadu8.4.1
encoded these with Clevels0, Clayers3, CorderLRCP, Creversibleyes and CmodesHT.
Commands, independent decoded outputs, source/tool/output hashes and logs are
retained in manifest.json. CodexR3IndependentHTTests verifies exact lossless
samples through a bounded depth1 dimensional-header adaptation with unchanged
packet and entropy bytes; it rejects nonzero-DWT adaptations.

Observed pass/segment data establishes cleanup and leading placeholder coverage
only. Three quality layers do not establish actual SigProp/MagRef or MULTIHT.
Actual refinement fixtures are in ../R3RefinementHT. Neither collection proves
direct combined Part10+15 interoperability or direct independent JP3D decoding.

Reproduce into a new directory:
python3 Scripts/generate-r3-ht-fixtures.py planar --output /tmp/new-r3-planar
Use --tools to specify the independent Kakadu executable directory if needed.
