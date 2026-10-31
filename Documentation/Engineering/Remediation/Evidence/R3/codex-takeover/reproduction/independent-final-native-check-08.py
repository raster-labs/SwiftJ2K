"""Read-only verification of frozen native receipts; never runs Swift or children."""
from pathlib import Path
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib, json, re, xml.etree.ElementTree as ET

W = Path(__file__).resolve().parent
S = W / 'candidate-snapshot-08'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p): return json.loads(Path(p).read_text())
manifest = read(W / 'candidate-snapshot-08-source.json')
actual = {str(p.relative_to(S)): sha(p) for p in S.rglob('*') if p.is_file() and '.build' not in p.relative_to(S).parts}
assert actual == manifest and len(actual) == 1349
receipt = {'review_started_at': datetime.now(timezone.utc).isoformat(), 'source': str(S),
           'manifest_sha256': sha(W / 'candidate-snapshot-08-source.json'),
           'source_files': len(actual), 'before': actual, 'files': {}, 'runs': {}, 'proofs': {}, 'historical': {}}
def record(p):
    p = Path(p); receipt['files'][str(p)] = sha(p)

diagnostic = re.compile(r'WARNING: ThreadSanitizer|ERROR: (?:AddressSanitizer|LeakSanitizer)|SUMMARY: (?:ThreadSanitizer|AddressSanitizer|LeakSanitizer)|runtime error:')
def run(name, expected_exit=0, source=manifest):
    d = W/'validation'/name; c = read(d/'command.json'); r = read(d/'result.json')
    assert r['exit_code'] == expected_exit and r['changed_inputs'] == []
    assert read(d/'source-before.json') == read(d/'source-after.json') == source
    assert sha(d/'native.log') == r['log_sha256']
    for p in d.iterdir():
        if p.is_file(): record(p)
    if 'native_streams' in r:
        assert r['capture_complete'] and r['capture_threads_joined'] and not r['capture_errors']
        assert r['wrapper_exit_code'] == expected_exit
        assert c['wrapper_sha256'] == sha(W/'run-validation.py')
        for key, value in r['native_streams'].items():
            p = d/('native.'+key)
            assert p.resolve() == Path(value['path']).resolve()
            assert sha(p) == value['sha256'] and p.stat().st_size == value['bytes']
        assert Counter((d/'native.log').read_bytes().splitlines()) == (Counter((d/'native.stdout').read_bytes().splitlines()) + Counter((d/'native.stderr').read_bytes().splitlines()))
    else:
        assert expected_exit != 0 or name in ['candidate-focused-08','candidate-release-build-08','candidate-cli-08']
    if expected_exit == 0:
        for p in [d/'native.log', d/'native.stdout', d/'native.stderr']:
            if p.exists(): assert not diagnostic.search(p.read_text()), p
    for item in r.get('built_cli_products_at_completion',{}).values():
        assert sha(item['path']) == item['sha256']; record(item['path'])
    result = {'exit_code': r['exit_code'], 'elapsed_seconds': r['elapsed_seconds'], 'command': c['command'],
              'log_sha256': r['log_sha256'], 'raw_capture_verified': 'native_streams' in r,
              'source_files': len(source), 'environment': c.get('test_environment'), 'compiler': c['compiler']}
    receipt['runs'][name] = result
    return result

for name in ['candidate-full-08','candidate-focused-08','candidate-release-build-08','candidate-cli-08',
             'candidate-tsan-inventory-08','candidate-jpip-tsan-08','candidate-complement-tsan-08',
             'candidate-asan-inventory-08','candidate-jpip-asan-08','candidate-complement-asan-08']:
    if (W/'validation'/name/'result.json').exists(): run(name)

def check_inventory(mode):
    d = W/'sanitizer-inventory-08'/mode; inv = read(d/'inventory.json')
    for p in d.iterdir():
        if p.is_file(): record(p)
    sets = {name: (d/(name+'.ids')).read_text().splitlines() for name in ['all','jpip','complement']}
    for v in sets.values(): assert len(v) == len(set(v)) and all(v)
    assert list(map(len,sets.values())) == [1336,625,711]
    allids, jpip, complement = (set(sets[n]) for n in ['all','jpip','complement'])
    assert not jpip & complement and jpip | complement == allids
    assert jpip == {s for s in allids if re.match(r'^SwiftJ2KJPIPTests[./]',s)}
    for kind in ['reference','sanitized']:
        assert inv[kind]['exit_code'] == 0
        assert sha(d/(kind+'.stdout')) == inv[kind]['stdout_sha256']
        assert sha(d/(kind+'.stderr')) == inv[kind]['stderr_sha256']
        assert set((d/(kind+'.stdout')).read_text().splitlines()) == allids
    return allids, jpip, complement

