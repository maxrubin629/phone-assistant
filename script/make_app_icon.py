"""Regenerates the layers of native/Resources/AppIcon.icon.

A light purple glass handset with call waves over a backdrop that is dark at
the top and turns purple below, like the notch widget's fade.
Pass a JSON object of parameter overrides and an output .icon path to draw a
variant elsewhere.
"""
import json, math, re, sys
from pathlib import Path

DEFAULTS = {
    'glyph_size': 600, 'center': [512, 512],   # the glyph's bounding box
    'wave_origin': [530, 430], 'wave_radii': [160, 250, 340], 'wave_width': 46,
    'glyph_color': '#C9A8FF',
    'backdrop': ['#050308', '#231244', '#6A3CC0'],   # top to bottom
    'glass': {"shadow": {"kind": "neutral", "opacity": 0.5}, "specular": True,
              "translucency": {"enabled": True, "value": 0.35}},
}
SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n{}\n</svg>\n'

# A classic receiver as a smooth closed curve through points on its outline:
# earpiece at the top left, mouthpiece at the lower right, on a 960-unit grid.
RECEIVER_OUTLINE = [
    (300, 188), (350, 184), (378, 190), (395, 210), (408, 250), (418, 300), (427, 345),
    (418, 365), (395, 378), (372, 388), (360, 402), (364, 428), (380, 470), (405, 515), (440, 560),
    (480, 598), (520, 625), (548, 632), (565, 620), (580, 598), (598, 582), (618, 578), (660, 590),
    (710, 610), (750, 630), (768, 650), (768, 680), (755, 720), (725, 760), (685, 787), (640, 795),
    (590, 790), (540, 773), (480, 735), (410, 670), (340, 590), (280, 505), (235, 415), (212, 335),
    (212, 280), (228, 238), (260, 205)]


def smooth_closed(points):
    """A Catmull-Rom curve through the points, as cubic Bezier segments."""
    n, d = len(points), f'M{points[0][0]} {points[0][1]}'
    for i in range(n):
        p0, p1, p2, p3 = points[i-1], points[i], points[(i+1) % n], points[(i+2) % n]
        d += (f'C{p1[0]+(p2[0]-p0[0])/6:.1f} {p1[1]+(p2[1]-p0[1])/6:.1f} '
              f'{p2[0]-(p3[0]-p1[0])/6:.1f} {p2[1]-(p3[1]-p1[1])/6:.1f} {p2[0]} {p2[1]}')
    return d + 'Z'


RECEIVER = smooth_closed(RECEIVER_OUTLINE)


def path_points(d):
    """Points along an SVG path (M, L, C, A and Z, absolute or relative), for measuring it."""
    tokens = re.findall(r'[MLCAZmlcaz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?', d)
    points, x, y, start, i, command = [], 0.0, 0.0, (0.0, 0.0), 0, None
    def number():
        nonlocal i
        i += 1
        return float(tokens[i - 1])
    while i < len(tokens):
        if tokens[i] in 'MLCAZmlcaz':
            command = tokens[i]; i += 1
        rel = command.islower()
        ox, oy = (x, y) if rel else (0.0, 0.0)
        c = command.upper()
        if c == 'Z':
            x, y = start; continue
        if c in 'ML':
            x, y = ox + number(), oy + number()
            if c == 'M': start = (x, y); command = 'l' if rel else 'L'
            points.append((x, y))
        elif c == 'C':
            x1, y1, x2, y2 = ox + number(), oy + number(), ox + number(), oy + number()
            x3, y3 = ox + number(), oy + number()
            for k in range(1, 25):
                t = k / 24
                points.append(((1-t)**3*x + 3*(1-t)**2*t*x1 + 3*(1-t)*t**2*x2 + t**3*x3,
                               (1-t)**3*y + 3*(1-t)**2*t*y1 + 3*(1-t)*t**2*y2 + t**3*y3))
            x, y = x3, y3
        elif c == 'A':
            rx, ry, _, large, sweep = number(), number(), number(), number(), number()
            x2, y2 = ox + number(), oy + number()
            # Endpoint to center parameterization (SVG 1.1, F.6.5), for unrotated arcs.
            dx, dy = (x - x2)/2, (y - y2)/2
            scale = max(1.0, math.sqrt((dx/rx)**2 + (dy/ry)**2)); rx, ry = rx*scale, ry*scale
            factor = math.sqrt(max(0.0, (rx*rx*ry*ry - rx*rx*dy*dy - ry*ry*dx*dx) / (rx*rx*dy*dy + ry*ry*dx*dx)))
            if large == sweep: factor = -factor
            cx, cy = factor*rx*dy/ry + (x + x2)/2, -factor*ry*dx/rx + (y + y2)/2
            a0 = math.atan2((y - cy)/ry, (x - cx)/rx); a1 = math.atan2((y2 - cy)/ry, (x2 - cx)/rx)
            span = a1 - a0
            if sweep and span < 0: span += 2*math.pi
            if not sweep and span > 0: span -= 2*math.pi
            for k in range(1, 25):
                a = a0 + span*k/24
                points.append((cx + rx*math.cos(a), cy + ry*math.sin(a)))
            x, y = x2, y2
    return points


