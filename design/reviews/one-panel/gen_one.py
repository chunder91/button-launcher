# One-panel mockups (BOX MOCKUPS). Reuses Option B tile/CSS from ../modern/gen.py. Run: python3 gen_one.py
import os
src=open('../modern/gen.py').read(); src=src[:src.index('def page(')]
g={}; os.chdir(os.path.dirname(os.path.abspath(__file__))); exec(src,g)
tile,CSS,top,bot=g['tile'],g['CSS'],g['top'],g['bot']
ICONS={ # simple stand-in glyphs (real build uses each target's own icon via ExtractAssociatedIcon)
 'notepad':'<svg viewBox="0 0 32 32"><rect x="6" y="4" width="20" height="24" rx="3" fill="#4FC3F7"/><path d="M10 11h12M10 15h12M10 19h8" stroke="#0B3954" stroke-width="2"/></svg>',
 'chrome':'<svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="13" fill="#DB4437"/><path d="M16 16 L28 22 A13 13 0 0 1 6 24Z" fill="#0F9D58"/><path d="M16 16 L6 24 A13 13 0 0 1 16 3 Z" fill="#F4B400"/><circle cx="16" cy="16" r="6" fill="#fff"/><circle cx="16" cy="16" r="4.5" fill="#4285F4"/></svg>',
 'pdf':'<svg viewBox="0 0 32 32"><path d="M8 3h12l6 6v20H8z" fill="#F5F5F5"/><path d="M20 3v6h6" fill="#ccc"/><rect x="5" y="16" width="18" height="9" rx="2" fill="#D93025"/><text x="14" y="23" font-size="7" font-family="Inter" font-weight="800" fill="#fff" text-anchor="middle">PDF</text></svg>',
 'ps1':'<svg viewBox="0 0 32 32"><rect x="3" y="5" width="26" height="22" rx="4" fill="#012456"/><path d="M8 11l6 5-6 5" stroke="#fff" stroke-width="2.4" fill="none"/><path d="M16 22h8" stroke="#fff" stroke-width="2.4"/></svg>',
 'excel':'<svg viewBox="0 0 32 32"><rect x="4" y="4" width="24" height="24" rx="4" fill="#107C41"/><path d="M11 10l10 12M21 10L11 22" stroke="#fff" stroke-width="3"/></svg>',
 'calc':'<svg viewBox="0 0 32 32"><rect x="7" y="3" width="18" height="26" rx="3" fill="#5F6368"/><rect x="10" y="6" width="12" height="5" fill="#C8E6C9"/><g fill="#fff"><rect x="10" y="14" width="3" height="3"/><rect x="14.5" y="14" width="3" height="3"/><rect x="19" y="14" width="3" height="3"/><rect x="10" y="19" width="3" height="3"/><rect x="14.5" y="19" width="3" height="3"/><rect x="19" y="19" width="3" height="8"/></g></svg>',
 'web':'<svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="12" fill="#1A73E8"/><path d="M4 16h24M16 4c-5 6-5 18 0 24M16 4c5 6 5 18 0 24" stroke="#fff" stroke-width="1.8" fill="none"/></svg>',
 'folder':'<svg viewBox="0 0 32 32"><path d="M3 9a2 2 0 0 1 2-2h7l3 3h12a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="#F9C74F"/></svg>'}
MID=[('Notepad','notepad','program'),('Chrome','chrome','program'),('Price List.pdf','pdf','file'),('Daily Backup.ps1','ps1','script'),
     ('Nightly Report.xlsx','excel','file'),('KBS Portal','web','website'),('Calculator','calc','program'),('Shared Drive','folder','file')]
