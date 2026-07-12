#!/usr/bin/env python3
"""
Icon generation script for ClipHist.
Converts cliphist.svg to all required PNG sizes, ICO (Windows).

Usage:
    python3 gen_icons.py              # auto-detect best converter
    python3 gen_icons.py --force-png  # regenerate even if PNGs exist
    python3 gen_icons.py --ico-only   # only regenerate ICO from existing PNGs
"""

import os
import shutil
import struct
import subprocess
import sys

SRC = os.path.join(os.path.dirname(__file__), "src-tauri", "icons", "cliphist.svg")
OUT = os.path.join(os.path.dirname(__file__), "src-tauri", "icons")

SIZES = {
    "icon.png": 512,
    "16x16.png": 16,
    "24x24.png": 24,
    "32x32.png": 32,
    "48x48.png": 48,
    "64x64.png": 64,
    "128x128.png": 128,
    "128x128@2x.png": 256,
    "Square30x30Logo.png": 30,
    "Square44x44Logo.png": 44,
    "Square71x71Logo.png": 71,
    "Square89x89Logo.png": 89,
    "Square107x107Logo.png": 107,
    "Square142x142Logo.png": 142,
    "Square150x150Logo.png": 150,
    "Square284x284Logo.png": 284,
    "Square310x310Logo.png": 310,
    "StoreLogo.png": 50,
}
ICO_SIZES = [256, 128, 64, 48, 32, 24, 16]  # desc first so image crate gets 256x256


def find_converter():
    if shutil.which("rsvg-convert"):
        return "rsvg-convert"
    try:
        import cairosvg
        return "cairosvg"
    except ImportError:
        pass
    if shutil.which("inkscape"):
        return "inkscape"
    return None


def convert_rsvg(svg_path, png_path, size):
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", png_path, svg_path],
        check=True,
    )


def convert_cairosvg(svg_path, png_path, size):
    import cairosvg
    cairosvg.svg2png(url=svg_path, write_to=png_path,
                     output_width=size, output_height=size)


def convert_inkscape(svg_path, png_path, size):
    subprocess.run(
        ["inkscape", svg_path, "--export-type=png",
         f"--export-filename={png_path}",
         f"--export-width={size}", f"--export-height={size}"],
        check=True,
    )


def make_ico(out_path):
    """Build ICO from existing PNGs (pure Python, no Pillow needed)."""
    png_data = []
    for size in ICO_SIZES:
        candidates = [
            os.path.join(OUT, f"{size}x{size}.png"),
            os.path.join(OUT, f"Square{size}x{size}Logo.png"),
        ]
        if size == 256:
            candidates.insert(0, os.path.join(OUT, "128x128@2x.png"))
        found = None
        for c in candidates:
            if os.path.exists(c):
                found = c
                break
        if found:
            with open(found, "rb") as f:
                png_data.append((size, f.read()))

    if not png_data:
        print("  No PNGs found, skipping ICO")
        return False

    count = len(png_data)
    header = struct.pack("<HHH", 0, 1, count)
    offset = 6 + count * 16
    entries = b""
    for size, data in png_data:
        w = 0 if size >= 256 else size
        h = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset)
        offset += len(data)

    with open(out_path, "wb") as f:
        f.write(header)
        f.write(entries)
        for _, data in png_data:
            f.write(data)
    print(f"  Generated {out_path} ({count} sizes)")
    return True


def main():
    force = "--force-png" in sys.argv
    ico_only = "--ico-only" in sys.argv

    if not ico_only:
        converter = find_converter()
        if not converter:
            print("Error: No SVG converter found.")
            print("Install one of:")
            print("  Linux:  sudo apt install librsvg2-bin")
            print("  macOS:  brew install librsvg")
            print("  Cross:  pip install cairosvg")
            sys.exit(1)

        print(f"Using converter: {converter}")
        print(f"Source: {SRC}")
        print(f"Output: {OUT}")
        print()

        if not os.path.exists(SRC):
            print(f"Source SVG not found at {SRC}")
            sys.exit(1)

        os.makedirs(OUT, exist_ok=True)
        for name, size in sorted(SIZES.items(), key=lambda x: x[1]):
            dst = os.path.join(OUT, name)
            if os.path.exists(dst) and not force:
                continue
            print(f"  {name} ({size}x{size})...", end=" ", flush=True)
            if converter == "rsvg-convert":
                convert_rsvg(SRC, dst, size)
            elif converter == "cairosvg":
                convert_cairosvg(SRC, dst, size)
            elif converter == "inkscape":
                convert_inkscape(SRC, dst, size)
            print("done")

    # Generate ICO
    ico_dst = os.path.join(OUT, "icon.ico")
    if not os.path.exists(ico_dst) or force or ico_only:
        make_ico(ico_dst)

    print("\nDone! All icons generated.")


if __name__ == "__main__":
    main()
