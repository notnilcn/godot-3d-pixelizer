#!/usr/bin/env python3
"""Pixel-level diff for Pixelizer3D capture regression tests.

Compares two PNGs and reports:
  * changed_pct  - percentage of pixels whose max channel delta is > threshold
  * mean_abs_diff - mean absolute difference across all channels (0-255)
  * max_abs_diff - largest single-channel delta

Usage:
    python tests/compare_captures.py A.png B.png
        [--pixel-threshold 3] [--max-changed-pct 0.05] [--max-mean 0.05]
        [--json] [--quiet]

Exit codes:
    0  within tolerance
    1  could not load / mismatched size
    2  over tolerance

The runner (`run_captures.py`) imports `diff_images()` from this module.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops

DEFAULT_PIXEL_THRESHOLD = 3
DEFAULT_MAX_CHANGED_PCT = 0.05
DEFAULT_MAX_MEAN = 0.05


def load_rgb(path: str | Path) -> Image.Image:
    with Image.open(path) as image:
        return image.convert("RGB")


def diff_images(a: Image.Image, b: Image.Image,
                pixel_threshold: int = DEFAULT_PIXEL_THRESHOLD) -> dict:
    """Return the diff metrics for two same-size RGB images."""
    if a.size != b.size:
        raise ValueError(f"size mismatch: {a.size} vs {b.size}")
    diff = ImageChops.difference(a, b)
    r, g, bl = diff.split()
    # Per-pixel max channel delta -> changed-pixel count.
    max_diff = ImageChops.lighter(ImageChops.lighter(r, g), bl)
    hist = max_diff.histogram()
    total = a.size[0] * a.size[1]
    changed = sum(hist[pixel_threshold + 1:])
    channel_sum = 0
    for band in (r, g, bl):
        band_hist = band.histogram()
        channel_sum += sum(i * band_hist[i] for i in range(256))
    max_abs = max((i for i, count in enumerate(hist) if count), default=0)
    return {
        "width": a.size[0],
        "height": a.size[1],
        "total_pixels": total,
        "changed_pixels": changed,
        "changed_pct": 100.0 * changed / max(total, 1),
        "mean_abs_diff": channel_sum / (3.0 * max(total, 1)),
        "max_abs_diff": max_abs,
    }


def verdict(metrics: dict, max_changed_pct: float, max_mean: float) -> bool:
    return (metrics["changed_pct"] <= max_changed_pct
            and metrics["mean_abs_diff"] <= max_mean)


def format_metrics(metrics: dict) -> str:
    return (f"changed={metrics['changed_pct']:.4f}% "
            f"({metrics['changed_pixels']} px) "
            f"mean={metrics['mean_abs_diff']:.4f} "
            f"max={metrics['max_abs_diff']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("a", type=Path, help="first image (reference)")
    parser.add_argument("b", type=Path, help="second image (capture)")
    parser.add_argument("--pixel-threshold", type=int, default=DEFAULT_PIXEL_THRESHOLD,
                        help="a pixel counts as changed when its max channel delta "
                             f"exceeds this (default {DEFAULT_PIXEL_THRESHOLD})")
    parser.add_argument("--max-changed-pct", type=float, default=DEFAULT_MAX_CHANGED_PCT,
                        help="tolerance for changed_pct (default "
                             f"{DEFAULT_MAX_CHANGED_PCT})")
    parser.add_argument("--max-mean", type=float, default=DEFAULT_MAX_MEAN,
                        help=f"tolerance for mean_abs_diff (default {DEFAULT_MAX_MEAN})")
    parser.add_argument("--json", action="store_true", help="print metrics as JSON")
    parser.add_argument("--quiet", action="store_true", help="suppress the PASS/FAIL line")
    args = parser.parse_args(argv)

    try:
        a = load_rgb(args.a)
        b = load_rgb(args.b)
        metrics = diff_images(a, b, args.pixel_threshold)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    ok = verdict(metrics, args.max_changed_pct, args.max_mean)
    metrics["pass"] = ok
    metrics["max_changed_pct"] = args.max_changed_pct
    metrics["max_mean"] = args.max_mean
    if args.json:
        print(json.dumps(metrics))
    elif not args.quiet:
        print(f"{args.a.name} vs {args.b.name}: {format_metrics(metrics)} "
              f"-> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
