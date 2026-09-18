# Pixelizer3D capture regression harness

Screenshot tests for the demo pipeline. The runner drives the Godot CLI
through a small capture matrix, then diffs each PNG against a checked-in
reference with a tolerance.

The demo does not parse the matrix flags and prints no diagnostics line, so
matrix runs fail the diagnostics check (exit 1).

## Layout

```
tests/
  run_captures.py       # runner: capture matrix + diff + exit codes
  compare_captures.py   # PIL diff tool (changed % / mean abs diff)
  captures/             # fresh captures (generated, gitignored)
  logs/                 # per-capture stdout/stderr (generated, gitignored)
  reference/            # reference PNGs (checked in, ~2 MB)
  README.md
```

## Quick start

```powershell
# Capture + compare against the checked-in references. Exit 0 = pass.
python tests/run_captures.py

# Refresh the reference set after an intentional visual change.
python tests/run_captures.py --update-references

# Just one or two captures.
python tests/run_captures.py --only anchor_outline,plain_outline

# Diff two PNGs directly.
python tests/compare_captures.py tests/reference/anchor_outline.png tests/captures/anchor_outline.png
```

The runner defaults to
`C:/Users/Clinton/g/Godot/Godot-stable_mono_win64_console.exe`; override with
`--godot <path>` or the `PIXELIZER_GODOT` / `GODOT_EXE` environment variable.
Pure Python 3 + Pillow (numpy not required).

## Matrix (9 captures, 960x540)

| Name | Args |
|---|---|
| `anchor_terrain` | `--station=0` |
| `anchor_water` | `--station=1` |
| `anchor_outline` | `--station=3` |
| `night_landmark` | `--night --station=2` |
| `debug_anchor_map` | `--debug-view=1 --station=3` |
| `lowres_outline` | `--capture-mode=lowres --station=3` |
| `plain_outline` | `--plain --station=3` |
| `tests_anchor` | `--tests --no-particles --station=6` |
| `tests_perspective` | `--tests --no-particles --perspective --station=6` |

The runner asserts the capture diagnostics JSON (`mode`, `plain`, window
size, and for `tests_*` `mover_count` / `unified_lattice` / `no_dither` /
`perspective`) so a flag that is silently ignored fails instead of comparing the
wrong image, and cross-checks that `plain_outline` and `lowres_outline` really
differ from `anchor_outline` (they are not no-ops).

## Determinism

Each capture runs as:

```
Godot-stable_mono_win64_console.exe --path . --fixed-fps 60 -- \
  --capture=res://tests/captures/<name>.png --resolution=960x540 <args>
```

- `--fixed-fps 60` makes shader `TIME` frame-deterministic (Godot strips the
  engine args from `OS.get_cmdline_args()`, so the demo cannot self-check it).
- The god-ray pass reads the wall clock while `time_override` /
  `ray_time_override < 0`; a value `>= 0` pins the phase.
- Default tolerance (0.05 % changed pixels, mean abs diff 0.05) absorbs
  GPU/driver rounding.

## Tolerances & exit codes

`run_captures.py`:

| Exit | Meaning |
|---|---|
| 0 | all captures ran, all diffs + cross-checks passed |
| 1 | a capture failed (process error, missing PNG, bad diagnostics) |
| 2 | a diff exceeded tolerance (or a cross-check failed) |
| 3 | a reference PNG is missing - run `--update-references` |
| 4 | environment error (Godot binary missing, unknown `--only` name) |

`compare_captures.py`: 0 within tolerance, 1 load error, 2 over tolerance.

Diff defaults: a pixel counts as changed when its max channel delta is **>**
`--pixel-threshold` (3); pass requires `changed_pct <= --max-changed-pct`
(0.05) **and** `mean_abs_diff <= --max-mean` (0.05).

Reference images are the *authority*: if a change is intentional, inspect the
captures in `tests/captures/` and refresh with `--update-references`.
