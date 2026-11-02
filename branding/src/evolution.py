# Evolutions of the current app icon (a window split into three panes, a cursor in the first).
import os, sys
OUT = sys.argv[1]
def f(x): return ("%.2f" % x).rstrip("0").rstrip(".")

X0, Y0, X1, Y1, R = 212, 232, 812, 792, 96
XM, YM = 512, 512

def rr(x0, y0, x1, y1, tl, tr, br, bl):
    return (f"M{f(x0+tl)} {f(y0)}H{f(x1-tr)}" + (f"A{f(tr)} {f(tr)} 0 0 1 {f(x1)} {f(y0+tr)}" if tr else "")
            + f"V{f(y1-br)}" + (f"A{f(br)} {f(br)} 0 0 1 {f(x1-br)} {f(y1)}" if br else "")
            + f"H{f(x0+bl)}" + (f"A{f(bl)} {f(bl)} 0 0 1 {f(x0)} {f(y1-bl)}" if bl else "")
            + f"V{f(y0+tl)}" + (f"A{f(tl)} {f(tl)} 0 0 1 {f(x0+tl)} {f(y0)}" if tl else "") + "Z")

def panes(t):
    """The window frame with its dividers, stroke t, as an even-odd path; and the three pane holes."""
    r = R - t
    holes = [rr(X0+t, Y0+t, XM-t/2, Y1-t, r, 0, 0, r),
             rr(XM+t/2, Y0+t, X1-t, YM-t/2, 0, r, 0, 0),
             rr(XM+t/2, YM+t/2, X1-t, Y1-t, 0, 0, r, 0)]
    return rr(X0, Y0, X1, Y1, R, R, R, R) + "".join(holes), holes

def variant(name, ink, ac, t, glyph=False):
    d, holes = panes(t)
    parts = [f'<path fill="{ink}" fill-rule="evenodd" d="{d}"/>']
    if name == "a-original":
        if glyph:
            parts.append(f'<rect x="316" y="560" width="96" height="152" rx="16" fill="{ac}"/>')
        else:
            parts.append(f'<rect x="316" y="560" width="92" height="152" rx="12" fill="{ac}"/>')
    elif name == "b-orb":
        parts.append(f'<circle cx="372" cy="624" r="{78 if glyph else 70}" fill="{ac}"/>')
    elif name == "c-orbit" and glyph:
        # too fine for 16 px: small sizes use B's glyph
        parts.append(f'<circle cx="372" cy="624" r="78" fill="{ac}"/>')
    elif name == "c-orbit":
        # a faint orbit through all three panes; the orb rides it in the first pane
        sw = 30 if glyph else 12
        op = "0.55" if glyph else "0.38"
        clip = "".join(holes)
        parts.insert(0, f'<clipPath id="in{1 if glyph else 0}"><path d="{clip}"/></clipPath>')
        parts.append(f'<g clip-path="url(#in{1 if glyph else 0})"><circle cx="512" cy="512" r="196" fill="none" stroke="{ink}" stroke-opacity="{op}" stroke-width="{sw}"/></g>')
        parts.append(f'<circle cx="327.8" cy="579" r="66" fill="{ac}"/>')
    elif name == "d-pane-orbs":
        parts.append(f'<circle cx="372" cy="512" r="{82 if glyph else 72}" fill="{ac}"/>')
        parts.append(f'<circle cx="652" cy="372" r="{50 if glyph else 40}" fill="{ink}"/>')
        parts.append(f'<circle cx="652" cy="652" r="{50 if glyph else 40}" fill="{ink}"/>')
    return "".join(parts)

NAMES = ["a-original", "b-orb", "c-orbit", "d-pane-orbs"]

def icon(name, theme):
    if theme == "dark":
        g0, g1, ink, ac = "#333840", "#16181D", "#FFFFFF", "#7AA6DA"
    else:
        g0, g1, ink, ac = "#FBFBFC", "#E4E7EB", "#1B1D22", "#2F6DB5"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{g0}"/>'
            f'<stop offset="1" stop-color="{g1}"/></linearGradient></defs>'
            f'<rect width="1024" height="1024" fill="url(#bg)"/>'
            f'<g opacity="{0.92 if theme == "dark" else 1}">{variant(name, ink, ac, 40)}</g></svg>\n')

def glyph(name, ink="currentColor", ac="currentColor"):
    # 16 pt grid: the frame fills 15 x 14, strokes thickened so they hold at 16 px
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="192 212 640 600" width="16" height="15">'
            f'{variant(name, ink, ac, 54, glyph=True)}</svg>\n')

for n in NAMES:
    d = os.path.join(OUT, n); os.makedirs(d, exist_ok=True)
    open(f"{d}/icon-dark.svg", "w").write(icon(n, "dark"))
    open(f"{d}/icon-light.svg", "w").write(icon(n, "light"))
    open(f"{d}/glyph.svg", "w").write(glyph(n))
    open(f"{d}/mark-dark.svg", "w").write(glyph(n, "#F2F3F5", "#7AA6DA"))
    open(f"{d}/mark-light.svg", "w").write(glyph(n, "#15171B", "#2F6DB5"))
print("ok")
