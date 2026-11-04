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
import threading

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
          'test_environment': {key: env.get(key) for key in ('SWIFTJ2K_TEST_CLI_PATH', 'ASAN_OPTIONS', 'TSAN_OPTIONS')},
          'identity_scope': 'Repository tracked/unignored files or snapshot files excluding generated .build',
          'base_head': (subprocess.check_output(['git','rev-parse','HEAD'],cwd=SOURCE).decode().strip() if (SOURCE/'.git').exists() else 'immutable diagnostic snapshot; see provenance'),
          'source_files': len(before), 'compiler': subprocess.check_output(['swift','--version']).decode()}
record['output_capture'] = {
    'version': 1, 'stdout': str(out/'native.stdout'), 'stderr': str(out/'native.stderr'),
    'merged': str(out/'native.log'),
    'merge_policy': 'Whole LF-terminated lines under one lock; EOF fragments receive one synthetic LF. Cross-stream chronological ordering is not guaranteed.'}
(out/'command.json').write_text(json.dumps(record, indent=2)+'\n')
print('Running '+label+'; full log '+str(out/'native.log'), flush=True)
checkpoint = json.loads(CHECKPOINT.read_text())
checkpoint['r3_audit']['native_current'] = 'Root exclusive native campaign '+label+' on '+str(SOURCE)+'; source writers only affect separate isolated checkout.'
CHECKPOINT.write_text(json.dumps(checkpoint, indent=2)+'\n')
began = time.monotonic()
capture_errors = []
capture_lock = threading.Lock()
merged_synthetic_eof_newlines = 0
merged_failed = False

def capture_error(stream, operation, error):
    with capture_lock:
        capture_errors.append({'stream': stream, 'operation': operation,
                               'error': type(error).__name__+': '+str(error)})

def merge_line(data, eof_fragment=False):
    global merged_failed, merged_synthetic_eof_newlines
    with capture_lock:
        if merged_failed:
            return
        try:
            log.write(data)
            if eof_fragment:
                log.write(b'\n')
                merged_synthetic_eof_newlines += 1
            log.flush()
        except Exception as error:
            merged_failed = True
            capture_errors.append({'stream': 'merged', 'operation': 'write/flush',
                                   'error': type(error).__name__+': '+str(error)})

def capture_stream(name, pipe, raw):
    pending = bytearray()
    raw_failed = False
    try:
        while True:
            chunk = os.read(pipe.fileno(), 65536)
            if not chunk:
                break
            if not raw_failed:
                try:
                    raw.write(chunk)
                    raw.flush()
                except Exception as error:
                    capture_error(name, 'write/flush', error)
                    raw_failed = True
                    # Continue draining so a capture failure cannot fill the child's pipe.
            pending.extend(chunk)
            begin = 0
            while True:
                end = pending.find(b'\n', begin)
                if end < 0:
                    break
                merge_line(bytes(pending[begin:end+1]))
                begin = end + 1
            if begin:
                del pending[:begin]
        if pending:
            merge_line(bytes(pending), eof_fragment=True)
    except Exception as error:
        capture_error(name, 'read/capture', error)
    finally:
        try:
            pipe.close()
        except Exception as error:
            capture_error(name, 'pipe close', error)

# Raw files contain exact bytes, including any unterminated final fragment.
# native.log remains compatible with old consumers but combines complete lines only.
log = (out/'native.log').open('wb')
raw_outputs = {}
threads = []
try:
    for name in ('stdout', 'stderr'):
        raw_outputs[name] = (out/('native.'+name)).open('wb')
    process = subprocess.Popen(command, cwd=SOURCE, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    record['spawned_pid'] = process.pid
    (out/'command.json').write_text(json.dumps(record, indent=2)+'\n')
    try:
        for name in ('stdout', 'stderr'):
            thread = threading.Thread(target=capture_stream,
                args=(name, getattr(process, name), raw_outputs[name]),
                name='validation-capture-'+name, daemon=False)
            thread.start()
            threads.append(thread)
    except BaseException as error:
        capture_error('merged', 'capture thread startup', error)
        # Only this newly spawned validation child is terminated on a fatal setup
        # failure; otherwise an undrained pipe could deadlock it and the wrapper.
        try:
            process.kill()
        except ProcessLookupError:
            pass
        for name in ('stdout', 'stderr'):
            if not any(thread.name == 'validation-capture-'+name for thread in threads):
                capture_stream(name, getattr(process, name), raw_outputs[name])
    try:
        code = process.wait()
    finally:
        for thread in threads:
            thread.join()
finally:
    for name, stream in [*raw_outputs.items(), ('merged', log)]:
        try:
            stream.close()
        except Exception as error:
            capture_error(name, 'file close', error)
after = identity()
changed = sorted(k for k in set(before)|set(after) if before.get(k) != after.get(k))
(out/'source-after.json').write_text(json.dumps(after, indent=2)+'\n')
result = {'finished_at': datetime.now(timezone.utc).isoformat(), 'exit_code': code,
          'elapsed_seconds': time.monotonic()-began, 'changed_inputs': changed,
          'log_sha256': hashlib.sha256((out/'native.log').read_bytes()).hexdigest(),
          'native_streams': {name: {'path': str(out/('native.'+name)),
              'sha256': hashlib.sha256((out/('native.'+name)).read_bytes()).hexdigest(),
              'bytes': (out/('native.'+name)).stat().st_size} for name in ('stdout', 'stderr')},
          'capture_complete': not capture_errors, 'capture_errors': capture_errors,
          'capture_threads_joined': True,
          'merged_synthetic_eof_newlines': merged_synthetic_eof_newlines,
          'wrapper_exit_code': code if code else (2 if changed or capture_errors else 0)}
if '--scratch-path' in command:
    scratch = Path(command[command.index('--scratch-path') + 1])
    if not scratch.is_absolute():
        scratch = SOURCE / scratch
    products = {}
    for configuration in ('debug', 'release'):
        binary = scratch / configuration / 'swiftj2k-cli'
        if binary.is_file():
            products[configuration] = {'path': str(binary.resolve()),
                'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    result['built_cli_products_at_completion'] = products
(out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
checkpoint = json.loads(CHECKPOINT.read_text())
checkpoint['r3_audit']['native_current'] = 'No native campaign active; last '+label+' exit '+str(code)+(' (capture failed)' if capture_errors else '')+'. See '+str(out/'result.json')
checkpoint['r3_codex_takeover']['latest_native_result'] = str(out/'result.json')
CHECKPOINT.write_text(json.dumps(checkpoint, indent=2)+'\n')
print(json.dumps({**result, 'changed_inputs': changed[:12], 'changed_input_count': len(changed)}), flush=True)
print('\n'.join(line if len(line) <= 1200 else line[:1200]+' [line shortened; full log retained]' for line in (out/'native.log').read_text(errors='replace').splitlines()[-35:]),flush=True)
sys.exit(result['wrapper_exit_code'])
