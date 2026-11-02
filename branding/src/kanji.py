# Outlines 求道 from Noto Serif JP / Noto Sans JP (OFL) into SVG path data.
import sys, glob
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

def outline(family, weight, text):
    files = glob.glob(f"{sys.argv[1]}/@fontsource/{family}/files/{family}-*-{weight}-normal.woff2")
    found = {}
    for fn in files:
        if not fn.split("/")[-1].split("-")[-3].isdigit():
            continue
        font = TTFont(fn)
        cmap = font.getBestCmap()
        for ch in text:
            if ord(ch) in cmap and ch not in found:
                found[ch] = (font, cmap[ord(ch)])
    paths = []; x = 0
    for ch in text:
        font, gname = found[ch]
        gs = font.getGlyphSet(); upm = font["head"].unitsPerEm
        pen = SVGPathPen(gs)
        # flip y, 1 em = 100 units, baseline at 88
        tp = TransformPen(pen, (100/upm, 0, 0, -100/upm, x, 88))
        gs[gname].draw(tp)
        paths.append(pen.getCommands())
        x += gs[gname].width * 100 / upm
    return " ".join(paths), x

for fam, w in [("noto-serif-jp", 500), ("noto-sans-jp", 400)]:
    d, width = outline(fam, w, "求道")
    print(fam, width)
    open(f"{sys.argv[2]}/kanji-{fam}.txt", "w").write(d)
