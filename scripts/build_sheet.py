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

from PIL import Image, ImageDraw, ImageEnhance, ImageFont

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


# Pokémon status-condition skins for the priority states from
# PetAnimationState.swift: blocked/waiting -> Freeze, done -> Infatuation,
# nothing -> Sleep. These layer a drawn overlay on top of the tinted sprite
# instead of relying on tint/desaturate alone, since a color shift by itself
# reads as a mood filter rather than a distinct status (see connor-pet
# artifact "얼음 연출 비교" — bubble read as soap-bubble, angular ice crystal
# read as "frozen" and matches the actual in-game status-effect art style).
def _load_font(size):
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def draw_ice_crystal(frame, shimmer=1.0):
    """Encase the sprite in an angular ice crystal (not a round bubble) —
    a faceted polygon plus three shards poking past its edges."""
    size = frame.size[0]
    inset = 25
    x0, y0, x1, y1 = inset, inset, size - inset, size - inset
    w, h = x1 - x0, y1 - y0

    def pt(fx, fy):
        return (x0 + fx * w, y0 + fy * h)

    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    outline_pts = [pt(*p) for p in [
        (0.50, 0.02), (0.78, 0.14), (1.00, 0.40), (0.92, 0.74),
        (0.68, 0.98), (0.32, 0.94), (0.04, 0.68), (0.10, 0.30),
    ]]
    fill_a = int(130 * shimmer)
    draw.polygon(outline_pts, fill=(150, 205, 245, fill_a))
    draw.polygon(outline_pts, outline=(230, 248, 255, 235), width=3)

    highlight_pts = [pt(*p) for p in [(0.50, 0.02), (0.78, 0.14), (0.50, 0.46), (0.10, 0.30)]]
    draw.polygon(highlight_pts, fill=(255, 255, 255, int(120 * shimmer)))

    shadow_pts = [pt(*p) for p in [(0.68, 0.98), (0.92, 0.74), (0.50, 0.46), (0.32, 0.94)]]
    draw.polygon(shadow_pts, fill=(30, 80, 150, int(100 * shimmer)))

    shards = [
        [(x0 + 0.10 * w, y0 - 4), (x0 + 0.30 * w, y0 - 4), (x0 + 0.20 * w, y0 - 22)],
        [(x1 + 4, y0 + 0.28 * h), (x1 + 4, y0 + 0.46 * h), (x1 + 20, y0 + 0.36 * h)],
        [(x0 + 0.28 * w, y1 + 4), (x0 + 0.46 * w, y1 + 4), (x0 + 0.36 * w, y1 + 20)],
    ]
    for shard in shards:
        draw.polygon(shard, fill=(220, 240, 255, int(160 * shimmer)))
        draw.polygon(shard, outline=(235, 250, 255, 220), width=2)

    return Image.alpha_composite(frame, overlay)


def draw_heart(draw, cx, cy, size, alpha):
    r = size / 2
    draw.ellipse([cx - r, cy - r * 1.3, cx, cy - 0.1 * r], fill=(255, 130, 185, alpha))
    draw.ellipse([cx, cy - r * 1.3, cx + r, cy - 0.1 * r], fill=(255, 130, 185, alpha))
    draw.polygon([(cx - r, cy - 0.4 * r), (cx + r, cy - 0.4 * r), (cx, cy + r * 1.1)], fill=(255, 130, 185, alpha))


def draw_hearts(frame, frame_index):
    """Floating hearts for the Infatuation skin, timed to rise + fade across
    the row's 4-frame loop like the CSS heartFloat keyframes."""
    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    alphas = [0, 190, 230, 90]
    dy = [10, 0, -12, -24]
    draw_heart(draw, frame.size[0] * 0.68, frame.size[1] * 0.30 + dy[frame_index], 20, alphas[frame_index])
    alt = (frame_index + 2) % 4
    draw_heart(draw, frame.size[0] * 0.32, frame.size[1] * 0.22 + dy[alt], 14, alphas[alt])
    return Image.alpha_composite(frame, overlay)


def draw_zzz(frame, frame_index):
    """Drifting "Zzz" for the Sleep skin, timed like the CSS zzzFloat keyframes."""
    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    alphas = [0, 210, 130, 0]
    dx = [0, 4, 12, 20]
    dy = [8, -2, -14, -26]
    font = _load_font(22)
    x = frame.size[0] * 0.62 + dx[frame_index]
    y = frame.size[1] * 0.10 + dy[frame_index]
    draw.text((x, y), "Zzz", font=font, fill=(210, 230, 255, alphas[frame_index]))
    return Image.alpha_composite(frame, overlay)


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

    # idle == "nothing is happening" in agentStateAnimation, reskinned as the
    # Sleep status: darker/desaturated + a drifting "Zzz" instead of a plain
    # resting pose.
    idle_src = pick(front_base, [0.0, 0.3, 0.55, 0.85])
    idle_frames = []
    for i, s in enumerate(idle_src):
        sleepy = desaturate(s, 0.4, 0.62)
        frame = paste_centered(sleepy, dy=[0, -3, -5, -2][i])
        idle_frames.append(draw_zzz(frame, i))
    rows["idle"] = {
        "frames": idle_frames,
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

    # blocked/waiting wins the priority check immediately, so it's reskinned
    # as Freeze: held on one pose (frozen == not moving) and encased in an
    # angular ice crystal, with a faint shimmer across the loop instead of
    # actual motion.
    freeze_pose = paste_centered(front_base[0])
    freeze_frames = []
    shimmer_by_frame = [0.85, 1.0, 1.0, 0.85]
    for i, shimmer in enumerate(shimmer_by_frame):
        icy = tint(desaturate(freeze_pose, 0.35, 1.1), (170, 215, 250), 0.6)
        freeze_frames.append(draw_ice_crystal(icy, shimmer=shimmer))
    rows["waiting"] = {
        "frames": freeze_frames,
        "durations": [800, 700, 700, 800]
    }

    work_src = pick(front_base, [0.1, 0.4, 0.6, 0.9])
    rows["running"] = {
        "frames": [paste_centered(s, dy=[0, -10, 0, -6][i], scale=[1.0, 1.02, 1.0, 1.01][i])
                   for i, s in enumerate(work_src)],
        "durations": [120, 120, 120, 120]
    }

    # done is the completion state, reskinned as Infatuation: a warm pink
    # tint (replacing the old gold) plus floating hearts instead of just a
    # color shift.
    rev_src = pick(front_base, [0.0, 0.3, 0.6, 0.9])
    review_frames = []
    for i, s in enumerate(rev_src):
        tinted = tint(s, (255, 140, 190), [0.15, 0.35, 0.5, 0.35][i])
        frame = paste_centered(tinted, dy=[0, -4, -6, -4][i])
        review_frames.append(draw_hearts(frame, i))
    rows["review"] = {
        "frames": review_frames,
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
        "description": "Custom connor-pet build: Totodile / 리아코 reacts to live Orca agent/project status, "
                        "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
                        "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites.",
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
