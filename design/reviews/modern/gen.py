# Generates option-a.html / option-b.html (box mockups). Run: python3 gen.py
import json, base64
def b64(ic): return base64.b64encode(open('assets/'+ic,'rb').read()).decode()
def hx(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
def lum(h):
    f=lambda v:(v/255)/12.92 if v/255<=0.03928 else ((v/255+0.055)/1.055)**2.4
    r,g,b=hx(h); return .2126*f(r)+.7152*f(g)+.0722*f(b)
def cr(a,b): A,B=lum(a),lum(b); return (max(A,B)+.05)/(min(A,B)+.05)
def mix(a,b,t): A,B=hx(a),hx(b); return '#%02X%02X%02X'%tuple(round(A[i]*(1-t)+B[i]*t) for i in range(3))
# Kern palette: key -> (fill, label)
K={'cyan':('#0B6E99','#FFFFFF'),'green':('#0E7A4B','#FFFFFF'),'violet':('#7B4FD6','#FFFFFF'),'yellow':('#FACC15','#111111'),
   'grey':('#5F6368','#FFFFFF'),'red':('#C40000','#FFFFFF'),'khaki':('#F0E68C','#111111'),'salmon':('#B8432F','#FFFFFF'),
   'gold':('#8A6100','#FFFFFF'),'danger':('#B3261E','#FFFFFF')}
# Restart tiles (Squint Major 1): neutral dark fill, white label, red icon + 2px red outline. PLCE stays the only solid red.
RESTART_FILL='#2A2A2A'; RESTART_RED='#E5484D'   # #E5484D: 4.71:1 vs panel, 3.67:1 vs tile (Kern danger #B3261E only 2.82:1)
RESTARTS=('rsc','rpc')
# Option A: tinted dark tile (accent mixed 70% toward #262626) + full-colour icon chip + 3px accent bar
A={k:(mix(v[0],'#262626',0.62),'#FFFFFF') for k,v in K.items()}
top=[('Red Dog Back Office','',"reddog.png",'cyan','full','hero'),('View Register','','register.png','green','full','row'),
     ('Internet','','globe.png','violet','half','row'),('Email','','email.png','yellow','half','row')]
bot=[('Back Office User Guide','Version 11','guide.png','grey','half','tall'),('Register User Guide','Version 11','guide.png','grey','half','tall'),
     ('PLCE','','badge.png','red','half','row'),('Department of Revenue','','revenue.png','khaki','half','row'),
     ('Start Jartrek Security','','security.png','gold','full','row','missing'),
     ('DANGER',),('Restart<br>ScreenConnect','','screenconnect.png','rsc','half','tall'),('Restart<br>Computer','','power.png','rpc','half','tall')]
def tile(b,opt,extra=''):
    lab,sub,ic,key,w,kind=b[:6]; missing=len(b)>6
    restart=key in RESTARTS
    if restart: fill,fg,acc=RESTART_FILL,'#FFFFFF',RESTART_RED
    else: fill,fg=(K if opt=='b' else A)[key]; acc=K[key][0]
    rd=ic=='reddog.png'
    isz={'hero':40,'row':32 if w=='full' else 24,'tall':24}[kind]
    if restart: icon=f'<span class="ic" style="width:{isz}px;height:{isz}px;background:{RESTART_RED};-webkit-mask:url(data:image/png;base64,{b64(ic)}) center/contain no-repeat"></span>'
    elif rd: icon=f'<span class="plate"><img src="assets/reddog.png" style="width:64px;height:64px"></span>'
    elif opt=='a': icon=f'<span class="chip" style="background:{acc}"><img src="assets/{ic}" style="width:{isz}px;height:{isz}px"></span>'
    else: icon=f'<img class="ic" src="assets/{ic}" style="width:{isz}px;height:{isz}px">'
    fs={'hero':22,'row':16 if w=='full' else 13,'tall':13}[kind]
    lbl=f'<span class="lb" style="font-size:{fs}px">{lab}'+(f'<small>{sub}</small>' if sub else '')+'</span>'
    if restart: extra+=' restart'
    cls=f"t {w} {kind} "+('above' if kind=='tall' else '')+' '+extra
    bar=f'<i class="bar" style="background:{acc}"></i>' if opt=='a' and not restart else ''
    dot='<b class="dot" title="Not set up on this PC yet"></b><span class="tip">Not set up on this PC yet</span>' if missing else ''
    return f'<div class="{cls}" style="background:{fill};color:{fg}">{bar}{icon}{lbl}{dot}</div>'
def panel(name,btns,opt,editing=False):
    h=f'<div class="panel{" editing" if editing else ""}"><div class="pt">{name} panel'+(' <em>locked</em>' if not editing else '')+'</div>'
    if editing: h+='<div class="ebar" title="Editing: right-click a button to change it. Lock when done.">Editing: right-click a button to change it. Lock when done.</div>'
    h+='<div class="grid">'
    for b in btns:
        if b[0]=='DANGER': h+='</div><div class="dz">Restarts</div><div class="grid danger">'; continue
        h+=tile(b,opt)
    return h+'</div></div>'
CSS='''
*{box-sizing:border-box} body{margin:0;background:#E9E9E9;font-family:"Inter","Noto Sans",sans-serif;font-weight:600;color:#111;padding:18px}
h1{font-size:18px;margin:0 0 2px} .note{font-size:12px;font-weight:500;color:#444;margin:0 0 12px;max-width:1500px}
.row{display:flex;gap:22px;align-items:flex-start}
.panel{width:290px;background:#141414;border-radius:14px;padding:6px;box-shadow:0 8px 24px rgba(0,0,0,.35)}
.pt{color:#9AA0A6;font-size:11px;padding:2px 4px 6px} .pt em{font-style:normal;color:#5F6368}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.t{position:relative;border-radius:8px;display:flex;align-items:center;gap:10px;padding:8px 12px;min-height:72px;
   box-shadow:inset 0 1px 0 rgba(255,255,255,.08);transition:transform 120ms ease-out,box-shadow 120ms ease-out,filter 120ms ease-out}
.t.full{grid-column:span 2} .t.hero{min-height:120px} .t.tall{min-height:92px}
.t.above{flex-direction:column;justify-content:center;gap:6px;text-align:center}
.lb{line-height:1.2;min-width:0;hyphens:manual} .lb small{display:block;font-size:11px;font-weight:500;opacity:.85}
.plate{background:#fff;border-radius:8px;padding:4px;display:inline-flex;flex:none}
.chip{border-radius:7px;padding:5px;display:inline-flex;flex:none}
.ic{flex:none}
.bar{position:absolute;left:0;top:0;bottom:0;width:4px}
.dot{position:absolute;top:6px;right:6px;width:8px;height:8px;border-radius:50%;background:#F59E0B;box-shadow:0 0 0 1.5px #141414}
.dz{color:#F28B82;font-size:10px;letter-spacing:.08em;text-transform:uppercase;margin:12px 4px 4px;border-top:1px solid #3A1D1B;padding-top:6px}
.danger{padding:4px;border-radius:10px;background:rgba(179,38,30,.14);outline:1px solid rgba(179,38,30,.45)}
.editing .t{outline:2px dashed rgba(255,255,255,.6);outline-offset:-4px}
.ebar{height:28px;line-height:28px;background:#F59E0B;color:#111;border-radius:8px;font-size:12px;padding:0 10px;margin-bottom:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.restart{box-shadow:inset 0 0 0 2px #E5484D,inset 0 1px 0 rgba(255,255,255,.08)}
.tip{position:absolute;top:-20px;right:-4px;background:#F2F2F2;color:#111;font-size:11px;font-weight:500;padding:3px 7px;border-radius:5px;box-shadow:0 2px 6px rgba(0,0,0,.4);white-space:nowrap;z-index:2}
.hover{transform:translateY(-1px);box-shadow:0 4px 10px rgba(0,0,0,.35),inset 0 1px 0 rgba(255,255,255,.08);filter:brightness(1.06)}
.pressed{transform:none;box-shadow:none;filter:brightness(.92)}
.focus{outline:2px solid #fff;outline-offset:2px}
.states{background:#141414;border-radius:14px;padding:12px;width:290px}
.states .cap{color:#9AA0A6;font-size:10px;margin:8px 0 3px}
.small .t{min-height:44px;padding:4px 10px} .small .t .lb{font-size:12px!important}
.menu{background:#2B2B2B;color:#EEE;border-radius:8px;width:220px;padding:5px;font-size:12.5px;font-weight:500;box-shadow:0 8px 24px rgba(0,0,0,.4)}
.menu div{padding:6px 10px;border-radius:5px} .menu .h{background:#3A3A3A} .menu hr{border:0;border-top:1px solid #444;margin:4px 0}
.menu .k{float:right;color:#9AA0A6}
.anim{font-size:11px;font-weight:500;color:#C9CDD2;margin-top:8px;line-height:1.45}
'''
def page(opt,title,desc):
    btn=('View Register','','register.png','green','full','row')
    st=f'''<div class="states"><div class="cap">Normal</div>{tile(btn,opt)}<div class="cap">Hover (lift 1px, shadow 0 4 10 #000 35%, fill +6%)</div>{tile(btn,opt,'hover')}
<div class="cap">Pressed (no lift, fill −8%)</div>{tile(btn,opt,'pressed')}<div class="cap">Keyboard focus (2px white ring, 2px offset)</div>{tile(btn,opt,'focus')}
<div class="anim">Animation: hover 120ms ease-out (translateY −1, shadow in) · press 60ms (fill −8%, optional scale 0.98) · launch flash white 45%: 60ms in / 240ms out, runs after the launch starts (never delays it) · all ≤150ms.</div>
<div class="cap" style="margin-top:12px">Small size strip (44px tiles, 12px floor)</div>
<div class="grid small">{tile(('Internet','','globe.png','violet','half','row'),opt)}{tile(('Email','','email.png','yellow','half','row'),opt)}
{tile(('Restart Computer','','power.png','rpc','half','row'),opt)}{tile(('PLCE','','badge.png','red','half','row'),opt)}</div></div>'''
    menu='''<div><div class="cap" style="color:#555;font-size:11px;margin-bottom:4px">Right-click menu (unlocked), inset</div><div class="menu">
<div class="h">Lock panels <span class="k">✓</span></div><div>Always on top</div><div>Size ▸</div><div>Monitor ▸</div><div>Start with Windows <span class="k">✓</span></div><hr>
<div>Edit this button…</div><div>Move ▸</div><div style="height:44px;line-height:1.25;padding-top:5px">Setup ▸<br><span style="font-size:12px;color:#A0A0A0">PC setup, panels, installer</span></div><hr>
<div>Close this panel</div><div>Close all…</div></div>
<div class="cap" style="color:#555;font-size:11px;margin:10px 0 4px">Locked menu</div><div class="menu"><div>Unlock to edit…</div><hr><div>Close this panel</div></div></div>'''
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>{title}</title><style>{CSS}</style></head><body>
<h1>{title} — BOX MOCKUP (HTML in headless Chrome), not a Windows capture</h1>
<p class="note">{desc} Font: Inter SemiBold as a stand-in for Segoe UI Variable Semibold. Icons: Set A from src/images; Red Dog full-colour logo on a white plate. Amber dot = "not set up on this PC" example (Start Jartrek Security).</p>
<div class="row">{panel("Top",top,opt)}{panel("Bottom",bot,opt)}{panel("Bottom",bot,opt,True)}{st}{menu}</div></body></html>'''
open('option-a.html','w').write(page('a','Option A · Windows 11 dark','Dark Mica-like panel. Tiles are tinted dark versions of each button\'s own colour, with a 4px accent bar and a full-colour icon chip so each button keeps its colour.'))
open('option-b.html','w').write(page('b','Option B · Bold flat colourful','Dark panel, solid AA-safe fills from Kern\'s palette, white or #111 labels as contrast needs.'))
rows=[]
for k,(f,fg) in K.items(): rows.append((k,f,fg,cr(f,fg),A[k][0],cr(A[k][0],'#FFFFFF'),cr(f,'#141414')))
json.dump(rows,open('contrast-raw.json','w'),indent=1)   # contrast.json (rev 2) is the curated summary
for r in rows: print('%-7s B %s/%s %.2f | A tile %s/#FFF %.2f | B fill vs panel %.2f'%r)
