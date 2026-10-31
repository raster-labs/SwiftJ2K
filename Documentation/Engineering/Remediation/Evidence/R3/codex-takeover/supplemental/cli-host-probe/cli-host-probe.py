import subprocess, sys
from pathlib import Path
binary=Path(sys.argv[1]).resolve()
case=Path(sys.argv[2]).resolve(); case.mkdir(exist_ok=False)
fixture=Path('Tests/SwiftJ2KTests/Fixtures/Lossless/g16_1x1_max.opj_n1.j2k').resolve()
argv=[str(binary),'jpip','server','--single-file',str(fixture),'--host',' 127.0.0.1 ','--port','0','--once','--json']
r=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
(case/'stdout.txt').write_bytes(r.stdout);(case/'stderr.txt').write_bytes(r.stderr)
print('Exit:',r.returncode);print(r.stdout.decode(errors='replace'));print(r.stderr.decode(errors='replace')[:1600])
assert r.returncode==0, 'Valid normalized loopback host must not trap'
