from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
F='node_modules/@fontsource/inter/files/'
bold=TTFont(F+'inter-latin-600-normal.woff'); reg=TTFont(F+'inter-latin-400-normal.woff')

def outline(font, text, size, x, y, tracking=0.0):
    """Text as one SVG path (font units scaled to `size`), baseline at y, starting at x."""
    upm=font['head'].unitsPerEm; gs=font.getGlyphSet(); cmap=font.getBestCmap(); hmtx=font['hmtx']
    k=size/upm; pen=SVGPathPen(gs); cur=x
    for ch in text:
        name=cmap[ord(ch)]
        tp=TransformPen(pen,(k,0,0,-k,cur,y))   # flip Y: font units go up, SVG goes down
        gs[name].draw(tp)
        cur+=hmtx[name][0]*k + tracking*size
    return pen.getCommands(), cur-x-tracking*size

def lockup(theme):
    C={'dark':dict(body='#e4e4e7',ant='#a1a1aa',title='#eef2f6',tag='#6e7e8b'),
       'light':dict(body='#27272a',ant='#71717a',title='#15181d',tag='#6b7280')}[theme]
    s=2.6                                   # mark scale; the mark's own box is 32x44
    mw,mh=32*s,44*s
    pad=10
    tx=pad+mw+30
    title_size,tag_size=62,33
    title_y=pad+mh*0.47
    tag_y=title_y+tag_size*1.55
    t_path,t_w=outline(bold,'Pepe',title_size,tx,title_y,tracking=-0.012)
    g_path,g_w=outline(reg,'agent runtime',tag_size,tx,tag_y,tracking=0.0)
    W=tx+max(t_w,g_w)+pad; H=pad*2+mh
    mark=f'''<g transform="translate({pad - 16*s:.2f} {pad - 8*s:.2f}) scale({s})">
    <g stroke="{C['ant']}" stroke-width="3" stroke-linecap="round" fill="none"><path d="M26 22 L21 13"/><path d="M38 22 L43 13"/></g>
    <circle cx="20.5" cy="12" r="3.2" fill="#e2231a"/><circle cx="43.5" cy="12" r="3.2" fill="#f5b301"/>
    <rect x="18" y="22" width="28" height="27" rx="9" fill="none" stroke="{C['body']}" stroke-width="3.4"/>
  </g>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.1f} {H:.1f}" role="img" aria-label="Pepe, agent runtime">
  <title>Pepe, agent runtime</title>
  {mark}
  <path d="{t_path}" fill="{C['title']}"/>
  <path d="{g_path}" fill="{C['tag']}"/>
</svg>
''', (W,H)

for theme in ['dark','light']:
    svg,(W,H)=lockup(theme)
    open(f'pepe-logo-{theme}.svg','w').write(svg)
    print(theme,round(W),round(H))
