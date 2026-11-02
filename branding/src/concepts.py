import math, os, sys
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

ACCENT_D = "#7AA6DA"; ACCENT_L = "#2F6DB5"
def f(x): return ("%.3f" % x).rstrip("0").rstrip(".")

# Each concept: function(fg, accent) -> svg body in a 16x16 grid.
def ring(fg, ac):
    n, R, r = 8, 5.6, 1.15
    out = []
    for i in range(n):
        a = -math.pi/2 + i*2*math.pi/n
        x, y = 8+R*math.cos(a), 8+R*math.sin(a)
        if i == 0:
            out.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="1.75" fill="{ac}"/>')
        else:
            out.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="{r}" fill="{fg}"/>')
    return "".join(out)

def split(fg, ac):
    # one pane, then a pane split in two: a large orb and two small ones
    g = 1.0; big = 4.0; sm = (2*big - g)/4
    W = 2*big + g + 2*sm
    x0 = 8 - W/2
    bx, by = x0+big, 8
    sx = x0 + 2*big + g + sm
    return (f'<circle cx="{f(bx)}" cy="{f(by)}" r="{f(big)}" fill="{fg}"/>'
            f'<circle cx="{f(sx)}" cy="{f(8-big+sm)}" r="{f(sm)}" fill="{ac}"/>'
            f'<circle cx="{f(sx)}" cy="{f(8+big-sm)}" r="{f(sm)}" fill="{fg}"/>')

def kernel(fg, ac):
    R, sw = 6.0, 1.3
    a = -math.pi/4
    sx, sy = 8+R*math.cos(a), 8+R*math.sin(a)
    gap = 2.9
    da = 2*math.asin(gap/(2*R))
    a1, a2 = a+da, a-da+2*math.pi
    p1 = (8+R*math.cos(a1), 8+R*math.sin(a1)); p2 = (8+R*math.cos(a2), 8+R*math.sin(a2))
    return (f'<circle cx="8" cy="8" r="2.6" fill="{fg}"/>'
            f'<path d="M{f(p1[0])} {f(p1[1])}A{f(R)} {f(R)} 0 1 1 {f(p2[0])} {f(p2[1])}" fill="none" stroke="{fg}" stroke-width="{sw}" stroke-linecap="round"/>'
            f'<circle cx="{f(sx)}" cy="{f(sy)}" r="1.7" fill="{ac}"/>')

def enso(fg, ac):
    # an open circle, thick at the lower left and thinning toward the gap; one orb in the gap
    C = (8, 8); Ro = 6.6
    ci = (8.75, 7.4); Ri = 5.0
    a_end, a_start = math.radians(-78), math.radians(-12)
    def outer(t): return (C[0]+Ro*math.cos(t), C[1]+Ro*math.sin(t))
    def inner(t):
        dx, dy = math.cos(t), math.sin(t)
        ox, oy = C[0]-ci[0], C[1]-ci[1]
        b = ox*dx+oy*dy; c = ox*ox+oy*oy-Ri*Ri
        s = -b+math.sqrt(b*b-c)
        return (C[0]+s*dx, C[1]+s*dy)
    t0, t1 = a_start, a_end + 2*math.pi
    o0, o1, i0, i1 = outer(t0), outer(t1), inner(t0), inner(t1)
    w0 = math.dist(o0, i0)/2; w1 = math.dist(o1, i1)/2
    d = (f'M{f(o0[0])} {f(o0[1])}A{f(Ro)} {f(Ro)} 0 1 1 {f(o1[0])} {f(o1[1])}'
         f'A{f(w1)} {f(w1)} 0 0 1 {f(i1[0])} {f(i1[1])}'
         f'A{f(Ri)} {f(Ri)} 0 1 0 {f(i0[0])} {f(i0[1])}'
         f'A{f(w0)} {f(w0)} 0 0 1 {f(o0[0])} {f(o0[1])}Z')
    am = math.radians(-45)
    ox, oy = 8+5.95*math.cos(am), 8+5.95*math.sin(am)
    return f'<path d="{d}" fill="{fg}"/><circle cx="{f(ox)}" cy="{f(oy)}" r="1.55" fill="{ac}"/>'

CONCEPTS = {"orbit": ring, "split": split, "kernel": kernel, "enso": enso}

def glyph_svg(fn, fg="currentColor", ac="currentColor"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16">{fn(fg, ac)}</svg>\n'

def icon_svg(fn, theme):
    # 1024 full-bleed square (the system applies the mask); mark at 62 % of the canvas
    if theme == "dark":
        g0, g1, ac = "#333840", "#16181D", ACCENT_D
        orb = '<radialGradient id="orb" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#C7CCD4"/></radialGradient>'
    else:
        g0, g1, ac = "#FBFBFC", "#E4E7EB", ACCENT_L
        orb = '<radialGradient id="orb" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stop-color="#3A3F48"/><stop offset="1" stop-color="#0E0F12"/></radialGradient>'
    s = 1024*0.62/16; off = (1024 - 16*s)/2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{g0}"/><stop offset="1" stop-color="{g1}"/></linearGradient>{orb}</defs>'
            f'<rect width="1024" height="1024" fill="url(#bg)"/>'
            f'<g transform="translate({f(off)} {f(off)}) scale({f(s)})">{fn("url(#orb)", ac)}</g></svg>\n')

for name, fn in CONCEPTS.items():
    d = os.path.join(OUT, name); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "glyph.svg"), "w").write(glyph_svg(fn))
    open(os.path.join(d, "mark-dark.svg"), "w").write(glyph_svg(fn, "#F2F3F5", ACCENT_D))
    open(os.path.join(d, "mark-light.svg"), "w").write(glyph_svg(fn, "#15171B", ACCENT_L))
    open(os.path.join(d, "icon-dark.svg"), "w").write(icon_svg(fn, "dark"))
    open(os.path.join(d, "icon-light.svg"), "w").write(icon_svg(fn, "light"))
print("ok")
