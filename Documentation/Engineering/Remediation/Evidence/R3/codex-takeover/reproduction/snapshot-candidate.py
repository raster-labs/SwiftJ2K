from pathlib import Path
import sys,json,subprocess,hashlib,shutil,datetime
w=Path(__file__).resolve().parent;src=w/'SwiftJ2K';name=sys.argv[1]
assert name.startswith('candidate-snapshot-') and all(c.isalnum() or c=='-' for c in name)
claim=Path('/Users/raster/Documents/Codex/2026-10-13/che/work/swiftj2k-audit/audit.claim/owner.json')
assert json.loads(claim.read_text())['invocation_id']==json.loads((w/'active-claim.json').read_text())['invocation_id']
dst=w/name;dst.mkdir(exist_ok=False)
names=sorted(set(subprocess.check_output(['git','ls-files','-co','--exclude-standard','-z'],cwd=src).decode().split('\0'))-{''})
hashes={}
for relative in names:
 p=src/relative
 if p.is_file():
  q=dst/relative;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
  h=hashlib.sha256(p.read_bytes()).hexdigest();assert h==hashlib.sha256(q.read_bytes()).hexdigest();hashes[relative]=h
assert all(hashlib.sha256((src/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
(w/(name+'-source.json')).write_text(json.dumps(hashes,indent=2)+'\n')
(w/(name+'-provenance.json')).write_text(json.dumps({'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'base_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=src).decode().strip(),'files':len(hashes),'scope':'Frozen production/test/doc/script inputs after positive writer stops. No acceptance claim.'},indent=2)+'\n')
print('Frozen '+name+' files '+str(len(hashes)),flush=True)
