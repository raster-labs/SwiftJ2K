from pathlib import Path
import hashlib,json,subprocess
base=Path(__file__).resolve().parent
out=base/'ht-refinement-candidates-01';out.mkdir(exist_ok=False)
src=base/'diagnostic-source-03/Tests/SwiftJ2KTests/Fixtures/Lossless/g16_64x64_random.pgm'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
records=[]
for rate in (4,8,12):
 p1=out/f'rate{rate}.part1.j2k'; ht=out/f'rate{rate}.ht.j2k'
 commands=[['/usr/local/bin/kdu_compress','-i',str(src),'-o',str(p1),'Creversible=yes','Cmodes=0','Clevels=0','Clayers=1','Cblk={8,8}','-rate',str(rate),'-num_threads','0','-quiet'],
 ['/usr/local/bin/kdu_transcode','-i',str(p1),'-o',str(ht),'Cmodes=HT','-quiet']]
 for kind,path in [('part1',p1),('ht',ht)]:
  commands.append(['/usr/local/bin/kdu_expand','-i',str(path),'-o',str(out/f'rate{rate}.{kind}.pgm'),'-num_threads','0','-precise','-quiet'])
 steps=[]
 for i,cmd in enumerate(commands):
  r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  log=out/f'rate{rate}.{i}.log';log.write_bytes(r.stdout)
  steps.append({'command':cmd,'exit_code':r.returncode,'log_sha256':sha(log)})
  if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace'))
 exact=(out/f'rate{rate}.part1.pgm').read_bytes()==(out/f'rate{rate}.ht.pgm').read_bytes()
 records.append({'rate':rate,'steps':steps,'independent_part1_ht_decodes_equal':exact,'files':{p.name:sha(p) for p in [p1,ht,out/f'rate{rate}.part1.pgm',out/f'rate{rate}.ht.pgm']}})
 assert exact
manifest={'purpose':'T.803 (2024) C.1.10 candidate generation: reversible transform with lossy Part1 truncation then HT transcode. Actual refinement coverage must be inspected separately.','source':str(src),'source_sha256':sha(src),'license':'Synthetic Apache-2.0 input; Kakadu output.','tools':{n:sha(Path('/usr/local/bin')/n) for n in ('kdu_compress','kdu_transcode','kdu_expand')},'records':records}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'candidates':len(records),'independent_decodes_equal':all(r['independent_part1_ht_decodes_equal'] for r in records)}))
