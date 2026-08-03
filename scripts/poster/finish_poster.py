# -*- coding: utf-8 -*-
"""把 codex imagegen 產出的主視覺（main_art.png）疊上 PZ 風標題板，
輸出 Workshop preview 與遊戲內 poster（皆 512x512）。Deterministic：無隨機數。

用法（repo 根目錄）： python scripts/poster/finish_poster.py
"""
import os
from PIL import Image, ImageDraw, ImageFont

SP = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SP))
MOD = os.path.join(REPO, "MOD", "MinidoracatFixesFor42")

# 出貨位置：Workshop 封面 + 遊戲內 MOD 清單縮圖（mod.info 的 poster=）
DESTS = [
    os.path.join(MOD, "preview.png"),
    os.path.join(MOD, "Contents", "mods", "MinidoracatFixesFor42", "42", "poster.png"),
]

BRAND = "Minidoracat"
TITLE = "FIXES"
SUB = "for Build 42"

FONTS = r"C:/Windows/Fonts"
GOLD = (233, 195, 90, 255)
PALE = (240, 234, 214, 255)
INK = (28, 26, 20, 255)
BOARD = (38, 40, 30, 235)      # 暗橄欖告示板
BOARD_EDGE = (18, 18, 12, 255)
TAPE = (214, 200, 160, 210)    # 泛黃膠帶
HAZ_Y = (208, 168, 40, 255)    # 警戒黃
HAZ_K = (24, 22, 18, 255)      # 警戒黑


def font(size, *names):
    for n in names:
        p = os.path.join(FONTS, n)
        if os.path.isfile(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def hazard_strip(draw, x0, y0, x1, y1, step=26):
    draw.rectangle([x0, y0, x1, y1], fill=HAZ_Y)
    for s in range(x0 - (y1 - y0), x1, step * 2):
        draw.polygon([(s, y1), (s + step, y1), (s + step + (y1 - y0), y0), (s + (y1 - y0), y0)], fill=HAZ_K)
    draw.rectangle([x0, y0, x1, y1], outline=BOARD_EDGE, width=3)


def tape(draw, cx, cy, w=64, h=26):
    draw.rectangle([cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2], fill=TAPE)


def stroked(draw, xy, text, f, fill, stroke, w):
    draw.text(xy, text, font=f, fill=fill, stroke_width=w, stroke_fill=stroke)


def build():
    art = os.path.join(SP, "main_art.png")
    if not os.path.isfile(art):
        raise SystemExit("缺少 " + art + "（先用 codex imagegen 產生 1024x1024 主視覺）")
    im = Image.open(art).convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    d = ImageDraw.Draw(im)

    f_brand = font(54, "segoeuib.ttf", "arialbd.ttf")
    f_title = font(106, "impact.ttf", "arialbd.ttf")

    # 告示板寬度貼合文字（標題短時不留大片空白），高度固定以維持系列一致性
    pad = 30
    inner = max(d.textlength(BRAND, font=f_brand), d.textlength(TITLE, font=f_title))
    bx0, by0 = 28, 26
    bx1, by1 = bx0 + int(inner) + pad * 2, 232

    d.rectangle([bx0 + 6, by0 + 8, bx1 + 6, by1 + 8], fill=(0, 0, 0, 120))   # 投影
    d.rectangle([bx0, by0, bx1, by1], fill=BOARD, outline=BOARD_EDGE, width=4)
    hazard_strip(d, bx0, by0, bx1, by0 + 14)
    tape(d, bx0 + 26, by0 + 10)
    tape(d, bx1 - 26, by0 + 10)
    stroked(d, (bx0 + pad, by0 + 30), BRAND, f_brand, PALE, INK, 3)
    stroked(d, (bx0 + pad - 2, by0 + 88), TITLE, f_title, GOLD, INK, 5)

    # for Build 42 小板
    f_sub = font(38, "segoeuib.ttf", "arialbd.ttf")
    sw = d.textlength(SUB, font=f_sub)
    d.rectangle([bx0, by1 + 10, bx0 + sw + 44, by1 + 66], fill=(52, 46, 34, 225), outline=BOARD_EDGE, width=3)
    stroked(d, (bx0 + 22, by1 + 16), SUB, f_sub, PALE, INK, 2)
    return im


small = build().resize((512, 512), Image.LANCZOS).convert("RGB")
for dest in DESTS:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    small.save(dest, "PNG")
    print("寫出:", dest)
print("done")