def independently_parse(d, bindings):
    """A second parser, independent of runtime-coverage/reconcile.py."""
    raw = (d/'native.stdout').read_text()
    reverse = {v:k for k,v in bindings.items()}; assert len(reverse) == len(bindings)
    xcstart = Counter(a+'/'+b for a,b in re.findall(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' started\.$",raw,re.M))
    xcpass = Counter(a+'/'+b for a,b in re.findall(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' passed \([^\n]+\)\.$",raw,re.M))
    assert xcstart == xcpass and all(n == 1 for n in xcpass.values())
    swstart = Counter(reverse[s] for s in re.findall(r'^◇ Test (?!case )(.+) started\.$',raw,re.M) if s != 'run')
    swpass = {}; parameters = {}
    for display, count in re.findall(r'^✔ Test (.+?)(?: with (\d+) test cases?)? passed after [0-9.]+ seconds\.$',raw,re.M):
        if display.startswith('run with '): continue
        key = reverse[display]; assert key not in swpass
        swpass[key] = {'status':'passed','parameter_count':int(count) if count else None}
    assert set(swstart) == set(swpass) and all(n == 1 for n in swstart.values())
    for recordtext in re.findall(r'^◇ Test case passing (.*?) started\.$',raw,re.M|re.S):
        arg, display = recordtext.rsplit(' to ',1)
        arg = re.sub(r'^(\d+) argument ',r'\1 arguments ',arg)
        assert not any(marker in arg for marker in ['◇ Test ', '✔ Test ', '✘ Test ', 'WARNING:', 'ERROR:'])
        key = reverse[display]; parameters.setdefault(key,Counter())[arg] += 1
    assert len(parameters) == sum(v['parameter_count'] is not None for v in swpass.values())
    for key, args in parameters.items(): assert sum(args.values()) == swpass[key]['parameter_count']
    xmlids = set()
    xml = ET.parse(d/'report-swift-testing.xml')
    for node in xml.iter('testcase'):
        assert not list(node)
        a,b=node.attrib['classname'],node.attrib['name']
        matches={a+'/'+b,a+'.'+b}&set(swpass)
        assert len(matches)==1
        key=matches.pop(); assert key not in xmlids; xmlids.add(key)
    assert xmlids == set(swpass)
    assert not re.search(r'^✘| skipped\b|known issue',raw,re.M|re.I)
    return dict(xcpass), swpass, {k:dict(v) for k,v in parameters.items()}

for mode in ['thread','address']:
    proofpath = W/('r3-sanitizer-execution-proof-'+mode+'-08.json')
    if not proofpath.exists(): continue
    proof = read(proofpath); record(proofpath)
    assert proof['state'] == 'COMPLETE_PARTITIONED_RUNTIME_COVERAGE'
    assert proof['declared_tests'] == 1336 and proof['parameter_declarations'] == 34
    assert proof['parameter_argument_starts'] == 397 and not proof['unexecuted_declarations']
    spec = W/'runtime-coverage'/(( 'thread' if mode=='thread' else 'address')+'-final-08.json')
    assert sha(spec)==proof['spec_sha256']; record(spec)
    assert sha(W/'runtime-coverage'/'reconcile.py')==proof['helper_sha256']; record(W/'runtime-coverage'/'reconcile.py')
    assert receipt['manifest_sha256']==proof['source_manifest_sha256']
    allids,jpip,complement=check_inventory(mode)
    assert sha(W/'sanitizer-inventory-08'/mode/'all.ids')==proof['inventory_sha256']
    for title in proof['title_source_receipts']:
        p=Path(title['source']); assert sha(p)==title['source_sha256']==manifest[str(p.relative_to(S))]
        assert title['literal'] in p.read_text().splitlines()[title['line']-1]
        assert json.loads(title['literal']) == json.loads(title['display'])
    parsed=[]; results=[]
    for obj,expected in zip([proof['ordinary'],*proof['partitions']],[allids,jpip,complement]):
        for path,digest in obj['files'].items(): assert sha(path)==digest; record(path)
        d=Path(obj['directory']); xc,sw,params=independently_parse(d,proof['display_bindings'])
        assert set(xc)|set(sw)==expected and not set(xc)&set(sw)
        assert set(obj['expected_ids'])==expected and set(obj['statuses'])==expected
        assert set(obj['statuses'].values())=={'passed'}
        assert {k:'passed' for k in xc}==obj['runtime']['xctest']
        assert sw==obj['runtime']['swift_testing'] and params==obj['runtime']['parameter_cases']
        assert not obj['runtime']['diagnostic_gaps']
        parsed.append((xc,sw,params))
        results.append({'directory':str(d),'declarations':len(xc)+len(sw),'xctest':len(xc),'swift_testing':len(sw),
                        'parameter_declarations':len(params),'parameter_starts':sum(sum(v.values()) for v in params.values())})
    assert {**parsed[1][1],**parsed[2][1]}==parsed[0][1]
    assert {**parsed[1][2],**parsed[2][2]}==parsed[0][2]
    receipt['proofs'][mode]={'proof_sha256':sha(proofpath),'independent_parser_matches':True,'runs':results}

cli=read(W/'cli-integration-08'/'report.json'); record(W/'cli-integration-08'/'report.json')
assert cli['checks']==len(cli['commands'])==246 and cli['status']=='passed'
assert all(c['exit_code']==c['expected_exit_code'] for c in cli['commands'])
assert sha(cli['binary'])==cli['binary_sha256']
assert cli['test_runner_sha256']==manifest['Scripts/test-cli.py']
assert cli['installer_sha256']==manifest['Scripts/install-cli.sh']
receipt['cli']={'checks':246,'binary_sha256':cli['binary_sha256'],'command_statuses_match':True}

old = [('candidate-full-tsan-05','candidate-snapshot-05', '4a0abcf25798065f203d2469776b5021931659d43e71f766035eeeb76b9d8fd7'),
       ('candidate-full-07','candidate-snapshot-07','d826c3c0afa13a283fdb0e68579e8031a111a1ebceabbcde9c4a95a7717fac6a')]
for name,snapshot,digest in old:
    if not (W/'validation'/name).exists():
        if name=='candidate-full-tsan-05': name='candidate-tsan-full-05'
    d=W/'validation'/name
    assert sha(d/'native.log')==digest
    r=read(d/'result.json'); assert r['exit_code']==1 and r['changed_inputs']==[]
    assert read(d/'source-before.json')==read(d/'source-after.json')==read(W/(snapshot+'-source.json'))
    for p in d.iterdir():
        if p.is_file(): record(p)
    receipt['historical'][name]={'exit_code':1,'log_sha256':digest,'source_unchanged':True}

record(W/'run-validation.py')
record(Path(__file__))
prior = ['independent-jpip-review-08.txt','independent-jpip-review-08-source.json',
         'independent-publication-review-07.txt','independent-publication-review-07-source.json',
         'independent-jpip-review-06.txt','independent-jpip-review-06-source.json',
         'independent-jpip-review-07.txt','independent-jpip-review-07-source.json']
for name in prior: record(W/name)
m04=read(W/'candidate-snapshot-04-source.json'); m07=read(W/'candidate-snapshot-07-source.json')
preserved=['Tests/SwiftJ2KJPIPTests/'+name for name in ['CodexR3IndependentTests.swift','CodexR3WebSocketBudgetTests.swift','CodexR3WebSocketLifecycleTests.swift']]
assert all(m04[p]==manifest[p] for p in preserved)
jpip=[p for p in m07 if p.startswith(('Sources/SwiftJ2KJPIP/','Tests/SwiftJ2KJPIPTests/'))]
assert len(jpip)==69 and all(m07[p]==manifest[p] for p in jpip)
receipt['unchanged_tests_from_failed_04']={p:manifest[p] for p in preserved}
receipt['unchanged_jpip_files_from_07']=len(jpip)
for name in ['candidate-snapshot-04-source.json','candidate-snapshot-07-source.json','candidate-snapshot-08-source.json']:
    record(W/name)
if (W/'independent-final-native-review-08.txt').exists(): record(W/'independent-final-native-review-08.txt')
after={str(p.relative_to(S)):sha(p) for p in S.rglob('*') if p.is_file() and '.build' not in p.relative_to(S).parts}
assert actual==after
receipt['after']=after; receipt['source_stable']=True
receipt['review_finished_at']=datetime.now(timezone.utc).isoformat()
(W/'independent-final-native-review-08-source.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({k:v for k,v in receipt.items() if k not in ['files','before','after']},indent=2))
