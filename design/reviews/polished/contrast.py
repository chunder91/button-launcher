def h(c):c=c.lstrip('#');return [int(c[i:i+2],16) for i in (0,2,4)]
def L(c):
  r=[]
  for v in h(c):
    v/=255;r.append(v/12.92 if v<=.03928 else ((v+.055)/1.055)**2.4)
  return .2126*r[0]+.7152*r[1]+.0722*r[2]
def cr(a,b):a,b=L(a),L(b);return (max(a,b)+.05)/(min(a,b)+.05)
def mix(c,t,p):return '#'+''.join('%02X'%round(x+(y-x)*p) for x,y in zip(h(c),h(t)))
B={'RedDog':'#0B6E99','Register':'#0E7A4B','Internet':'#7B4FD6','Email':'#FACC15','Guides':'#5F6368','PLCE':'#C40000','Revenue':'#F0E68C','Jartrek':'#8A6100'}
dark={'Email','Revenue'}
for name,(tl,bd,hv) in {'D1':(.06,.06,.06),'D2':(.12,.16,.06)}.items():
  print(name)
  for k,f in B.items():
    fg='#111111' if k in dark else '#FFFFFF'
    top=mix(f,'#FFFFFF',tl);bot=mix(f,'#000000',bd)
    htop=mix(top,'#FFFFFF',hv);hbot=mix(bot,'#FFFFFF',hv)
    if k in dark: htop=mix(top,'#FFFFFF',hv)
    print(f" {k:9} top {top} {cr(top,fg):.2f} bot {bot} {cr(bot,fg):.2f} | hover top {htop} {cr(htop,fg):.2f} bot {hbot} {cr(hbot,fg):.2f} | bot vs panel {cr(bot,'#141414'):.2f}")
for c in ['#2A2A2A','#333333','#202020','#262626']: print(c,cr(c,'#FFFFFF'),cr('#E5484D',c))
print('FINAL')
import json
out={}
def row(k,f,stops):
  fg='#111111' if k in dark else '#FFFFFF'
  cs=[mix(f,'#000000',p) if p>=0 else mix(f,'#FFFFFF',-p) for p in stops]
  return cs,[round(cr(c,fg),2) for c in cs]
# D1 rest top -4 bot -12 ; hover 0 / -8 ; pressed -10/-18 ; dark-label buttons: rest +4/-6 hover +10/0
# D2 rest top 0 + sheen (8% white on top 30%) / bot -22 ; hover sheen 12% top 0 / -16 ; pressed -12/-30
sp={'D1':{'rest':(.04,.12),'hover':(0,.08),'press':(.10,.18)},'D2':{'rest':(-.08,.22),'hover':(-.12,.16),'press':(.08,.30)}}
spd={'D1':{'rest':(-.04,.06),'hover':(-.10,0),'press':(.04,.12)},'D2':{'rest':(-.10,.14),'hover':(-.16,.08),'press':(.06,.20)}}
for d in sp:
  print(d)
  for k,f in B.items():
    s=spd[d] if k in dark else sp[d]
    line=f" {k:9}"
    for st,v in s.items():
      cs,rs=row(k,f,v);line+=f" {st}: {cs[0]}→{cs[1]} ({rs[0]}/{rs[1]})"
    print(line)
print('D2b')
sp['D2']={'rest':(0,.26),'hover':(-.04,.18),'press':(.10,.32)}
spd['D2']={'rest':(-.08,.14),'hover':(-.14,.06),'press':(.06,.22)}
for k,f in B.items():
    s=spd['D2'] if k in dark else sp['D2']
    line=f" {k:9}"
    for st,v in s.items():
      cs,rs=row(k,f,v);line+=f" {st}: {cs[0]}→{cs[1]} ({rs[0]}/{rs[1]})"
    print(line)
# glow/edge colors vs panel
for k,f in B.items(): print(k,'glow(B+30%white) vs panel',round(cr(mix(f,'#FFFFFF',.3),'#141414'),2), mix(f,'#FFFFFF',.3))
# panel mica tints
for c in ['#1C1C1E','#202024','#16161A']: print(c,round(cr(c,'#FFFFFF'),2),round(cr(c,'#A0A0A0'),2))
print('restart D2 #262626/#1E1E1E', cr('#262626','#FFFFFF'), cr('#1E1E1E','#E5484D'), cr('#E5484D','#262626'))
print('focus white vs panel',cr('#FFFFFF','#1C1C1E'),'disabled', cr('#8A8A8A','#2A2A2A'))
