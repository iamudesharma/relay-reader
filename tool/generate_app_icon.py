#!/usr/bin/env python3
"""Distribute the Relay Reader master icon to the iOS and Android asset sets.

Run after tool/generate_app_icon.swift. The master is a full-bleed 1024 px
image. iOS needs opaque RGB icons; Android gets a rounded legacy launcher icon
with transparent surrounding space.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets" / "branding" / "app_icon_master.png"
IOS = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
MACOS = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ANDROID = ROOT / "android" / "app" / "src" / "main" / "res"

IOS_ICONS = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

ANDROID_ICONS = {
    "mipmap-mdpi/ic_launcher.png": 48,
    "mipmap-hdpi/ic_launcher.png": 72,
    "mipmap-xhdpi/ic_launcher.png": 96,
    "mipmap-xxhdpi/ic_launcher.png": 144,
    "mipmap-xxxhdpi/ic_launcher.png": 192,
}

MACOS_ICONS = {
    "app_icon_16.png": 16,
    "app_icon_32.png": 32,
    "app_icon_64.png": 64,
    "app_icon_128.png": 128,
    "app_icon_256.png": 256,
    "app_icon_512.png": 512,
    "app_icon_1024.png": 1024,
}


def resize(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.Resampling.LANCZOS)


def android_icon(master: Image.Image, size: int) -> Image.Image:
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    inset = 56
    inner = 1024 - inset * 2
    rounded = Image.new("L", (inner, inner), 0)
    draw = ImageDraw.Draw(rounded)
    draw.rounded_rectangle(
        (0, 0, inner - 1, inner - 1),
        radius=200,
        fill=255,
    )
    plate = resize(master.convert("RGBA"), inner)
    plate.putalpha(rounded)
    canvas.alpha_composite(plate, (inset, inset))
    return resize(canvas, size)


def main() -> None:
    if not MASTER.exists():
        raise SystemExit(f"Missing master icon: {MASTER}")
    master = Image.open(MASTER).convert("RGBA")
    if master.size != (1024, 1024):
        raise SystemExit(f"Expected a 1024x1024 master, got {master.size}")

    IOS.mkdir(parents=True, exist_ok=True)
    opaque = master.convert("RGB")
    for name, size in IOS_ICONS.items():
        resize(opaque, size).save(IOS / name, format="PNG", optimize=True)

    # macOS 26 masks and adds the glass treatment to full-bleed, opaque art.
    # Transparent margins or baked rounded corners land the app in "icon jail"
    # with a gray plate around the artwork.
    MACOS.mkdir(parents=True, exist_ok=True)
    for name, size in MACOS_ICONS.items():
        resize(opaque, size).save(MACOS / name, format="PNG", optimize=True)

    for name, size in ANDROID_ICONS.items():
        target = ANDROID / name
        target.parent.mkdir(parents=True, exist_ok=True)
        android_icon(master, size).save(target, format="PNG", optimize=True)

    print(f"Distributed app icons to {IOS}, {MACOS}, and {ANDROID}.")


if __name__ == "__main__":
    main()
