#!/usr/bin/env python3
"""
Builds totodile.codex-pet/spritesheet.png + pet.json from PokeAPI's public
gen5 battle sprites for Totodile / 리아코 (#158). Reproducible: re-running
this script re-downloads the source frames and regenerates the bundle from
scratch.

Requires: pillow (`pip install pillow`)

Usage: python3 scripts/build_sheet.py
"""
import json
import os
import urllib.request

from PIL import Image, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(REPO_ROOT, "totodile.codex-pet")
CACHE_DIR = os.path.join(HERE, ".cache")

FRONT_URL = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/158.gif"
BACK_URL = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/back/158.gif"

FRAME = 200
COLS = 4
ROWS_ORDER = [
    "idle", "running-right", "running-left", "waving",
    "jumping", "failed", "waiting", "running", "review"
]


def fetch(url, dest):
    if os.path.exists(dest):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print(f"downloading {url}")
    urllib.request.urlretrieve(url, dest)
    return dest


def load_frames(path):
    im = Image.open(path)
    frames = []
    for i in range(im.n_frames):
        im.seek(i)
        frames.append(im.convert("RGBA").copy())
    return frames


def pick(frames, fracs):
    n = len(frames)
    return [frames[min(n - 1, int(round(f * (n - 1))))] for f in fracs]


def autocrop(img):
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


def scale_to_height(img, target_h):
    w, h = img.size
    scale = target_h / h
    return img.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.NEAREST)


def blank_canvas():
    return Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))


def paste_centered(sprite, dx=0, dy=0, scale=1.0):
    canvas = blank_canvas()
    s = sprite
    if scale != 1.0:
        w, h = s.size
        s = s.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.NEAREST)
    w, h = s.size
    x = (FRAME - w) // 2 + dx
    y = (FRAME - h) // 2 + dy
    canvas.alpha_composite(s, (x, y))
    return canvas


def tint(img, color, strength):
    r, g, b, a = img.split()
    base = Image.merge("RGB", (r, g, b))
    solid = Image.new("RGB", img.size, color)
    blended = Image.blend(base, solid, strength)
    br, bg, bb = blended.split()
    return Image.merge("RGBA", (br, bg, bb, a))


def desaturate(img, sat, bright):
    r, g, b, a = img.split()
    rgb = Image.merge("RGB", (r, g, b))
    rgb = ImageEnhance.Color(rgb).enhance(sat)
    rgb = ImageEnhance.Brightness(rgb).enhance(bright)
    br, bg, bb = rgb.split()
    return Image.merge("RGBA", (br, bg, bb, a))


def flip(img):
    return img.transpose(Image.FLIP_LEFT_RIGHT)


