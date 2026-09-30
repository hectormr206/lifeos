import sys
from PIL import Image
names=sys.argv[2:]; out=sys.argv[1]
ims=[Image.open(n+'.png').convert('RGB') for n in names]
w=360
ims=[i.resize((w,int(i.size[1]*w/i.size[0]))) for i in ims]
H=max(i.size[1] for i in ims)
s=Image.new('RGB',(w*len(ims),H),'white')
for k,i in enumerate(ims): s.paste(i,(k*w,0))
s.save(out)