def mid(edit=False,n=8,cols=2,scroll=False):
    h='<div class="mid">'+('<div class="hint">Drag ⠿ to reorder · × to remove</div>' if edit else '')+f'<div class="mg" style="grid-template-columns:repeat({cols},1fr)">'
    for lab,ic,kind in MID[:n]:
        h+=f'<div class="mi{" ed" if edit else ""}" title="{kind}">'+('<b class="x">×</b><span class="hd">⠿</span>' if edit else '')+f'<span class="mic">{ICONS[ic]}</span><span class="ml">{lab}</span></div>'
    if edit: h+='<div class="mi add"><span class="plus">+</span><span class="ml">Add icon</span></div>'
    h+='</div>'
    if scroll: h+='<div class="more">▾ 4 more (scroll)</div>'
    return h+'</div>'
def group(btns):
    h='<div class="grid">'
    for b in btns:
        if b[0]=='DANGER': h+='</div><div class="dz">Restarts</div><div class="grid danger">'; continue
        h+=tile(b,'b')
    return h+'</div>'
TOP=top; BOT=[b for b in bot]
EX='''
html,body{margin:0;padding:0;background:#000}
.desk{position:relative;overflow:hidden;font-family:Inter,"Noto Sans",sans-serif;
 background:radial-gradient(1200px 700px at 78% 45%,rgba(255,214,120,.95),transparent 60%),radial-gradient(900px 600px at 20% 30%,rgba(0,120,215,.85),transparent 65%),
 radial-gradient(800px 500px at 60% 90%,rgba(170,60,200,.7),transparent 60%),url(wall.png) center/cover}
.tag{position:absolute;left:16px;top:12px;background:rgba(255,255,255,.92);color:#111;font:600 15px Inter;padding:6px 10px;border-radius:6px;z-index:9}
.dicons{position:absolute;left:14px;top:60px;display:grid;gap:18px;color:#fff;font:500 12px "Noto Sans";text-shadow:0 1px 3px #000;text-align:center}
.dicons div{width:76px} .dicons i{display:block;width:44px;height:44px;margin:0 auto 4px;border-radius:6px}
.win{position:absolute;right:0;top:0;width:290px;display:flex;flex-direction:column}
.seg{background:#141414;padding:6px;border-radius:14px 0 0 14px;box-shadow:0 8px 24px rgba(0,0,0,.45)}
.seg.top{border-radius:0 0 0 14px} .seg.bot{border-radius:14px 0 0 0}
.mid{flex:1;overflow:hidden;display:flex;flex-direction:column;justify-content:center;padding:10px 8px;position:relative;min-height:0}
.mg{display:grid;gap:10px}
.mi{position:relative;display:flex;flex-direction:column;align-items:center;gap:5px;padding:10px 6px 8px;border-radius:12px;
 background:rgba(20,20,20,.55);backdrop-filter:blur(14px) saturate(1.2);-webkit-backdrop-filter:blur(14px);box-shadow:0 2px 8px rgba(0,0,0,.25),inset 0 1px 0 rgba(255,255,255,.10)}
.mic svg{width:32px;height:32px;display:block} .ml{color:#fff;font:600 11.5px Inter;text-align:center;line-height:1.2}
.mi.ed{outline:2px dashed rgba(255,255,255,.7);outline-offset:-3px}
.x{position:absolute;top:-6px;right:-6px;width:18px;height:18px;border-radius:50%;background:#E5484D;color:#fff;font:700 13px/18px Inter;text-align:center;box-shadow:0 0 0 2px #141414}
.hd{position:absolute;top:4px;left:7px;color:#ddd;font-size:13px}
.add{background:rgba(245,158,11,.18);outline:2px dashed #F59E0B;outline-offset:-3px} .plus{color:#F59E0B;font:700 26px/32px Inter;height:32px}
.hint{align-self:center;background:rgba(20,20,20,.7);color:#fff;font:500 11px Inter;padding:4px 10px;border-radius:10px;margin-bottom:8px}
.more{align-self:center;margin-top:8px;background:rgba(20,20,20,.7);color:#fff;font:600 11px Inter;padding:4px 10px;border-radius:10px}
.edge{position:absolute;right:0;width:290px;border-left:1px dashed rgba(255,255,255,.55);pointer-events:none}
.callout{position:absolute;background:#fff;color:#111;font:500 12px Inter;padding:6px 9px;border-radius:6px;max-width:220px;box-shadow:0 3px 10px rgba(0,0,0,.35)}
.taskbar{position:absolute;left:0;right:0;bottom:0;height:48px;background:rgba(32,32,32,.88);backdrop-filter:blur(20px);display:flex;align-items:center;justify-content:center;gap:10px}
.taskbar i{width:30px;height:30px;border-radius:6px;background:#3a3a3a;display:block} .taskbar i.s{background:#0078D4}
.clock{position:absolute;right:14px;color:#fff;font:500 12px "Noto Sans";text-align:right;line-height:1.3}
.ebar{border-radius:8px}
.compact .t{min-height:46px;padding:4px 10px} .compact .t.hero{min-height:64px} .compact .t.tall{min-height:58px;gap:2px}
.compact .t .lb{font-size:12px!important} .compact .plate img{width:44px!important;height:44px!important}
.compact .t.tall .ic{width:18px!important;height:18px!important} .compact .dz{margin:6px 4px 3px;padding-top:3px}
.compact .mid{padding:6px 6px} .compact .mi{padding:6px 2px 5px;gap:3px} .compact .mic svg{width:24px;height:24px} .compact .ml{font-size:10px}
'''
def frame(W,H,label,edit=False,small=False):
    work=H-48
    dicons=''.join(f'<div><i style="background:{c}"></i>{n}</div>' for n,c in [('Recycle Bin','#9AA0A6'),('Jartrek','#C62828'),('Red Dog','#E53935'),('ScreenConnect','#1565C0')])
    cols=2; n=8; scroll=False
    topb=TOP; botb=BOT
    if small: n=4; scroll=True; cols=4
    if edit: cols=3
    eb='<div class="ebar" title="Editing: right-click a button to change it. Lock when done.">Editing: right-click a button to change it. Lock when done.</div>' if edit else ''
    sc=' class="compact"' if small else ''
    html=f'''<div class="desk" style="width:{W}px;height:{H}px"><div class="tag">{label}: BOX MOCKUP (HTML/CSS, headless Chrome), not a Windows capture</div>
<div class="dicons">{dicons}</div>
<div class="win{' compact' if small else ''}" style="height:{work}px">
 <div class="seg top{' editing' if edit else ''}">{eb}{group(topb)}</div>
 {mid(edit,n,cols,scroll)}
 <div class="seg bot{' editing' if edit else ''}">{group(botb)}</div>
</div>
<div class="taskbar"><i class="s"></i><i></i><i></i><i></i><i></i><div class="clock">10:01 AM<br>10/29/2026</div></div>
'''
    if not small and not edit:
        html+=f'<div class="callout" style="right:310px;top:{int(work*0.47)}px">Transparent middle: empty pixels pass clicks to the desktop/app behind. Only the icon chips are hit-testable.</div>'
        html+=f'<div class="callout" style="right:310px;top:{work-60}px">Window bottom = work-area bottom (taskbar never covered)</div>'
    if small:
        html+=f'<div class="callout" style="right:250px;top:{int(work*0.45)}px">1366×768: groups scale down (min 12px text, 44px tiles); middle shows what fits and scrolls the rest. Below ~1 row of space it collapses to a ⋯ button.</div>'
    if edit:
        html+=f'<div class="callout" style="right:310px;top:{int(work*0.42)}px">Edit mode: amber bar, dashed icon outlines, ⠿ drag to reorder, × remove, + Add icon (opens the same Edit window: Program / Website / File / Script)</div>'
    return html+'</div>'
def page(body,W,H): return f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}{EX}</style></head><body style="width:{W}px;height:{H}px">{body}</body></html>'
open('one-panel-normal.html','w').write(page(frame(1920,1080,'Frame 1 · Normal (locked) · 1920×1080'),1920,1080))
open('one-panel-edit.html','w').write(page(frame(1920,1080,'Frame 2 · Edit mode · 1920×1080',edit=True),1920,1080))
open('one-panel-small.html','w').write(page(frame(1366,768,'Frame 3 · Small screen · 1366×768',small=True),1366,768))