def glyph(p):
    """The handset and waves in the receiver's units, with their bounding box."""
    handset = [f'<path d="{RECEIVER}"/>']
    points = path_points(RECEIVER)
    # Waves radiate from the receiver's open side, toward the upper right.
    ox, oy = p['wave_origin']
    waves = []
    for r in p['wave_radii']:
        a0, a1 = math.radians(-80), math.radians(-10)
        waves.append(f'<path d="M{ox+r*math.cos(a0):.1f} {oy+r*math.sin(a0):.1f} '
                     f'A{r} {r} 0 0 1 {ox+r*math.cos(a1):.1f} {oy+r*math.sin(a1):.1f}"/>')
        for t in range(-80, -9, 2):
            for d in (-p['wave_width']/2, p['wave_width']/2):
                points.append((ox + (r+d)*math.cos(math.radians(t)), oy + (r+d)*math.sin(math.radians(t))))
    xs, ys = [x for x, _ in points], [y for _, y in points]
    return handset, waves, (min(xs), min(ys), max(xs), max(ys))


def build(icon, p):
    assets = icon/'Assets'
    assets.mkdir(parents=True, exist_ok=True)
    for old in assets.glob('*.svg'): old.unlink()

    handset, waves, (left, top, right, bottom) = glyph(p)
    scale = p['glyph_size'] / max(right - left, bottom - top)
    tx = p['center'][0] - (left + right)/2*scale
    ty = p['center'][1] - (top + bottom)/2*scale
    place = f'transform="translate({tx:.1f} {ty:.1f}) scale({scale:.4f})"'
    color = p['glyph_color']
    (assets/'handset.svg').write_text(SVG.format(
        f'  <g {place} fill="{color}">\n    ' + '\n    '.join(handset) + '\n  </g>'))
    (assets/'waves.svg').write_text(SVG.format(
        f'  <g {place} fill="none" stroke="{color}" stroke-width="{p["wave_width"]}" stroke-linecap="round">\n    '
        + '\n    '.join(waves) + '\n  </g>'))

    colors = p['backdrop']
    stops = '\n'.join(f'      <stop offset="{i/(len(colors)-1):.2f}" stop-color="{c}"/>' for i, c in enumerate(colors))
    (assets/'backdrop.svg').write_text(SVG.format(f'''  <defs>
    <linearGradient id="backdrop" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">
{stops}
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#backdrop)"/>'''))

    icon_json = {
        "fill": {"solid": "display-p3:0.03000,0.02000,0.05000,1.00000"},
        "groups": [
            {"layers": [{"image-name": "waves.svg", "name": "waves", "glass": True},
                        {"image-name": "handset.svg", "name": "handset", "glass": True}],
             "name": "call", **p['glass']},
            {"layers": [{"image-name": "backdrop.svg", "name": "backdrop", "glass": False}],
             "name": "backdrop", "shadow": {"kind": "none", "opacity": 0.5}, "specular": False,
             "translucency": {"enabled": False, "value": 0.5}},
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (icon/'icon.json').write_text(json.dumps(icon_json, indent=2) + '\n')


if __name__ == '__main__':
    params = dict(DEFAULTS, **(json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}))
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent/'native/Resources/AppIcon.icon'
    build(target, params)
