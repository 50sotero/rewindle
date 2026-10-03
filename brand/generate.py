"""Regenerate Rewindle's editable SVG artwork. Requires fonttools and brotli."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '.cache' / 'brand-tools'))
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen

ROOT = Path(__file__).resolve().parent
font = TTFont(ROOT / 'fonts' / 'Inter-Semibold.ttf')
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()
units = font['head'].unitsPerEm
INK, PAPER, TEAL, MINT = '#101927', '#F6F4EE', '#167C73', '#76D6C8'

def text(value, x, y, size, color, tracking=-0.035):
    shapes, advance = [], 0
    for character in value:
        glyph = cmap.get(ord(character), '.notdef')
        pen = SVGPathPen(glyphs)
        glyphs[glyph].draw(pen)
        shapes.append(f'<path transform="translate({advance},0)" d="{pen.getCommands()}"/>')
        advance += glyphs[glyph].width + units * tracking
    return f'<g fill="{color}" transform="translate({x},{y}) scale({size / units},{-size / units})">{"".join(shapes)}</g>'

def mark(color=TEAL, check=None):
    return f'<g fill="none" stroke-linecap="round" stroke-linejoin="round"><path stroke="{color}" stroke-width="5.5" d="M15 22A21 21 0 1 1 12 39M15 11V22H26"/><path stroke="{check or color}" stroke-width="4.5" d="M25 33L31 39L43 27"/></g>'

def svg(name, width, height, body, title):
    (ROOT / name).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title"><title id="title">{title}</title>{body}</svg>\n', encoding='utf-8', newline='\n')

svg('mark.svg',64,64,mark(),'Rewindle verification mark')
svg('mark-mono.svg',64,64,mark(INK),'Rewindle monochrome mark')
svg('mark-reversed.svg',64,64,mark(PAPER),'Rewindle reversed mark')
icon=f'<rect x="2" y="2" width="60" height="60" rx="15" fill="{INK}"/><rect x="2.5" y="2.5" width="59" height="59" rx="14.5" fill="none" stroke="#2B4150"/>{mark(MINT,PAPER)}'
svg('app-icon.svg',64,64,icon,'Rewindle app icon')
for theme, color in [('dark',INK),('light',PAPER)]:
    svg(f'wordmark-{theme}.svg',590,148,text('rewindle',4,111,112,color),'Rewindle')
    svg(f'lockup-{theme}.svg',734,160,f'<g transform="translate(8,16) scale(2)">{mark(TEAL if theme=="dark" else MINT)}</g>'+text('rewindle',151,114,110,color),'Rewindle')
body=f'<rect width="1200" height="630" fill="{INK}"/>'
body+=f'<path d="M1200 74H920C839 74 796 130 796 205V415C796 493 850 551 928 551H1200" fill="none" stroke="#223341" stroke-width="1.5"/>'
body+=f'<g transform="translate(68,48)">{mark(MINT,PAPER)}</g>'+text('rewindle',143,94,39,PAPER)
body+=text('Backup you',72,272,76,PAPER)+text('can verify.',72,362,76,MINT)
body+=text('Encrypted snapshots. Visible checks.',76,446,21,'#B7C2CA',-0.02)+text('Guided recovery. Powered by Restic.',76,480,21,'#B7C2CA',-0.02)
body+=f'<g transform="translate(865,218) scale(3.75)">{mark(MINT,PAPER)}</g>'
body+=text('WINDOWS + macOS',76,568,14,'#93A5B4',0.07)
svg('social-card.svg',1200,630,body,'Rewindle — Backup you can verify')
print('Generated 9 vector brand assets')
