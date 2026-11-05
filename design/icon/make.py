"""Draws the app icon (paw with Immich-coloured petal toes) in its Default, Dark and Tinted looks,
then renders each to the 1024 px PNG that Assets.xcassets uses. Run: python3 design/icon/make.py"""
import pathlib, subprocess

HERE = pathlib.Path(__file__).parent
OUT = HERE.parent.parent / "WoofPhoto/Assets.xcassets/AppIcon.appiconset"
PETAL = "M0 14 C-13 10 -15 -8 -6 -16 C-1 -20 7 -19 10 -12 C14 -3 10 10 0 14Z"
HEEL = "M0 -17 C16 -17 29 -1 29 10 C29 21 18 23 9 20 C5 19 -5 19 -9 20 C-18 23 -29 21 -29 10 C-29 -1 -16 -17 0 -17Z"
# toe centres and tilt, 22 units apart (petals overlap a little)
TOES = [(-33.66, 12.6, -30), (-11.22, -0.4, -10), (11.22, -0.4, 10), (33.66, 12.6, 30)]
IMMICH = [("#FF5A4E", "#E8201A"), ("#FFCB3D", "#F5A300"), ("#3FD66A", "#12A63E"), ("#4DA3FF", "#1A6FE0")]
LOOKS = {
    "light": dict(bg=("#FFFFFF", "#E9E9EE"), toes=IMMICH, heel=("#4A4A4F", "#1F1F22"), blend="multiply", shadow=0.22),
    "dark": dict(bg=("#2A2A2E", "#050505"), toes=IMMICH, heel=("#F4F4F6", "#C9C9CF"), blend="screen", shadow=0.45),
    # iOS colours the tinted look itself from its brightness, so it is grey on black
    "tinted": dict(bg=("#1C1C1E", "#000000"), toes=[("#E0E0E0", "#C0C0C0"), ("#E2E2E2", "#C8C8C8"), ("#E4E4E4", "#D0D0D0"), ("#E6E6E6", "#D8D8D8")],
                   heel=("#ECECEC", "#D8D8D8"), blend="normal", shadow=0.45),
}

def grad(id, top, bottom):
    return f'<linearGradient id="{id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>'

def svg(look):
    defs = [grad("bg", *look["bg"]), grad("heel", *look["heel"])] + [grad(f"t{i}", *c) for i, c in enumerate(look["toes"])]
    # Apple-style shine: white fading out by the middle of each shape, and a soft shadow under the paw
    defs.append('<linearGradient id="shine" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>')
    defs.append(f'<filter id="shadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="2.2" stdDeviation="2.4" flood-color="#000" flood-opacity="{look["shadow"]}"/></filter>')
    toes = "".join(
        f'<g transform="translate({x} {y}) rotate({r}) scale(1.2)"><path d="{PETAL}" fill="url(#t{i})" fill-opacity=".92" style="mix-blend-mode:{look["blend"]}"/><path d="{PETAL}" fill="url(#shine)"/></g>'
        for i, (x, y, r) in enumerate(TOES))
    heel = f'<g transform="translate(0 50)"><path d="{HEEL}" fill="url(#heel)"/><path d="{HEEL}" fill="url(#shine)" opacity=".7"/></g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024"><defs>{"".join(defs)}</defs>'
            f'<rect width="100" height="100" fill="url(#bg)"/>'
            f'<g filter="url(#shadow)" transform="translate(50 51) scale(0.5473) translate(0 -23.39)"><g style="isolation:isolate">{toes}</g>{heel}</g></svg>\n')

for name, look in LOOKS.items():
    source = HERE / f"{name}.svg"
    source.write_text(svg(look))
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", "-b", look["bg"][1], "-o", str(OUT / f"{name}.png"), str(source)], check=True)
