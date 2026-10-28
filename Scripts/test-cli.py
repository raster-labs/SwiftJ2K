#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Black-box CLI and staged binary/manual installation regression checks."""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True,help='New evidence directory')
    args=parser.parse_args();binary=args.binary.resolve();out=args.output.resolve()
    if out.exists():parser.error('Use a fresh output directory')
    out.mkdir(parents=True)
    repo=Path(__file__).resolve().parent.parent
    tool=binary.name;version=(repo/'VERSION').read_text().strip();manual=repo/'ManPages'/(tool+'.1')
    if not manual.is_file():parser.error('Binary name must match this repository manual')
    report={'binary':str(binary),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
            'installer_sha256':hashlib.sha256((repo/'Scripts/install-cli.sh').read_bytes()).hexdigest(),
            'test_runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'version':version,'manual_sha256':hashlib.sha256(manual.read_bytes()).hexdigest(),'commands':[],'status':'running'}
    def save(): (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    def run(argv,expected=0,**kwargs):
        r=subprocess.run([str(x) for x in argv],capture_output=True,text=True,timeout=30,**kwargs)
        report['commands'].append({'argv':[str(x) for x in argv],'exit_code':r.returncode,'expected_exit_code':expected,
                                   'stdout':r.stdout,'stderr':r.stderr})
        save();assert r.returncode==expected,(argv,r.returncode,r.stderr);return r
    def cli(*values,expected=0):return run([binary,*values],expected)
    def document(r):
        d=json.loads(r.stdout);assert d['version']==version and d['minimumAppleOS']=='26.0'
        assert d['canEncode'] is True and d['canDecode'] is True and d['canInspect'] is True and d['canTranscode'] is True
        assert d['formats']==['htj2k-codestream','jp2','jpeg2000-codestream','jph','jpx']
        assert d['availableBackends']==['scalar','accelerated']
        return d
    try:
        root=cli('--help');assert 'USAGE:' in root.stdout and 'unavailable' in root.stdout and not root.stderr
        for form in [[],['-h'],['help']]:assert cli(*form).stdout==root.stdout
        command=cli('capabilities','--help').stdout
        assert cli('help','capabilities').stdout==command and cli('capabilities','-h').stdout==command
        assert '--json' in command and 'EXIT STATUS' in command
        for form in [['--version'],['version'],['--version','--quiet']]:assert cli(*form).stdout==tool+' '+version+'\n'
        baseline=document(cli('capabilities','--json'))
        for level in range(1,6):
            for form in [['-'+'v'*level],['-v']*level,['--verbose',str(level)],['--verbose='+str(level)],
                         ['-verbose:',str(level)],['-verbose:'+str(level)],['--verbose','+'*level],['--verbose='+'+'*level]]:
                r=cli('capabilities','--json',*form);assert document(r)==baseline
                assert len(r.stderr.splitlines())==level,(form,r.stderr)
                assert all(f'[{i}]' in r.stderr for i in range(1,level+1))
        for form in [['--verbose'],['-verbose']]:assert len(cli(*form,'capabilities','--json').stderr.splitlines())==1
        assert len(cli('capabilities','-v','--verbose','2','-v').stderr.splitlines())==3
        assert len(cli('capabilities','-vv','-vvv').stderr.splitlines())==5
        quiet=cli('capabilities','--json','--quiet');assert not quiet.stderr and document(quiet)==baseline
        assert cli('--help','--quiet').stdout==root.stdout
        for invalid in ['0','6','10','99999999999999999999999999999','abc','++++++','+2','١','']:
            r=cli('capabilities','--verbose='+invalid,expected=2);assert not r.stdout and r.stderr
        for form in [['--verbose=5','-v'],['-vvvvvv'],['-v','--quiet'],['--quiet','--verbose=1'],['--quiet','--verbose=0'],
                     ['--unknown'],['bogus'],['help','bogus'],['capabilities','extra'],['--verbose:'],['--json'],
                     ['--input','some-path'],['capabilities','--output','x'],['capabilities','--version'],['--input']]:
            r=cli(*form,expected=2);assert not r.stdout and r.stderr
        with tempfile.TemporaryDirectory(prefix='cli stage spaces ',dir=out) as temp:
            temp=Path(temp);payload=temp/'private image λ.raw';payload.write_bytes(b'unchanged')
            for verb in ['encode','decode','inspect','validate','transcode']:
                assert 'USAGE:' in cli(verb,'--help').stdout and 'UNAVAILABLE' not in cli(verb,'--help').stdout
            r=cli('transcode','--input',str(payload),'--output',str(temp/'out.j2c'),'-vvvvv',expected=4)
            assert not r.stdout and str(payload) not in r.stderr and not (temp/'out.j2c').exists() and payload.read_bytes()==b'unchanged'
            # Codec verbs on the repository fixtures (CLI-02, CLI-03, CLI-04, CLI-06).
            fixtures=repo/'Tests/SwiftJ2KTests/Fixtures/Lossless'
            manifest=json.loads((fixtures/'manifest.json').read_text())
            def pgm_samples(path):
                d=path.read_bytes();parts=[];i=0
                while len(parts)<4:
                    while d[i:i+1].isspace():i+=1
                    if d[i:i+1]==b'#':
                        while d[i:i+1]!=b'\n':i+=1
                        continue
                    j=i
                    while not d[j:j+1].isspace():j+=1
                    parts.append(d[i:j]);i=j
                body=d[i+1:];w,h,mx=int(parts[1]),int(parts[2]),int(parts[3])
                return w,h,(list(body[:w*h]) if mx<=255 else [int.from_bytes(body[k:k+2],'big') for k in range(0,w*h*2,2)])
            def nrrd_samples(data):
                i=data.index(b'\n\n')+2;header=data[:i].decode();body=data[i:]
                fields=dict(l.split(': ',1) for l in header.splitlines() if ': ' in l and not l.startswith('#'))
                keys=dict(l.split(':=',1) for l in header.splitlines() if ':=' in l)
                assert fields['type']=='uint16' and fields['dimension']=='2' and fields['encoding']=='raw' and fields['endian']=='little'
                w,h=map(int,fields['sizes'].split());assert len(body)==w*h*2
                return w,h,int(keys['swiftj2k.meaningfulbits']),[int.from_bytes(body[k:k+2],'little') for k in range(0,len(body),2)]
            for entry in manifest['fixtures']:
                if entry['name'] not in ('g12_129x67_gradient','g16_17x9_alternating','g08_37x23_random'):continue
                w,h,samples=pgm_samples(fixtures/(entry['name']+'.pgm'))
                stream=fixtures/entry['codestreams'][0]['file']
                info=json.loads(cli('inspect','-i',stream,'--json').stdout)
                assert info['width']==w and info['height']==h and info['meaningfulBits']==entry['meaningfulBits'] and info['format']=='jpeg2000-codestream'
                text=cli('inspect','-i',stream).stdout;assert f'width: {w}' in text and f'meaningful bits: {entry["meaningfulBits"]}' in text
                valid=json.loads(cli('validate','-i',stream,'--json').stdout);assert valid['valid'] is True and valid['width']==w
                assert cli('validate','-i',stream).stdout.startswith('valid: ')
                decoded=temp/(entry['name']+' decoded.nrrd')
                r=cli('decode','-i',stream,'-o',decoded,'--json');assert not r.stdout
                dreport=json.loads(r.stderr);assert dreport['command']=='decode' and dreport['copyEvents']==0 and dreport['fidelity']=='exactSamples'
                nw,nh,bits,nsamples=nrrd_samples(decoded.read_bytes());assert (nw,nh,bits)==(w,h,entry['meaningfulBits']) and nsamples==samples
                cli('decode','-i',stream,'-o',decoded,expected=6);assert nrrd_samples(decoded.read_bytes())[3]==samples
                cli('decode','-i',stream,'-o',decoded,'--overwrite','--input-format','j2k','--output-format','nrrd','--copy-policy','allow-copy')
                encoded=temp/(entry['name']+' re-encoded.j2k')
                r=cli('encode','-i',decoded,'-o',encoded,'--json','--levels','2','--code-block','32x32');ereport=json.loads(r.stderr)
                assert not r.stdout and ereport['format']=='jpeg2000-codestream' and ereport['meaningfulBits']==entry['meaningfulBits'] and ereport['outputBytes']==encoded.stat().st_size
                back=json.loads(cli('validate','-i',encoded,'--json').stdout);assert back['width']==w and back['height']==h
                piped=subprocess.run(f'"{binary}" decode -i - -o - < "{stream}" | "{binary}" encode -i - --input-format nrrd -o - | "{binary}" decode -i - -o -',shell=True,capture_output=True,timeout=60)
                report['commands'].append({'argv':['sh','-c','decode | encode | decode'],'exit_code':piped.returncode,'expected_exit_code':0,'stderr':piped.stderr.decode(errors='replace')});save()
                assert piped.returncode==0 and nrrd_samples(piped.stdout)[3]==samples
                # Native J2K <-> HTJ2K transcode and HTJ2K encode/decode/inspect/validate (Milestone 6).
                ht_encoded=temp/(entry['name']+' ht-encoded.j2c')
                r=cli('encode','-i',decoded,'-o',ht_encoded,'--output-format','htj2k','--json','--levels','2','--code-block','32x32')
                ht_ereport=json.loads(r.stderr);assert not r.stdout and ht_ereport['format']=='htj2k-codestream'
                ht_info=json.loads(cli('inspect','-i',ht_encoded,'--input-format','htj2k','--json').stdout)
                assert ht_info['format']=='htj2k-codestream' and ht_info['width']==w and ht_info['height']==h
                converted=temp/(entry['name']+' converted.j2c')
                r=cli('transcode','-i',stream,'--input-format','j2k','--output-format','htj2k','--mode','lossless','-o',converted,'--json')
                treport=json.loads(r.stderr);assert not r.stdout and treport['command']=='transcode' and treport['format']=='htj2k-codestream'
                assert treport['processingPath']=='coefficients' and treport['pixelAllocations']==0 and treport['copyEvents']==0
                cli('transcode','-i',stream,'-o',converted,expected=6)
                restored=temp/(entry['name']+' restored.j2k')
                r=cli('transcode','-i',converted,'--input-format','htj2k','--output-format','j2k','--mode','lossless','-o',restored,'--json')
                rreport=json.loads(r.stderr);assert not r.stdout and rreport['format']=='jpeg2000-codestream' and rreport['processingPath']=='coefficients'
                t_piped=subprocess.run(f'"{binary}" transcode -i - -o - < "{stream}" | "{binary}" transcode -i - -o - | "{binary}" decode -i - -o -',shell=True,capture_output=True,timeout=60)
                report['commands'].append({'argv':['sh','-c','transcode | transcode | decode'],'exit_code':t_piped.returncode,'expected_exit_code':0,'stderr':t_piped.stderr.decode(errors='replace')});save()
                assert t_piped.returncode==0 and nrrd_samples(t_piped.stdout)[3]==samples
                assert not [f for f in temp.iterdir() if f.name.endswith('.tmp')]
            # COM metadata preservation and discard-ancillary policy (M6-AUD-004).
            first_stream=(fixtures/manifest['fixtures'][0]['codestreams'][0]['file']).read_bytes()
            com_text=b'Codex-M6-ancillary-metadata-audit'
            com_payload=b'\x00\x01'+com_text
            com_seg=b'\xff\x64'+(2+len(com_payload)).to_bytes(2,'big')+com_payload
            com_in=temp/'com_input.j2k';com_in.write_bytes(first_stream[:2]+com_seg+first_stream[2:])
            com_ht=temp/'com_out.j2c';com_j2k=temp/'com_restored.j2k';com_disc=temp/'com_discarded.j2c'
            r_pres=cli('transcode','-i',com_in,'-o',com_ht,'--output-format','htj2k','--json')
            pres_rep=json.loads(r_pres.stderr)
            assert com_text in com_ht.read_bytes() and pres_rep['discardedMetadataCount']==0 and pres_rep['discardedMetadataBytes']==0 and pres_rep['discardedMetadataKinds']==[]
            cli('transcode','-i',com_ht,'-o',com_j2k,'--output-format','j2k','--json')
            assert com_text in com_j2k.read_bytes()
            r_disc=cli('transcode','-i',com_in,'-o',com_disc,'--output-format','htj2k','--metadata-policy','discard-ancillary','--json')
            disc_rep=json.loads(r_disc.stderr)
            assert com_text not in com_disc.read_bytes() and disc_rep['discardedMetadataCount']>=1 and disc_rep['discardedMetadataBytes']>=len(com_payload) and disc_rep['discardedMetadataKinds']==['COM']
            # Exit statuses: 2 usage, 3 malformed, 4 unsupported format/feature, 5 limit/deadline, 6 I/O.
            good=fixtures/'g16_64x64_random.opj.j2k';nine=fixtures/'g16_64x64_random.irreversible97.j2k'
            assert json.loads(cli('validate','-i',nine,'--json').stdout)['valid'] is True
            part2=temp/'part2.j2k';gbytes=bytearray(good.read_bytes());gbytes[6]=0x80;gbytes[7]=0x02;part2.write_bytes(bytes(gbytes))
            # Milestone 7 CLI breadth: lossy, near-lossless, signed int16 NRRD, and 3D RGB NRRD.
            rgb_nrrd=temp/'rgb8.nrrd'
            rgb_payload=bytes((i*7)&255 for i in range(3*16*12))
            rgb_nrrd.write_bytes(b'NRRD0004\ntype: uint8\ndimension: 3\nsizes: 3 16 12\nencoding: raw\nkinds: RGB-color space space\nswiftj2k.meaningfulbits:=8\n\n'+rgb_payload)
            rgb_j2k=temp/'rgb_rct.j2k';rgb_ict=temp/'rgb_ict.j2k';rgb_dec=temp/'rgb_dec.nrrd'
            r_rct=cli('encode','-i',rgb_nrrd,'-o',rgb_j2k,'--wavelet','53','--mct','rct','--tile-size','8x6','--layers','2','--sop','--eph','--json')
            assert json.loads(r_rct.stderr)['fidelity']=='exactSamples'
            cli('decode','-i',rgb_j2k,'-o',rgb_dec,'--json')
            assert rgb_dec.read_bytes().endswith(rgb_payload)
            r_ict=cli('encode','-i',rgb_nrrd,'-o',rgb_ict,'--mode','lossy','--quality','0.85','--wavelet','97','--mct','ict','--json')
            assert json.loads(r_ict.stderr)['fidelity']=='lossy'
            assert json.loads(cli('validate','-i',rgb_ict,'--json').stdout)['valid'] is True
            s16_nrrd=temp/'signed16.nrrd';s16_j2k=temp/'signed16_nl.j2k'
            s16_nrrd.write_bytes(b'NRRD0004\ntype: int16\ndimension: 2\nsizes: 16 12\nencoding: raw\nendian: little\n\n'+b'\x00\x80\xff\x7f'*(16*6))
            r_nl=cli('encode','-i',s16_nrrd,'-o',s16_j2k,'--mode','near-lossless','--max-error','2','--roi','2,2,8,6','--json')
            assert json.loads(r_nl.stderr)['fidelity']=='boundedError(2)'
            # Milestone 8 CLI container formats: JP2, JPH, JPX, --container, and --max-metadata.
            c_fixtures=repo/'Tests/SwiftJ2KTests/Fixtures/Containers'
            rgb_jp2=temp/'rgb8.jp2';rgb_jph=temp/'rgb8.jph';rgb_jpx=temp/'rgb8.jpx';rgb_jp2_dec=temp/'rgb_jp2_dec.nrrd'
            r_jp2=cli('encode','-i',rgb_nrrd,'-o',rgb_jp2,'--output-format','jp2','--json')
            assert json.loads(r_jp2.stderr)['format']=='jp2'
            assert json.loads(cli('inspect','-i',rgb_jp2,'--input-format','jp2','--json').stdout)['format']=='jp2'
            cli('decode','-i',rgb_jp2,'-o',rgb_jp2_dec,'--json')
            assert rgb_jp2_dec.read_bytes().endswith(rgb_payload)
            r_jph=cli('encode','-i',rgb_nrrd,'-o',rgb_jph,'--output-format','jph','--json')
            assert json.loads(r_jph.stderr)['format']=='jph'
            r_jpx=cli('encode','-i',rgb_nrrd,'-o',rgb_jpx,'--container','jpx','--json')
            assert json.loads(r_jpx.stderr)['format']=='jpx'
            assert json.loads(cli('validate','-i',rgb_jpx,'--input-format','jpx','--json').stdout)['valid'] is True
            # Transcode JP2 <-> JPH container round-trip on greyscale fixture.
            g12_jp2=c_fixtures/'jp2_g16_lossless.kdu.jp2'
            g12_jph=temp/'g12_trans.jph';g12_back=temp/'g12_back.jp2'
            r_tjp=cli('transcode','-i',g12_jp2,'-o',g12_jph,'--json')
            assert json.loads(r_tjp.stderr)['format']=='jph' and json.loads(r_tjp.stderr)['sourceFormat']=='jp2'
            r_tbk=cli('transcode','-i',g12_jph,'-o',g12_back,'--json')
            assert json.loads(r_tbk.stderr)['format']=='jp2' and json.loads(r_tbk.stderr)['sourceFormat']=='jph'
            # Enforce --max-metadata on container with ICC + XML + UUID metadata.
            meta_jp2=c_fixtures/'jp2_rgb8_icc_res_meta.kdu.jp2'
            cli('validate','-i',meta_jp2,'--max-metadata','64',expected=5)
            # Milestone 9 CLI backend selection: scalar vs accelerated byte-identity.
            acc_j2k=temp/'rgb8_acc.j2k';sca_j2k=temp/'rgb8_sca.j2k'
            r_acc=cli('encode','-i',rgb_nrrd,'-o',acc_j2k,'--backend','accelerated','--json')
            r_sca=cli('encode','-i',rgb_nrrd,'-o',sca_j2k,'--backend','scalar','--json')
            assert json.loads(r_acc.stderr)['backend']=='accelerated' and json.loads(r_sca.stderr)['backend']=='scalar'
            assert acc_j2k.read_bytes()==sca_j2k.read_bytes()
            v_acc=json.loads(cli('validate','-i',acc_j2k,'--backend','accelerated','--json').stdout)
            v_sca=json.loads(cli('validate','-i',acc_j2k,'--backend','scalar','--json').stdout)
            assert v_acc['backend']=='accelerated' and v_sca['backend']=='scalar'
            for form in [['encode'],['decode','-i',good],['transcode','-i',good],['inspect','-i',good,'-o','x'],['validate','-i',good,'--output','x'],
                         ['decode','-i',good,'-o','x','--input-format','tiff'],['encode','-i',good,'-o','x','--precision','17'],
                         ['encode','-i',good,'-o','x','--code-block','3x3'],['encode','-i',good,'-o','x','--levels','40'],
                         ['transcode','-i',good,'-o','x','--precision','12'],['transcode','-i',good,'-o','x','--metadata-policy','bogus'],
                         ['validate','-i',good,'--threads','9'],['validate','-i',good,'--timeout','-1'],['validate','-i',good,'-i',good]]:
                r=cli(*form,expected=2);assert not r.stdout and r.stderr
            truncated=temp/'truncated.j2k';truncated.write_bytes(good.read_bytes()[:100])
            ht_good=repo/'Tests/SwiftJ2KTests/Fixtures/HTJ2K/g16_64x64_random.ojph.j2c'
            for form,code in [(['validate','-i',part2],4),(['validate','-i',truncated],3),(['validate','-i',payload],4),
                              (['encode','-i',good,'-o',temp/'x.j2k'],4),(['decode','-i',good,'-o',temp/'x.nrrd','--input-format','nrrd'],4),
                              (['decode','-i',good,'-o',temp/'x.nrrd','--input-format','htj2k'],4),
                              (['decode','-i',ht_good,'-o',temp/'x.nrrd','--input-format','j2k'],4),
                              (['transcode','-i',good,'-o',temp/'x.j2k','--output-format','j2k'],4),
                              (['transcode','-i',ht_good,'-o',temp/'x.j2k','--output-format','htj2k'],4),
                              (['transcode','-i',good,'-o',temp/'x.j2k','--output-format','nrrd'],4),
                              (['transcode','-i',good,'-o',temp/'x.j2k','--levels','1'],4),
                              (['decode','-i',good,'-o',temp/'x.nrrd','--mode','lossy'],4),(['decode','-i',good,'-o',temp/'x.nrrd','--backend','metal'],4),
                              (['validate','-i',fixtures/'g16_256x256_smooth.opj.j2k','--timeout','0.000001'],5),
                              (['validate','-i',fixtures/'g16_256x256_smooth.opj.j2k','--max-memory','1000'],5),
                              (['validate','-i',temp/'missing.j2k'],6),(['decode','-i',good,'-o',temp/'no such dir'/'x.nrrd'],6)]:
                r=cli(*form,expected=code);assert not r.stdout and r.stderr,(form,r.stderr)
                assert not (temp/'x.j2k').exists() and not (temp/'x.nrrd').exists()
            # A rejected NRRD profile field never reaches the encoder.
            detached=temp/'detached.nrrd';detached.write_bytes(b'NRRD0004\ntype: uint16\ndimension: 2\nsizes: 2 2\nencoding: raw\nendian: little\ndata file: other.raw\n\n'+bytes(8))
            cli('encode','-i',detached,'-o',temp/'x.j2k',expected=4);assert not (temp/'x.j2k').exists()
            gzipped=temp/'gzip.nrrd';gzipped.write_bytes(b'NRRD0004\ntype: uint16\ndimension: 2\nsizes: 2 2\nencoding: gzip\nendian: little\n\n'+bytes(8))
            cli('encode','-i',gzipped,'-o',temp/'x.j2k',expected=4)
            short=temp/'short.nrrd';short.write_bytes(b'NRRD0004\ntype: uint16\ndimension: 2\nsizes: 2 2\nencoding: raw\nendian: little\n\n'+bytes(6))
            cli('encode','-i',short,'-o',temp/'x.j2k',expected=3)
            # Milestone 12 CLI & consumer breadth: multi-format I/O (PGM/PPM/PNM/PNG/TIFF/RAW),
            # convert, compare, batch, encode3d, decode3d, jpip, benchmark, and completions.
            for m12_verb in ['convert','compare','batch','encode3d','decode3d','jpip','benchmark','completions']:
                vh=cli(m12_verb,'--help').stdout
                assert 'USAGE:' in vh and 'EXIT STATUS' in vh
            # Multi-format encode/decode/convert/compare (PGM, PPM, PNG, TIFF, RAW, NRRD).
            pgm_src=fixtures/'g12_129x67_gradient.pgm'
            pgm_j2k=temp/'from_pgm.j2k';dec_png=temp/'dec_12.png';dec_tiff=temp/'dec_12.tiff';dec_raw=temp/'dec_12.raw';dec_pgm=temp/'dec_12.pgm'
            r_pgm_enc=cli('encode','-i',pgm_src,'-o',pgm_j2k,'--json')
            assert json.loads(r_pgm_enc.stderr)['meaningfulBits']==12
            cli('decode','-i',pgm_j2k,'-o',dec_png,'--json')
            cli('decode','-i',pgm_j2k,'-o',dec_tiff,'--json')
            cli('decode','-i',pgm_j2k,'-o',dec_raw,'--json')
            cli('decode','-i',pgm_j2k,'-o',dec_pgm,'--json')
            assert pgm_samples(dec_pgm)==pgm_samples(pgm_src)
            # Encode from PNG, TIFF, and RAW (with explicit dimensions/bit-depth) and verify bit-exactness via compare.
            png_j2k=temp/'from_png.j2k';tiff_j2k=temp/'from_tiff.j2k';raw_j2k=temp/'from_raw.j2k'
            cli('encode','-i',dec_png,'-o',png_j2k,'--json')
            cli('encode','-i',dec_tiff,'-o',tiff_j2k,'--json')
            cli('encode','-i',dec_raw,'--input-format','raw','--dimensions','129x67','--bit-depth','12','-o',raw_j2k,'--json')
            for cand in [dec_png,dec_tiff,png_j2k,tiff_j2k,raw_j2k]:
                cmp_res=json.loads(cli('compare','-i',pgm_src,'-r',cand,'--bit-exact','--json').stdout)
                assert cmp_res['passed'] is True and cmp_res['bitExact'] is True and cmp_res['maxError']==0
            # Compare lossy image with thresholds and verify failure exit 3 when bit-exact is requested on lossy.
            cmp_lossy=json.loads(cli('compare','-i',rgb_nrrd,'-r',rgb_ict,'--max-error','80','--min-psnr','20','--json').stdout)
            assert cmp_lossy['passed'] is True and len(cmp_lossy['components'])==3
            cli('compare','-i',rgb_nrrd,'-r',rgb_ict,'--bit-exact','--json',expected=3)
            # Convert across uncompressed formats (NRRD -> PPM -> PNG -> TIFF -> NRRD) and --bit-depth scaling.
            conv_ppm=temp/'conv_rgb.ppm';conv_png=temp/'conv_rgb.png';conv_tiff=temp/'conv_rgb.tiff';conv_png16=temp/'conv_rgb16.png'
            r_c1=cli('convert','-i',rgb_nrrd,'-o',conv_ppm,'--json')
            assert json.loads(r_c1.stderr)['outputFormat']=='ppm'
            cli('convert','-i',conv_ppm,'-o',conv_png,'--json')
            cli('convert','-i',conv_png,'-o',conv_tiff,'--json')
            assert json.loads(cli('compare','-i',rgb_nrrd,'-r',conv_tiff,'--bit-exact','--json').stdout)['bitExact'] is True
            r_c16=cli('convert','-i',conv_png,'-o',conv_png16,'--bit-depth','16','--json')
            assert json.loads(r_c16.stderr)['bitDepth']==16
            cli('convert','-i',conv_png,'-o',temp/'same.png',expected=4)
            cli('convert','-i',rgb_jp2,'-o',temp/'bad.png',expected=4)
            # Batch encode, transcode, and decode with bounded worker pool (--threads 2).
            batch_in=temp/'batch_in';batch_j2k=temp/'batch_j2k';batch_jph=temp/'batch_jph';batch_dec=temp/'batch_dec'
            batch_in.mkdir()
            shutil.copy(fixtures/'g08_37x23_random.pgm',batch_in/'img1.pgm')
            shutil.copy(fixtures/'g16_17x9_alternating.pgm',batch_in/'img2.pgm')
            r_be=cli('batch','encode','-i',batch_in,'-o',batch_j2k,'--filter','*.pgm','--threads','2','--json')
            be_rep=json.loads(r_be.stdout)
            assert be_rep['succeeded']==2 and be_rep['failed']==0 and be_rep['threads']==2
            r_bt=cli('batch','transcode','-i',batch_j2k,'-o',batch_jph,'--output-format','jph','--threads','2','--json')
            assert json.loads(r_bt.stdout)['succeeded']==2
            r_bd=cli('batch','decode','-i',batch_jph,'-o',batch_dec,'--output-suffix','.png','--threads','2','--json')
            assert json.loads(r_bd.stdout)['succeeded']==2 and (batch_dec/'img1.png').is_file() and (batch_dec/'img2.png').is_file()
            # 3D volumetric encode3d, decode3d, and 3D compare.
            slices_in=temp/'slices_in';slices_in.mkdir()
            for z in range(4):
                s_bytes=bytes(((x+y+z*11)&255) for y in range(12) for x in range(16))
                (slices_in/f'slice_{z:04d}.pgm').write_bytes(f'P5\n16 12\n255\n'.encode()+s_bytes)
            vol_j3d=temp/'vol.j3d';vol_nrrd=temp/'vol.nrrd';vol_ht_j3d=temp/'vol_ht.j3d';slices_out=temp/'slices_out';vol_roi=temp/'vol_roi.nrrd'
            r_e3d=cli('encode3d','-i',slices_in,'-o',vol_j3d,'--codec','j2k-lossless','--tile-size','16x12x4','--levels','1,1,1','--spacing','0.5,0.5,1.5','--origin','0,0,0','--json')
            e3d_rep=json.loads(r_e3d.stderr)
            assert e3d_rep['width']==16 and e3d_rep['height']==12 and e3d_rep['depth']==4 and e3d_rep['lossless'] is True
            r_d3d=cli('decode3d','-i',vol_j3d,'-o',vol_nrrd,'--json')
            assert json.loads(r_d3d.stderr)['depth']==4 and vol_nrrd.is_file()
            r_e3d_ht=cli('encode3d','-i',vol_nrrd,'-o',vol_ht_j3d,'--codec','htj2k-lossless','--levels','1,1,1','--json')
            assert json.loads(r_e3d_ht.stderr)['lossless'] is True
            cmp3d=json.loads(cli('compare','-i',vol_nrrd,'-r',vol_ht_j3d,'--mode','3d','--bit-exact','--json').stdout)
            assert cmp3d['passed'] is True and cmp3d['bitExact'] is True and cmp3d['depth']==4
            cli('decode3d','-i',vol_ht_j3d,'-o',slices_out,'--output-format','pgm','--slice-naming','slice_%04d.pgm','--json')
            assert len(list(slices_out.glob('slice_*.pgm')))==4
            r_d3d_roi=cli('decode3d','-i',vol_j3d,'-o',vol_roi,'--region','2,2,1,8,6,2','--json')
            d3d_roi_rep=json.loads(r_d3d_roi.stderr)
            assert d3d_roi_rep['width']==8 and d3d_roi_rep['height']==6 and d3d_roi_rep['depth']==2
            # JPIP client & server (loopback single-file session, ROI request, and --once server).
            jpip_full=temp/'jpip_full.nrrd';jpip_roi=temp/'jpip_roi.png'
            r_jc=cli('jpip','client','--single-file',rgb_jp2,'--port','18493','-o',jpip_full,'--json')
            jc_rep=json.loads(r_jc.stdout)
            assert jc_rep['width']==16 and jc_rep['height']==12 and jc_rep['components']==3
            assert json.loads(cli('compare','-i',rgb_nrrd,'-r',jpip_full,'--bit-exact','--json').stdout)['bitExact'] is True
            r_jroi=cli('jpip','client','--single-file',rgb_jp2,'--port','18494','--region','2,2,8,6','--resolution-level','0','--quality-layers','1','-o',jpip_roi,'--json')
            jroi_rep=json.loads(r_jroi.stdout)
            assert jroi_rep['width']==8 and jroi_rep['height']==6 and jpip_roi.is_file()
            r_jsrv=cli('jpip','server','--single-file',rgb_jp2,'--port','18495','--once','--json')
            assert json.loads(r_jsrv.stdout)['status']=='stopped'
            # In-process benchmark (zero external process invocations, text/json/csv).
            bench_csv=temp/'bench.csv'
            r_bm=cli('benchmark','-i',rgb_nrrd,'--runs','2','--warmup','1','--compare-all','--json')
            bm_rep=json.loads(r_bm.stdout)
            assert bm_rep['runs']==2 and len(bm_rep['presets'])==3
            cli('benchmark','-i',rgb_nrrd,'--runs','1','--warmup','0','--format','csv','-o',bench_csv)
            assert 'preset,operation,runs,median_ms' in bench_csv.read_text()
            # Shell completions (bash, zsh, fish, and invalid shell error).
            for sh in ['bash','zsh','fish']:
                comp_out=cli('completions',sh).stdout
                assert 'encode3d' in comp_out and 'jpip' in comp_out and 'benchmark' in comp_out
            cli('completions','powershell',expected=2)
            # SIGINT before the payload arrives: the interrupt is remembered and the
            # operation cancels cooperatively before decoding starts (exit 130, no output).
            import signal,time
            proc=subprocess.Popen([str(binary),'decode','-i','-','-o',str(temp/'interrupted.nrrd')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            time.sleep(0.3);proc.send_signal(signal.SIGINT);time.sleep(0.05)
            o,e=proc.communicate(input=(fixtures/'g10_300x200_gradient.opj_n1.j2k').read_bytes(),timeout=30)
            report['commands'].append({'argv':['decode','-i','-','(SIGINT while waiting for stdin)'],'exit_code':proc.returncode,'expected_exit_code':130,'stderr':e.decode(errors='replace')});save()
            assert proc.returncode==130 and not o and not (temp/'interrupted.nrrd').exists(),(proc.returncode,e)
        report['status']='passed';report['checks']=len(report['commands']);save()
        print(f'{tool}: {len(report["commands"])} process checks passed');return 0
    except Exception as error:
        report['status']='failed';report['failure']=str(error);save();raise
if __name__=='__main__':sys.exit(main())
