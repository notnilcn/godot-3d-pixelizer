#!/usr/bin/env python3
"""Pixelizer3D capture regression runner (PLAN section 8).

Runs the demo's deterministic capture matrix through the Godot CLI, saves the
PNGs to tests/captures/, and diffs them against tests/reference/. Also checks
the capture diagnostics JSON (mode / plain / window size) and cross-checks that
`--plain` and `--capture-mode=lowres` really render differently from anchor mode.

Usage:
    python tests/run_captures.py                      # capture + compare
    python tests/run_captures.py --update-references  # refresh reference set
    python tests/run_captures.py --only anchor_outline,plain_outline
    python tests/run_captures.py --list
    python tests/run_captures.py --no-compare         # capture only

Exit codes:
    0  all captures ran and all diffs passed
    1  a capture failed (process error / missing PNG / bad diagnostics)
    2  a diff exceeded tolerance
    3  a reference PNG is missing (run --update-references to create it)
    4  environment error (Godot binary or PIL missing)

Determinism: every run uses `--fixed-fps 60` (engine arg), fixes the window
(`--resolution`, default 960x540) and lets the demo pin the god-ray cloud-field
phase for `--capture` (that pass reads the wall clock, unlike shader TIME).
Run-to-run captures are expected to be byte-identical; the default tolerance is
a hair above zero to absorb GPU rounding.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from compare_captures import diff_images, format_metrics, load_rgb, verdict

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
CAPTURES_DIR = TESTS_DIR / "captures"
REFERENCE_DIR = TESTS_DIR / "reference"
LOGS_DIR = TESTS_DIR / "logs"

DEFAULT_GODOT = "C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe"
DEFAULT_RESOLUTION = "960x540"

# Capture matrix: the smallest set that covers the pipeline modes + stations
# worth regressing. `expect` asserts the diagnostics JSON so a silently ignored
# flag fails the run instead of comparing the wrong image.
MATRIX = [
    {
        "name": "anchor_terrain",
        "args": ["--station=0"],
        "expect": {"mode": "anchor", "plain": False},
    },
    {
        "name": "anchor_water",
        "args": ["--station=1"],
        "expect": {"mode": "anchor", "plain": False},
    },
    {
        "name": "anchor_outline",
        "args": ["--station=3"],
        "expect": {"mode": "anchor", "plain": False},
    },
    {
        "name": "night_landmark",
        "args": ["--night", "--station=2"],
        "expect": {"mode": "anchor", "plain": False},
    },
    {
        "name": "debug_anchor_map",
        "args": ["--debug-view=1", "--station=3"],
        "expect": {"mode": "anchor", "plain": False},
    },
    {
        "name": "lowres_outline",
        "args": ["--capture-mode=lowres", "--station=3"],
        "expect": {"mode": "lowres", "plain": False},
    },
    {
        "name": "plain_outline",
        "args": ["--plain", "--station=3"],
        "expect": {"mode": "anchor", "plain": True},
    },
    {
        "name": "tests_anchor",
        "args": ["--tests", "--no-particles", "--station=6"],
        "expect": {"mode": "anchor", "plain": False, "mover_count": 5,
                   "unified_lattice": True, "no_dither": True},
    },
    {
        "name": "tests_perspective",
        "args": ["--tests", "--no-particles", "--perspective", "--station=6"],
        "expect": {"mode": "anchor", "plain": False, "perspective": True},
    },
]

# (a, b, minimum changed_pct, why) - proves the flag variants are not no-ops.
CROSS_CHECKS = [
    ("anchor_outline", "plain_outline", 1.0,
     "--plain renders un-pixelized, so it must differ from the anchor capture"),
    ("anchor_outline", "lowres_outline", 0.5,
     "low-res mode must differ from anchor mode"),
]

DEFAULT_TOLERANCE = {
    "max_changed_pct": 0.05,
    "max_mean": 0.05,
    "pixel_threshold": 3,
}

EXIT_OK = 0
EXIT_CAPTURE_FAILED = 1
EXIT_DIFF_FAILED = 2
EXIT_MISSING_REFERENCE = 3
EXIT_ENV_ERROR = 4

DIAGNOSTICS_RE = re.compile(r"Pixelizer3D diagnostics: (\{.*\})")
CAPTURE_SAVED_RE = re.compile(r"Pixelizer3D capture saved: (.+?) \(err=(\d+)\)")


def find_godot(explicit: str | None) -> str:
    if explicit:
        return explicit if Path(explicit).is_file() else ""
    for candidate in (os.environ.get("PIXELIZER_GODOT"),
                      os.environ.get("GODOT_EXE"), DEFAULT_GODOT):
        if candidate and Path(candidate).is_file():
            return candidate
    return ""


def parse_log(text: str) -> dict:
    """Extract the capture diagnostics JSON and the saved path/error."""
    info: dict = {"diagnostics": None, "saved_path": None, "save_err": None}
    match = CAPTURE_SAVED_RE.search(text)
    if match:
        info["saved_path"] = match.group(1)
        info["save_err"] = int(match.group(2))
    match = DIAGNOSTICS_RE.search(text)
    if match:
        try:
            info["diagnostics"] = json.loads(match.group(1))
        except json.JSONDecodeError:
            info["diagnostics"] = None
    return info


def run_capture(godot: str, entry: dict, resolution: str, timeout: float) -> dict:
    """Run one matrix entry. Returns a result dict (ok, log_path, diagnostics...)."""
    name = entry["name"]
    level_png = CAPTURES_DIR / f"{name}.png"
    level_log = LOGS_DIR / f"{name}.log"
    rel_png = f"res://tests/captures/{name}.png"
    command = [
        godot, "--path", str(REPO_ROOT), "--fixed-fps", "60", "--",
        f"--capture={rel_png}", f"--resolution={resolution}",
        *entry["args"],
    ]
    started = time.time()
    try:
        proc = subprocess.run(command, cwd=str(REPO_ROOT), capture_output=True,
                              text=True, timeout=timeout)
        stdout, stderr, returncode = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = (exc.stdout or b"").decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = (exc.stderr or b"").decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        returncode = -1
    elapsed = time.time() - started

    level_log.write_text(stdout + "\n----- stderr -----\n" + stderr, encoding="utf-8")
    result = {
        "name": name,
        "args": entry["args"],
        "command": command,
        "ok": True,
        "reasons": [],
        "log": level_log,
        "png": level_png,
        "elapsed": elapsed,
        "diagnostics": None,
    }
    if returncode != 0:
        result["ok"] = False
        result["reasons"].append(f"godot exit code {returncode}")
    if not level_png.is_file():
        result["ok"] = False
        result["reasons"].append("capture PNG missing")
    for line in (stdout + stderr).splitlines():
        if "SCRIPT ERROR" in line or "SHADER ERROR" in line:
            result["ok"] = False
            result["reasons"].append(f"engine error: {line.strip()[:160]}")
            break
    info = parse_log(stdout + stderr)
    result["diagnostics"] = info["diagnostics"]
    if info["saved_path"] is None:
        result["ok"] = False
        result["reasons"].append("no 'capture saved' line")
    elif info["save_err"] not in (0, None):
        result["ok"] = False
        result["reasons"].append(f"save_png error {info['save_err']}")
    if info["diagnostics"] is None:
        result["ok"] = False
        result["reasons"].append("diagnostics dump missing/invalid")
    else:
        diagnostics = info["diagnostics"]
        expected = entry.get("expect", {})
        for key, value in expected.items():
            if diagnostics.get(key) != value:
                result["ok"] = False
                result["reasons"].append(
                    f"diagnostics.{key}={diagnostics.get(key)!r} (expected {value!r})")
        window = diagnostics.get("window")
        wanted = [int(v) for v in resolution.lower().split("x")]
        if window != wanted:
            result["ok"] = False
            result["reasons"].append(f"window={window} (expected {wanted})")
    return result


def subset(matrix: list[dict], only: str | None) -> list[dict]:
    if not only:
        return matrix
    wanted = {name.strip() for name in only.split(",") if name.strip()}
    unknown = wanted - {entry["name"] for entry in matrix}
    if unknown:
        print(f"ERROR: unknown capture name(s): {', '.join(sorted(unknown))}",
              file=sys.stderr)
        raise SystemExit(EXIT_ENV_ERROR)
    return [entry for entry in matrix if entry["name"] in wanted]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=None,
                        help="Godot 4.7 console binary (default: %(default)s or "
                             "PIXELIZER_GODOT/GODOT_EXE)")
    parser.add_argument("--resolution", default=DEFAULT_RESOLUTION,
                        help=f"fixed window size (default {DEFAULT_RESOLUTION})")
    parser.add_argument("--only", default=None,
                        help="comma-separated capture names to run")
    parser.add_argument("--update-references", action="store_true",
                        help="copy the fresh captures into tests/reference/ and exit")
    parser.add_argument("--no-compare", action="store_true",
                        help="capture only; skip the reference diff")
    parser.add_argument("--list", action="store_true", help="list the matrix and exit")
    parser.add_argument("--timeout", type=float, default=300.0,
                        help="per-capture timeout in seconds (default 300)")
    parser.add_argument("--max-changed-pct", type=float,
                        default=DEFAULT_TOLERANCE["max_changed_pct"],
                        help="diff tolerance (default %(default)s)")
    parser.add_argument("--max-mean", type=float,
                        default=DEFAULT_TOLERANCE["max_mean"],
                        help="diff tolerance (default %(default)s)")
    parser.add_argument("--pixel-threshold", type=int,
                        default=DEFAULT_TOLERANCE["pixel_threshold"],
                        help="changed-pixel channel delta threshold (default %(default)s)")
    args = parser.parse_args(argv)

    if args.list:
        for entry in MATRIX:
            print(f"{entry['name']}: {' '.join(entry['args']) or '(no flags)'}")
        return EXIT_OK

    godot = find_godot(args.godot)
    if not godot:
        print("ERROR: Godot console binary not found. Pass --godot <path> or set "
              "PIXELIZER_GODOT.", file=sys.stderr)
        return EXIT_ENV_ERROR

    CAPTURES_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    REFERENCE_DIR.mkdir(parents=True, exist_ok=True)

    entries = subset(MATRIX, args.only)
    print(f"Pixelizer3D capture matrix: {len(entries)} captures at {args.resolution} "
          f"({godot})")
    results = []
    for entry in entries:
        result = run_capture(godot, entry, args.resolution, args.timeout)
        results.append(result)
        flags = " ".join(entry["args"]) or "(no flags)"
        status = "ok" if result["ok"] else "FAIL"
        print(f"  [{status:^4}] {entry['name']:<18} {flags:<34} "
              f"{result['elapsed']:5.1f}s"
              + ("" if result["ok"] else "  <- " + "; ".join(result["reasons"])))

    failed_captures = [r for r in results if not r["ok"]]
    if failed_captures:
        print(f"\nCapture failures ({len(failed_captures)}/{len(results)}):")
        for result in failed_captures:
            print(f"  {result['name']}: {', '.join(result['reasons'])}")
            print(f"    log: {result['log']}")
        return EXIT_CAPTURE_FAILED

    if args.update_references:
        for result in results:
            shutil.copyfile(result["png"], REFERENCE_DIR / result["png"].name)
        print(f"\nReferences refreshed: {len(results)} PNG(s) -> "
              f"{REFERENCE_DIR.relative_to(REPO_ROOT)}")
        return EXIT_OK

    if args.no_compare:
        print("\nCaptures written (comparison skipped).")
        return EXIT_OK

    print(f"\nDiff vs {REFERENCE_DIR.relative_to(REPO_ROOT)} "
          f"(tolerances: changed<={args.max_changed_pct}% mean<={args.max_mean}, "
          f"pixel threshold {args.pixel_threshold}):")
    missing = []
    diff_failures = []
    for result in results:
        reference = REFERENCE_DIR / result["png"].name
        if not reference.is_file():
            missing.append(result)
            print(f"  [MISS] {result['name']:<18} no reference")
            continue
        try:
            metrics = diff_images(load_rgb(reference), load_rgb(result["png"]),
                                  args.pixel_threshold)
        except (OSError, ValueError) as exc:
            diff_failures.append(result)
            print(f"  [FAIL] {result['name']:<18} diff error: {exc}")
            continue
        ok = verdict(metrics, args.max_changed_pct, args.max_mean)
        if not ok:
            diff_failures.append(result)
        print(f"  [{'PASS' if ok else 'FAIL'}] {result['name']:<18} "
              f"{format_metrics(metrics)}")

    cross_failures = []
    if not args.only:
        print("Cross-checks (flag variants are not no-ops):")
        for name_a, name_b, minimum, why in CROSS_CHECKS:
            png_a = CAPTURES_DIR / f"{name_a}.png"
            png_b = CAPTURES_DIR / f"{name_b}.png"
            if not (png_a.is_file() and png_b.is_file()):
                continue
            metrics = diff_images(load_rgb(png_a), load_rgb(png_b),
                                  args.pixel_threshold)
            ok = metrics["changed_pct"] >= minimum
            if not ok:
                cross_failures.append((name_a, name_b))
            print(f"  [{'PASS' if ok else 'FAIL'}] {name_a} vs {name_b}: "
                  f"changed={metrics['changed_pct']:.2f}% "
                  f"(min {minimum:.2f}%) - {why}")

    exit_code = EXIT_OK
    if missing:
        exit_code = EXIT_MISSING_REFERENCE
    if diff_failures or cross_failures:
        exit_code = EXIT_DIFF_FAILED
    print()
    if exit_code == EXIT_OK:
        print(f"PASS: {len(results)} captures, all diffs within tolerance "
              f"(exit {EXIT_OK})")
    elif exit_code == EXIT_MISSING_REFERENCE:
        print(f"FAIL: {len(missing)} reference(s) missing - refresh with "
              f"`python tests/run_captures.py --update-references` "
              f"(exit {EXIT_MISSING_REFERENCE})", file=sys.stderr)
    else:
        print(f"FAIL: {len(diff_failures)} diff failure(s), "
              f"{len(cross_failures)} cross-check failure(s) "
              f"(exit {EXIT_DIFF_FAILED})", file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
