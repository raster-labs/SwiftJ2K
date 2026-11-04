import os,threading,time

def emit(fd,label):
 for i in range(100):
  data=f'{label}-{i}-λ\n'.encode()
  os.write(fd,data[:len(data)-2]);time.sleep(.0001);os.write(fd,data[len(data)-2:])
 os.write(fd,(label+'-tail-λ').encode())
ts=[threading.Thread(target=emit,args=(fd,label)) for fd,label in [(1,'out'),(2,'err')]]
for t in ts:t.start()
for t in ts:t.join()
