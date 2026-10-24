"""Renders the Brainbox bot app icon (same geometry as BotRenderer in Mascot.swift)."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4                      # supersample
N = 1024 * S

def rrect(d, box, r, fill):
    d.rounded_rectangle([round(v) for v in box], radius=round(r), fill=fill)

def render(variant, out):
    if variant == "tinted":
        img = Image.new("RGBA", (N, N), (0, 0, 0, 255))
    else:
        img = Image.new("RGBA", (N, N), (0, 0, 0, 255))
        # Soft grey spotlight behind the bot (monochrome depth, not a gradient wash).
        glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        g = ImageDraw.Draw(glow)
        c = (52, 52, 56, 255) if variant == "light" else (30, 30, 34, 255)
        g.ellipse([N * 0.12, N * 0.10, N * 0.88, N * 0.86], fill=c)
        glow = glow.filter(ImageFilter.GaussianBlur(N * 0.12))
        img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)

    head_c = (240, 240, 242, 255) if variant != "tinted" else (255, 255, 255, 255)
    visor_c = (6, 6, 8, 255)
    eye_c = (250, 250, 252, 255)
    node_c = (255, 255, 255, 255)

    unit = N * 0.80
    cx, cy = N / 2, N / 2 + N * 0.035
    head_w, head_h = unit * 0.78, unit * 0.64
    top = cy - head_h / 2 + unit * 0.06
    head = (cx - head_w / 2, top, cx + head_w / 2, top + head_h)
    corner = head_h * 0.38

    # Antenna + status node.
    stem_w = unit * 0.035
    stem_top = head[1] - unit * 0.13
    rrect(d, (cx - stem_w / 2, stem_top, cx + stem_w / 2, head[1] + stem_w), stem_w / 2, head_c)
    nr = unit * 0.062
    d.ellipse([cx - nr, stem_top - nr, cx + nr, stem_top + nr], fill=node_c)

    # Ears.
    ear_w, ear_h = unit * 0.06, head_h * 0.34
    mid_y = (head[1] + head[3]) / 2
    for side in (-1, 1):
        ex = cx + side * (head_w / 2 + ear_w * 0.35)
        rrect(d, (ex - ear_w / 2, mid_y - ear_h / 2, ex + ear_w / 2, mid_y + ear_h / 2), ear_w / 2,
              tuple(int(v * 0.85) if i < 3 else 255 for i, v in enumerate(head_c)))

    rrect(d, head, corner, head_c)

    # Visor.
    vx, vy = head_w * 0.1, head_h * 0.17
    visor = (head[0] + vx, head[1] + vy, head[2] - vx, head[3] - vy)
    vh = visor[3] - visor[1]
    vw = visor[2] - visor[0]
    rrect(d, visor, vh * 0.42, visor_c)

    # Eyes (idle, looking slightly up-right: friendly and curious).
    gap = vw * 0.22
    ew, eh = vw * 0.13, vh * 0.52
    ecx = (visor[0] + visor[2]) / 2 + vw * 0.03
    ecy = (visor[1] + visor[3]) / 2 - vh * 0.03
    for side in (-1, 1):
        x = ecx + side * gap
        rrect(d, (x - ew / 2, ecy - eh / 2, x + ew / 2, ecy + eh / 2), ew / 2, eye_c)

    img = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    img.save(out, optimize=True)

if __name__ == "__main__":
    folder = sys.argv[1]
    render("light", f"{folder}/AppIcon-1024.png")
    render("dark", f"{folder}/AppIcon-Dark-1024.png")
    render("tinted", f"{folder}/AppIcon-Tinted-1024.png")
