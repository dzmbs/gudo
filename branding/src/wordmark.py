# "gudo": geometric monoline, built from the same circle as the orbs.
import sys, os
out = sys.argv[1]; kanji = open(sys.argv[2]).read()
os.makedirs(out, exist_ok=True)
SW = 7.5; R = 20 - SW/2          # bowl: outer radius 20, x-height 30..70
TOP, BASE, ASC = 30 + SW/2, 70 - SW/2, 12
def f(x): return ("%.2f" % x).rstrip("0").rstrip(".")

def letters():
    p = []
    # g: bowl, stem, hook
    cx = 20; sx = cx + R
    p.append(f'M{f(cx+R)} 50A{f(R)} {f(R)} 0 1 1 {f(cx-R)} 50A{f(R)} {f(R)} 0 1 1 {f(cx+R)} 50Z')
    p.append(f'M{f(sx)} {f(TOP)}V74A{f(R)} {f(R)} 0 0 1 {f(cx-R+2)} 84')
    # u
    x0 = sx + SW + 11; x1 = x0 + 2*R
    p.append(f'M{f(x0)} {f(TOP)}V50A{f(R)} {f(R)} 0 0 0 {f(x1)} 50')
    p.append(f'M{f(x1)} {f(TOP)}V{f(BASE)}')
    # d
    cx = x1 + SW + 10 + R; sx = cx + R
    p.append(f'M{f(cx+R)} 50A{f(R)} {f(R)} 0 1 1 {f(cx-R)} 50A{f(R)} {f(R)} 0 1 1 {f(cx+R)} 50Z')
    p.append(f'M{f(sx)} {f(ASC)}V{f(BASE)}')
    # o
    cx = sx + SW + 9 + R
    p.append(f'M{f(cx+R)} 50A{f(R)} {f(R)} 0 1 1 {f(cx-R)} 50A{f(R)} {f(R)} 0 1 1 {f(cx+R)} 50Z')
    return " ".join(p), cx + R + SW/2

d, W = letters()
H0, H1 = ASC - SW/2, 92
def word(color="currentColor"):
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round"/>'

def svg(body, w, y0, h):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 {f(y0)} {f(w)} {f(h)}" width="{f(w*2)}" height="{f(h*2)}">{body}</svg>\n'

open(f"{out}/gudo.svg", "w").write(svg(word(), W, H0, H1 - H0))
open(f"{out}/gudo-white.svg", "w").write(svg(word("#ECEEF1"), W, H0, H1 - H0))
open(f"{out}/gudo-black.svg", "w").write(svg(word("#15171B"), W, H0, H1 - H0))
# with 求道: set small after the word, on the x-height band, quieter
k = 0.34; kx = W + 18
kan = f'<g transform="translate({f(kx)} {f(70 - 88*k)}) scale({k})" fill="currentColor" opacity="0.55"><path d="{kanji}"/></g>'
open(f"{out}/gudo-kyudo.svg", "w").write(svg(word() + kan, kx + 200*k, H0, H1 - H0))
# lockup with the icon's glyph (window, panes, orb): the frame spans ascender to baseline
GD = "M308 232H716A96 96 0 0 1 812 328V696A96 96 0 0 1 716 792H308A96 96 0 0 1 212 696V328A96 96 0 0 1 308 232ZM308 286H485V738H308A42 42 0 0 1 266 696V328A42 42 0 0 1 308 286ZM539 286H716A42 42 0 0 1 758 328V485H539V286ZM539 539H758V696A42 42 0 0 1 716 738H539V539Z"
s = (70 - ASC + SW) / 560
def glyph(ac): return (f'<g transform="translate(0 {f(ASC - SW/2)}) scale({f(s)}) translate(-212 -232)">'
    f'<path fill="currentColor" fill-rule="evenodd" d="{GD}"/><circle cx="372" cy="624" r="78" fill="{ac}"/></g>')
gx = 600 * s + 28
open(f"{out}/lockup.svg", "w").write(svg(glyph("currentColor") + f'<g transform="translate({f(gx)} 0)">{word()}</g>', gx + W, H0, H1 - H0))
open(f"{out}/lockup-dark.svg", "w").write(svg(glyph("#7AA6DA").replace("currentColor", "#ECEEF1") + f'<g transform="translate({f(gx)} 0)">{word("#ECEEF1")}</g>', gx + W, H0, H1 - H0))
open(f"{out}/lockup-light.svg", "w").write(svg(glyph("#2F6DB5").replace("currentColor", "#15171B") + f'<g transform="translate({f(gx)} 0)">{word("#15171B")}</g>', gx + W, H0, H1 - H0))
print(W)
