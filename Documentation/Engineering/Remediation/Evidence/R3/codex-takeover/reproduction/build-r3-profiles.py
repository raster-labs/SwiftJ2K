from pathlib import Path
import os,subprocess,sys
w=Path(__file__).resolve().parent
for variant,source in [('baseline','performance-baseline-source'),('candidate','diagnostic-source-05')]:
 env=os.environ.copy();env['SWIFTJ2K_VALIDATION_SOURCE']=str(w/source)
 args=[sys.executable,str(w/'run-validation.py'),'profile-'+variant+'-build-01','swift','build',
       '--package-path',str(w/('r3-profile-'+variant)),
       '--scratch-path',str(w/('r3-profile-'+variant+'-build')),
       '--cache-path',str(w/'swiftpm-cache'),'--config-path',str(w/'swiftpm-config'),
       '--security-path',str(w/'swiftpm-security'),'--disable-sandbox','--build-system','native',
       '-c','release','-j','4','--product','r3-profile']
 r=subprocess.run(args,env=env)
 if r.returncode:sys.exit(r.returncode)
