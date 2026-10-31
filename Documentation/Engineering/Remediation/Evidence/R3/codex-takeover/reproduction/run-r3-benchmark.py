from pathlib import Path
import argparse,datetime,hashlib,json,math,platform,statistics,subprocess,time

p=argparse.ArgumentParser()
p.add_argument('--baseline-bin',type=Path,required=True)
p.add_argument('--candidate-bin',type=Path,required=True)
p.add_argument('--inputs',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--rounds',type=int,default=20)
p.add_argument('--cases',nargs='+',default=['odd8','medium16'])
p.add_argument('--operations',nargs='+',default=['encode-ebcot','encode-ht','decode-ebcot','decode-ht','transcode-to-ht','transcode-to-ebcot'])
a=p.parse_args();assert a.rounds>=20
a.output.mkdir(parents=True,exist_ok=False)
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
bins={'baseline':a.baseline_bin.resolve(),'candidate':a.candidate_bin.resolve()}
metadata={'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'scope':'Bounded R3 changed-volume-hot-path comparison; not complete R4 corpus or release qualification.',
 'baseline':'Rejected pre-takeover 67c8f7ed05379113b1fd41897b289c48a541266c; comparator only',
 'platform':platform.platform(),'compiler':subprocess.check_output(['swift','--version']).decode(),
 'hardware':subprocess.check_output(['sysctl','-n','hw.model','hw.physicalcpu','hw.logicalcpu','hw.memsize']).decode(),
 'os':subprocess.check_output(['sw_vers']).decode(),
 'power_before':subprocess.check_output(['pmset','-g','therm']).decode(),
 'binaries':{k:{'path':str(v),'sha256':sha(v)} for k,v in bins.items()},
 'inputs':{f.name:sha(f) for f in a.inputs.iterdir() if f.is_file()},
 'rounds':a.rounds,'warmups_per_process':5,
 'timing':'One operation timed per fresh process after five warmups. Serial alternating AB/BA per round. Process startup and sample verification excluded from operation latency; RSS includes startup/input/warmups.'}
(a.output/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
all_samples=[]
with (a.output/'samples.jsonl').open('w') as raw:
 for case in a.cases:
  for operation in a.operations:
   for round_index in range(a.rounds):
    for variant in (['baseline','candidate'] if round_index%2==0 else ['candidate','baseline']):
     command=[str(bins[variant]),'sample',str(a.inputs.resolve()),case,operation]
     began=time.monotonic()
     r=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
     prefix=f'{case}-{operation}-{round_index:02d}-{variant}'
     (a.output/(prefix+'.stdout')).write_bytes(r.stdout)
     (a.output/(prefix+'.stderr')).write_bytes(r.stderr)
     if r.returncode:raise RuntimeError(prefix+' failed exit '+str(r.returncode))
     sample=json.loads(r.stdout.decode().splitlines()[-1]);sample.update(variant=variant,round=round_index,command=command,process_seconds=time.monotonic()-began)
     assert sample['sample_exact'] and sample['backend']=='scalarCPU'
     all_samples.append(sample);raw.write(json.dumps(sample,sort_keys=True)+'\n');raw.flush()
   print('Measured '+case+' '+operation+' '+str(a.rounds)+' interleaved samples per version',flush=True)

def stats(values):
 s=sorted(values)
 return {'median':statistics.median(s),'p95':s[math.ceil(len(s)*.95)-1],'minimum':s[0],'maximum':s[-1],'stddev':statistics.stdev(s) if len(s)>1 else 0}

rows=[]
for case in a.cases:
 for operation in a.operations:
  row={'case':case,'operation':operation}
  for variant in bins:
   group=[s for s in all_samples if s['case']==case and s['operation']==operation and s['variant']==variant]
   row[variant]={'timed_samples':len(group),'warmups':sum(s['warmups'] for s in group),
     'latency_seconds':stats([s['elapsed_seconds'] for s in group]),
     'throughput_voxels_per_second':stats([s['voxels']/s['elapsed_seconds'] for s in group]),
     'peak_rss_bytes':stats([s['peak_rss_bytes'] for s in group])}
   for key in ['encoded_bytes','reported_peak_pixel_bytes','reported_peak_workspace_bytes','reported_pixel_allocation_count','copy_count','copy_bytes','output_sha256','low_power_mode','thermal_state','maximum_workers']:
    row[variant][key]=sorted({s[key] for s in group},key=str)
  row['median_latency_change_percent']=(row['candidate']['latency_seconds']['median']/row['baseline']['latency_seconds']['median']-1)*100
  row['median_rss_change_percent']=(row['candidate']['peak_rss_bytes']['median']/row['baseline']['peak_rss_bytes']['median']-1)*100
  row['encoded_size_change_percent']=(max(row['candidate']['encoded_bytes'])/max(row['baseline']['encoded_bytes'])-1)*100
  row['investigate_over_5_percent']=row['median_latency_change_percent']>5 or row['median_rss_change_percent']>5
  row['investigate_size_over_1_percent']=row['encoded_size_change_percent']>1
  rows.append(row)
summary={'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'all_samples_exact':True,'rows':rows,
 'power_after':subprocess.check_output(['pmset','-g','therm']).decode(),
 'interpretation':'Latency/memory increases above5% and encoded-size increases above1% require investigation and repeated controlled evidence. No automatic acceptance or waiver; reports are admission/accounting values, not measured heap allocation.'}
(a.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'cases':len(rows),'samples':len(all_samples),'all_samples_exact':True,'investigation_triggers':sum(r['investigate_over_5_percent'] or r['investigate_size_over_1_percent'] for r in rows)}),flush=True)
