#!/usr/bin/env python3
"""
LifeOS Wallpaper Optimization Script

Converts SVG wallpapers to optimized PNG format for different screen resolutions.
Generates multiple sizes for responsive loading.

Usage:
    python3 optimize-wallpapers.py [--input-dir DIR] [--output-dir DIR] [--resolutions RES]

Example:
    python3 optimize-wallpapers.py --input-dir ./svg --output-dir ./png --resolutions 1920x1080,2560x1440,3840x2160
"""

import argparse
import subprocess
import sys
from pathlib import Path
from typing import List, Tuple


# Default resolutions for common display sizes
DEFAULT_RESOLUTIONS = [
    (1920, 1080),  # Full HD
    (2560, 1440),  # QHD / 2K
    (3840, 2160),  # 4K UHD
    (1366, 768),  # Common laptop
    (1600, 900),  # HD+
]


def check_dependencies() -> bool:
    """Check if required tools are installed."""
    dependencies = ["rsvg-convert", "optipng"]
    missing = []

    for dep in dependencies:
        try:
            subprocess.run(["which", dep], capture_output=True, check=True)
        except subprocess.CalledProcessError:
            missing.append(dep)

    if missing:
        print(f"Missing dependencies: {', '.join(missing)}")
        print("\nInstall with:")
        if "rsvg-convert" in missing:
            print("  sudo dnf install librsvg2-tools  # Fedora")
            print("  sudo apt install librsvg2-bin    # Debian/Ubuntu")
        if "optipng" in missing:
            print("  sudo dnf install optipng         # Fedora")
            print("  sudo apt install optipng         # Debian/Ubuntu")
        return False

    return True


def svg_to_png(svg_path: Path, output_path: Path, width: int, height: int) -> bool:
    """Convert SVG to PNG at specified resolution."""
    try:
        cmd = [
            "rsvg-convert",
            "-w",
            str(width),
            "-h",
            str(height),
            "-o",
            str(output_path),
            str(svg_path),
        ]
        subprocess.run(cmd, capture_output=True, check=True)
        return True
    except subprocess.CalledProcessError as e:
        print(f"Error converting {svg_path}: {e.stderr.decode()}")
        return False


def optimize_png(png_path: Path, level: int = 3) -> bool:
    """Optimize PNG file size with optipng."""
    try:
        cmd = ["optipng", f"-o{level}", "-quiet", str(png_path)]
        subprocess.run(cmd, capture_output=True, check=True)
        return True
    except subprocess.CalledProcessError as e:
        print(f"Error optimizing {png_path}: {e.stderr.decode()}")
        return False


def parse_resolution(res_str: str) -> Tuple[int, int]:
    """Parse resolution string like '1920x1080' to tuple."""
    try:
        w, h = res_str.lower().split("x")
        return (int(w), int(h))
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid resolution: {res_str}. Use format: WIDTHxHEIGHT"
        )


def process_wallpaper(
    svg_file: Path, output_dir: Path, resolutions: List[Tuple[int, int]]
) -> dict:
    """Process a single SVG wallpaper file."""
    results = {"success": [], "failed": []}
    base_name = svg_file.stem

    print(f"\nProcessing: {svg_file.name}")

    for width, height in resolutions:
        # Create resolution-specific subdirectory
        res_dir = output_dir / f"{width}x{height}"
        res_dir.mkdir(parents=True, exist_ok=True)

        # Output filename
        output_file = res_dir / f"{base_name}.png"

        print(f"  → {width}x{height}...", end=" ")

        # Convert SVG to PNG
        if svg_to_png(svg_file, output_file, width, height):
            # Optimize PNG
            if optimize_png(output_file):
                size_kb = output_file.stat().st_size / 1024
                print(f"✓ ({size_kb:.1f} KB)")
                results["success"].append((width, height, output_file))
            else:
                print("✗ (optimization failed)")
                results["failed"].append((width, height, output_file))
        else:
            print("✗ (conversion failed)")
            results["failed"].append((width, height, output_file))

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Optimize LifeOS wallpapers from SVG to PNG"
    )
    parser.add_argument(
        "--input-dir",
        "-i",
        type=Path,
        default=Path("."),
        help="Input directory containing SVG files (default: current directory)",
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        type=Path,
        default=Path("./optimized"),
        help="Output directory for PNG files (default: ./optimized)",
    )
    parser.add_argument(
        "--resolutions",
        "-r",
        type=str,
        help="Comma-separated resolutions (e.g., 1920x1080,2560x1440)",
    )
    parser.add_argument(
        "--optimize-level",
        type=int,
        default=3,
        choices=range(0, 8),
        help="PNG optimization level 0-7 (default: 3)",
    )

    args = parser.parse_args()

    # Check dependencies
    if not check_dependencies():
        sys.exit(1)

    # Parse resolutions
    if args.resolutions:
        resolutions = [parse_resolution(r) for r in args.resolutions.split(",")]
    else:
        resolutions = DEFAULT_RESOLUTIONS

    # Find SVG files
    svg_files = list(args.input_dir.glob("*.svg"))

    if not svg_files:
        print(f"No SVG files found in {args.input_dir}")
        sys.exit(1)

    print(f"Found {len(svg_files)} SVG file(s)")
    print(f"Resolutions: {', '.join(f'{w}x{h}' for w, h in resolutions)}")
    print(f"Output directory: {args.output_dir}")

    # Create output directory
    args.output_dir.mkdir(parents=True, exist_ok=True)

    # Process each file
    total_success = 0
    total_failed = 0

    for svg_file in sorted(svg_files):
        results = process_wallpaper(svg_file, args.output_dir, resolutions)
        total_success += len(results["success"])
        total_failed += len(results["failed"])

    # Summary
    print(f"\n{'=' * 50}")
    print(f"Summary:")
    print(f"  Total generated: {total_success}")
    print(f"  Failed: {total_failed}")

    if total_failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
