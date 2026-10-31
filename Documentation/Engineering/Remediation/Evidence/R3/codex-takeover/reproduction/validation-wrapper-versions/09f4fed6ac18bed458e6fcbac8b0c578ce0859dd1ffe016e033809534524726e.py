#!/usr/bin/env python3
"""Run one exclusive native gate with source identities and unfiltered logs."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess
import sys
import time

WORK = Path(__file__).resolve().parent
SOURCE = Path(os.environ.get("SWIFTJ2K_VALIDATION_SOURCE", str(WORK / "SwiftJ2K"))).resolve()
assert SOURCE.is_relative_to(WORK) if hasattr(SOURCE, "is_relative_to") else str(SOURCE).startswith(str(WORK)+"/")
CLAIM = Path('/Users/raster/Documents/Codex/2026-10-13/che/work/swiftj2k-audit/audit.claim/owner.json')
assert json.loads(CLAIM.read_text())['invocation_id'] == json.loads((WORK/'active-claim.json').read_text())['invocation_id']
CHECKPOINT = Path('/Users/raster/Documents/Codex/2026-10-28/check-the-project-in-the-path/outputs/SwiftJ2K-remediation-checkpoint.json')
label = sys.argv[1]
assert label and all(c.isalnum() or c in '-_' for c in label)
command = sys.argv[2:]
assert command
out = WORK / 'validation' / label
out.mkdir(parents=True, exist_ok=False)

def identity():
    if (SOURCE/'.git').exists():
        paths = set(subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=SOURCE).decode().split('\0'))
    else:
        paths = {str(p.relative_to(SOURCE)) for p in SOURCE.rglob('*')
                 if p.is_file() and '.build' not in p.relative_to(SOURCE).parts}
    result = {}
    for name in sorted(paths):
        if name and (SOURCE/name).is_file():
            result[name] = hashlib.sha256((SOURCE/name).read_bytes()).hexdigest()
    return result

before = identity()
(out/'source-before.json').write_text(json.dumps(before, indent=2)+'\n')
env = os.environ.copy()
for key in ('CLANG_MODULE_CACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE'):
    env[key] = str(WORK/'module-cache')
for name in ('module-cache', 'swiftpm-cache', 'swiftpm-config', 'swiftpm-security'):
    (WORK/name).mkdir(exist_ok=True)
start = datetime.now(timezone.utc).isoformat()
record = {'started_at': start, 'cwd': str(SOURCE), 'command': command,
          'wrapper_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'identity_scope': 'Repository tracked/unignored files or snapshot files excluding generated .build',
          'base_head': (subprocess.check_output(['git','rev-parse','HEAD'],cwd=SOURCE).decode().strip() if (SOURCE/'.git').exists() else 'immutable diagnostic snapshot; see provenance'),
          'source_files': len(before), 'compiler': subprocess.check_output(['swift','--version']).decode()}
(out/'command.json').write_text(json.dumps(record, indent=2)+'\n')
print('Running '+label+'; full log '+str(out/'native.log'), flush=True)
checkpoint = json.loads(CHECKPOINT.read_text())
checkpoint['r3_audit']['native_current'] = 'Root exclusive native campaign '+label+' on '+str(SOURCE)+'; source writers only affect separate isolated checkout.'
CHECKPOINT.write_text(json.dumps(checkpoint, indent=2)+'\n')
began = time.monotonic()
with (out/'native.log').open('w') as log:
    process = subprocess.Popen(command, cwd=SOURCE, env=env, stdout=log, stderr=subprocess.STDOUT)
    code = process.wait()
after = identity()
changed = sorted(k for k in set(before)|set(after) if before.get(k) != after.get(k))
(out/'source-after.json').write_text(json.dumps(after, indent=2)+'\n')
result = {'finished_at': datetime.now(timezone.utc).isoformat(), 'exit_code': code,
          'elapsed_seconds': time.monotonic()-began, 'changed_inputs': changed,
          'log_sha256': hashlib.sha256((out/'native.log').read_bytes()).hexdigest()}
(out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
checkpoint = json.loads(CHECKPOINT.read_text())
checkpoint['r3_audit']['native_current'] = 'No native campaign active; last '+label+' exit '+str(code)+'. See '+str(out/'result.json')
checkpoint['r3_codex_takeover']['latest_native_result'] = str(out/'result.json')
CHECKPOINT.write_text(json.dumps(checkpoint, indent=2)+'\n')
print(json.dumps({**result, 'changed_inputs': changed[:12], 'changed_input_count': len(changed)}), flush=True)
print('\n'.join(line if len(line) <= 1200 else line[:1200]+' [line shortened; full log retained]' for line in (out/'native.log').read_text(errors='replace').splitlines()[-35:]),flush=True)
sys.exit(code if code else (2 if changed else 0))