def main():
    front_path = fetch(FRONT_URL, os.path.join(CACHE_DIR, "front.gif"))
    back_path = fetch(BACK_URL, os.path.join(CACHE_DIR, "back.gif"))

    front_raw = load_frames(front_path)
    back_raw = load_frames(back_path)

    front_base = [scale_to_height(autocrop(f), 150)
                  for f in pick(front_raw, [0.0, 0.14, 0.28, 0.42, 0.5, 0.64, 0.78, 0.92])]
    back_base = [scale_to_height(autocrop(f), 150)
                 for f in pick(back_raw, [0.0, 0.25, 0.5, 0.75])]

    rows = {}

    idle_src = pick(front_base, [0.0, 0.3, 0.55, 0.85])
    rows["idle"] = {
        "frames": [paste_centered(s, dy=[0, -3, -5, -2][i]) for i, s in enumerate(idle_src)],
        "durations": [900, 500, 500, 900]
    }

    run_src = pick(front_base, [0.1, 0.4, 0.6, 0.9])
    run_right_frames = []
    for i, s in enumerate(run_src):
        dx = [-14, 4, 14, -4][i]
        dy = [4, -6, 2, -8][i]
        run_right_frames.append(paste_centered(s, dx=dx, dy=dy, scale=1.02))
    rows["running-right"] = {"frames": run_right_frames, "durations": [110, 110, 110, 110]}
    rows["running-left"] = {"frames": [flip(f) for f in run_right_frames], "durations": [110, 110, 110, 110]}

    wave_src = pick(back_base, [0.0, 0.33, 0.66, 0.99])
    rows["waving"] = {
        "frames": [paste_centered(s, dy=[0, -6, -8, -2][i]) for i, s in enumerate(wave_src)],
        "durations": [160, 160, 160, 220]
    }

    base_jump = front_base[0]
    jump_frames = [
        paste_centered(base_jump, dy=14, scale=0.92),
        paste_centered(base_jump, dy=-18, scale=1.03),
        paste_centered(base_jump, dy=-34, scale=1.0),
        paste_centered(base_jump, dy=6, scale=0.95),
    ]
    rows["jumping"] = {"frames": jump_frames, "durations": [140, 140, 160, 160]}

    fail_src = pick(front_base, [0.0, 0.3, 0.6, 0.9])
    fail_frames = []
    for i, s in enumerate(fail_src):
        tinted = tint(s, (220, 40, 40), 0.45 if i % 2 == 0 else 0.2)
        fail_frames.append(paste_centered(tinted, dx=[-6, 6, -4, 0][i], dy=[2, 2, 4, 6][i]))
    rows["failed"] = {"frames": fail_frames, "durations": [140, 140, 140, 240]}

    wait_src = pick(front_base, [0.0, 0.5])
    wait_src = [wait_src[0], wait_src[1], wait_src[1], wait_src[0]]
    rows["waiting"] = {
        "frames": [paste_centered(desaturate(s, 0.35, 0.82), dy=[0, -2, -2, 0][i]) for i, s in enumerate(wait_src)],
        "durations": [800, 700, 700, 800]
    }

    work_src = pick(front_base, [0.1, 0.4, 0.6, 0.9])
    rows["running"] = {
        "frames": [paste_centered(s, dy=[0, -10, 0, -6][i], scale=[1.0, 1.02, 1.0, 1.01][i])
                   for i, s in enumerate(work_src)],
        "durations": [120, 120, 120, 120]
    }

    rev_src = pick(front_base, [0.0, 0.3, 0.6, 0.9])
    rows["review"] = {
        "frames": [paste_centered(tint(s, (255, 214, 102), [0.15, 0.35, 0.5, 0.35][i]), dy=[0, -4, -6, -4][i])
                   for i, s in enumerate(rev_src)],
        "durations": [220, 220, 220, 220]
    }

    sheet_w = FRAME * COLS
    sheet_h = FRAME * len(ROWS_ORDER)
    sheet = Image.new("RGBA", (sheet_w, sheet_h), (0, 0, 0, 0))

    manifest_animations = {}
    for row_idx, name in enumerate(ROWS_ORDER):
        data = rows[name]
        for col_idx, frame in enumerate(data["frames"]):
            sheet.alpha_composite(frame, (col_idx * FRAME, row_idx * FRAME))
        manifest_animations[name] = {
            "row": row_idx,
            "frames": len(data["frames"]),
            "frameDurationsMs": data["durations"]
        }

    os.makedirs(OUT_DIR, exist_ok=True)
    sheet.save(os.path.join(OUT_DIR, "spritesheet.png"), optimize=True)

    manifest = {
        "id": "totodile-riako",
        "displayName": "리아코 (Totodile)",
        "description": "Custom connor-pet build: Totodile / 리아코 reacts to live Orca agent/project status "
                        "(idle/running/waiting/review/jumping/running-left/running-right), built from "
                        "PokeAPI gen5 battle sprites.",
        "spritesheetPath": "spritesheet.png",
        "frame": {"width": FRAME, "height": FRAME},
        "fps": 8,
        "defaultAnimation": "idle",
        "animations": manifest_animations
    }
    with open(os.path.join(OUT_DIR, "pet.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    print(f"wrote {OUT_DIR}/spritesheet.png ({sheet.size[0]}x{sheet.size[1]}) and pet.json")


if __name__ == "__main__":
    main()
