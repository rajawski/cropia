#!/usr/bin/env python3
"""
cropia v1.0.0
Lossless-aware batch image cropper.

Usage:
  python cropia.py [OPTIONS] INPUT_DIR OUTPUT_DIR
  python cropia.py --help
"""

import argparse
import configparser
import csv
import fnmatch
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional, Tuple

try:
    from PIL import Image as PILImage
    PILLOW_AVAILABLE = True
except ImportError:
    PILLOW_AVAILABLE = False

VERSION = "1.1.0"
MCU = 16  # JPEG MCU block size - all offsets and dimensions must be multiples of this



VALID_GRAVITIES = [
    "center",
    "top", "bottom", "left", "right",
    "top-left", "top-right", "bottom-left", "bottom-right",
]
VALID_FORMATS = ["jpg", "png", "webp", "tiff"]
INPUT_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif"}


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class CropOptions:
    input_dir:  str   = "./input"
    output_dir: str   = "./cropped"
    ratio:      str   = "3:2"
    gravity:    str   = "bottom"
    fmt:        str   = ""       # empty = preserve input format
    suffix:     str   = ""
    overwrite:  bool  = False
    skip:       bool  = False
    dry_run:    bool  = False
    verbose:    bool  = False
    recursive:  bool  = False
    pattern:    str   = ""
    min_mp:     float = 0.0
    max_mp:     float = 0.0
    preview:    bool  = False
    log_file:   str   = ""


@dataclass
class FileResult:
    filename:    str
    orig_width:  str
    orig_height: str
    crop_width:  str
    crop_height: str
    offset_x:   str
    offset_y:   str
    ratio:       str
    gravity:     str
    output_path: str
    status:      str


@dataclass
class RunSummary:
    found:       int = 0
    processed:   int = 0
    skipped:     int = 0
    failed:      int = 0
    bytes_saved: int = 0
    results: List[FileResult] = field(default_factory=list)


# =============================================================================
# Dependency Checking
# =============================================================================

def check_dependencies(opts: CropOptions) -> List[str]:
    """
    Return a list of human-readable missing dependency strings.
    Empty list means all required tools are present.
    """
    missing = []

    if not shutil.which("jpegtran"):
        missing.append(
            "jpegtran  ->  brew install jpeg (macOS)  "
            "|  apt install libjpeg-turbo-progs (Linux)"
        )

    needs_pillow = opts.fmt not in ("", "jpg") or True  # Pillow handles all non-JPEG paths
    if not PILLOW_AVAILABLE:
        missing.append(
            "Pillow  ->  pip install Pillow"
        )

    if not shutil.which("sips") and not shutil.which("identify"):
        missing.append(
            "sips (built-in on macOS)  OR  "
            "ImageMagick identify  ->  brew install imagemagick  |  apt install imagemagick\n"            "  (only needed for dimension reading on Linux - not required on macOS)"
        )

    return missing


# =============================================================================
# Config File
# =============================================================================

def load_config_file(path: str) -> dict:
    """
    Load options from a config file. Supports two formats:
      INI with [crop-tool] section   (preferred)
      Bare key=value lines           (bash-compatible legacy)

    Returns a dict of key -> string value.
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Config file not found: {path}")

    text = p.read_text()

    # Try INI format
    cfg = configparser.ConfigParser()
    try:
        cfg.read_string(text)
        for section in ("crop-tool", "options", "DEFAULT"):
            if section in cfg:
                return dict(cfg[section])
    except configparser.Error:
        pass

    # Fall back to bare key=value
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            result[k.strip().lower().replace("-", "_")] = v.strip()
    return result


def apply_config(opts: CropOptions, cfg: dict):
    """Merge a config dict into a CropOptions instance."""
    bool_fields  = {"overwrite", "skip", "dry_run", "verbose", "recursive", "preview"}
    float_fields = {"min_mp", "max_mp"}

    key_map = {
        "ratio": "ratio", "gravity": "gravity",
        "format": "fmt",  "fmt": "fmt",
        "suffix": "suffix",
        "overwrite": "overwrite", "skip": "skip",
        "dry_run": "dry_run", "dryrun": "dry_run",
        "verbose": "verbose", "recursive": "recursive",
        "pattern": "pattern",
        "min_mp": "min_mp", "minmp": "min_mp",
        "max_mp": "max_mp", "maxmp": "max_mp",
        "preview": "preview",
        "log": "log_file", "log_file": "log_file",
    }

    for raw_key, val in cfg.items():
        attr = key_map.get(raw_key.lower().replace("-", "_"))
        if attr is None:
            continue
        if attr in bool_fields:
            setattr(opts, attr, val.lower() in ("true", "1", "yes"))
        elif attr in float_fields:
            try:
                setattr(opts, attr, float(val))
            except ValueError:
                pass
        else:
            setattr(opts, attr, val)


# =============================================================================
# Validation
# =============================================================================

def validate(opts: CropOptions) -> List[str]:
    """Return a list of validation error strings. Empty means valid."""
    errors = []

    if not Path(opts.input_dir).is_dir():
        errors.append(f"Input directory not found: '{opts.input_dir}'")

    parts = opts.ratio.split(":")
    if len(parts) != 2:
        errors.append(f"Invalid ratio '{opts.ratio}' - use A:B format (e.g. 3:2, 16:9)")
    else:
        try:
            a, b = int(parts[0]), int(parts[1])
            if a <= 0 or b <= 0:
                errors.append("Ratio values must be greater than zero")
        except ValueError:
            errors.append(f"Ratio values must be integers (got '{opts.ratio}')")

    if opts.gravity not in VALID_GRAVITIES:
        errors.append(
            f"Invalid gravity '{opts.gravity}'. "
            f"Valid: {', '.join(VALID_GRAVITIES)}"
        )

    if opts.fmt:
        if opts.fmt.lower() not in VALID_FORMATS + ["jpeg"]:
            errors.append(
                f"Invalid format '{opts.fmt}'. "
                f"Valid: {', '.join(VALID_FORMATS)}"
            )

    if opts.overwrite and opts.skip:
        errors.append("--overwrite and --skip are mutually exclusive")

    if opts.log_file:
        ext = Path(opts.log_file).suffix.lower()
        if ext not in (".csv", ".json"):
            errors.append(
                f"Log file must end in .csv or .json (got '{ext}')"
            )

    return errors


# =============================================================================
# Image Utilities
# =============================================================================

def get_image_dims(filepath: Path) -> Tuple[int, int]:
    """
    Return (width, height) for an image.
    Uses sips on macOS, ImageMagick identify on Linux/Windows.
    Raises ValueError if dimensions cannot be determined.
    """
    if shutil.which("sips"):
        r = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(filepath)],
            capture_output=True, text=True
        )
        w = h = None
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("pixelWidth:"):
                try:
                    w = int(line.split(":")[1].strip())
                except ValueError:
                    pass
            elif line.startswith("pixelHeight:"):
                try:
                    h = int(line.split(":")[1].strip())
                except ValueError:
                    pass
        if w and h:
            return w, h

    if shutil.which("identify"):
        # [0] handles multi-frame images (animated webp, etc.)
        r = subprocess.run(
            ["identify", "-format", "%w %h", f"{filepath}[0]"],
            capture_output=True, text=True,
        )
        parts = r.stdout.strip().split()
        if len(parts) >= 2:
            try:
                return int(parts[0]), int(parts[1])
            except ValueError:
                pass

    raise ValueError(f"Could not read image dimensions for '{filepath.name}'")


def compute_offsets(
    img_w: int, img_h: int,
    crop_w: int, crop_h: int,
    gravity: str,
    snap_to_mcu: bool = False,
) -> Tuple[int, int]:
    """
    Compute (offset_x, offset_y) for a given gravity.
    When snap_to_mcu is True (JPG-to-JPG lossless path only), offsets are
    rounded down to the nearest 16px MCU block boundary. For all other formats
    (PNG, WEBP, TIFF) exact pixel offsets are used - no rounding needed.
    """
    slack_x = img_w - crop_w
    slack_y = img_h - crop_h

    gravity_map = {
        "top-left":     (0,             0),
        "top":          (slack_x // 2,  0),
        "top-right":    (slack_x,       0),
        "left":         (0,             slack_y // 2),
        "center":       (slack_x // 2,  slack_y // 2),
        "right":        (slack_x,       slack_y // 2),
        "bottom-left":  (0,             slack_y),
        "bottom":       (slack_x // 2,  slack_y),
        "bottom-right": (slack_x,       slack_y),
    }

    raw_x, raw_y = gravity_map[gravity]
    if snap_to_mcu:
        offset_x = (raw_x // MCU) * MCU
        offset_y = (raw_y // MCU) * MCU
    else:
        offset_x = raw_x
        offset_y = raw_y
    return offset_x, offset_y


def human_bytes(n: int) -> str:
    """Format an absolute byte count as a human-readable string."""
    a = abs(n)
    if a >= 1_073_741_824:
        return f"{a / 1_073_741_824:.1f} GB"
    if a >= 1_048_576:
        return f"{a / 1_048_576:.1f} MB"
    if a >= 1_024:
        return f"{a / 1_024:.1f} KB"
    return f"{a} bytes"


# =============================================================================
# Core Crop Engine
# =============================================================================

class CropEngine:
    """
    Main processing engine, decoupled from I/O so it works identically
    under the CLI and the Tkinter GUI.

    Callbacks
    ---------
    on_log(level: str, message: str)
        level is one of: "info", "ok", "warn", "err", "verbose"

    on_progress(current: int, total: int)
        Called after each file is processed.

    stop_event: threading.Event (optional)
        When set, the engine stops after the current file.
    """

    def __init__(
        self,
        opts: CropOptions,
        on_log:      Optional[Callable[[str, str], None]] = None,
        on_progress: Optional[Callable[[int, int], None]] = None,
        stop_event=None,
    ):
        self.opts      = opts
        self._log      = on_log      or (lambda level, msg: None)
        self._progress = on_progress or (lambda cur, total: None)
        self._stop     = stop_event
        self.summary   = RunSummary()

    # ------------------------------------------------------------------
    def run(self) -> RunSummary:
        opts = self.opts

        # Normalize format
        if opts.fmt:
            opts.fmt = opts.fmt.lower()
            if opts.fmt == "jpeg":
                opts.fmt = "jpg"

        files = self._collect_files()
        total = len(files)

        if total == 0:
            self._log("warn", f"No matching images found in '{opts.input_dir}'")
            if opts.pattern:
                self._log("warn", f"  Pattern filter was active: '{opts.pattern}'")
            return self.summary

        self._log("info", f"Found {total} file(s) to process")
        self.summary.found = total

        for i, filepath in enumerate(files, 1):
            if self._stop and self._stop.is_set():
                self._log("warn", "Stopped by user.")
                break
            self._process_file(filepath)
            self._progress(i, total)

        return self.summary

    # ------------------------------------------------------------------
    def _collect_files(self) -> List[Path]:
        opts  = self.opts
        root  = Path(opts.input_dir)
        globber = root.rglob if opts.recursive else root.glob

        seen:  set  = set()
        files: list = []

        for ext in INPUT_EXTENSIONS:
            for f in sorted(globber(f"*{ext}")):
                if f not in seen:
                    seen.add(f)
                    files.append(f)
            for f in sorted(globber(f"*{ext.upper()}")):
                if f not in seen:
                    seen.add(f)
                    files.append(f)

        files.sort()

        if opts.pattern:
            files = [f for f in files if fnmatch.fnmatch(f.name, opts.pattern)]

        return files

    # ------------------------------------------------------------------
    def _process_file(self, filepath: Path):
        opts   = self.opts
        fn     = filepath.name
        stem   = filepath.stem
        in_ext = filepath.suffix.lower().lstrip(".")
        if in_ext == "jpeg":
            in_ext = "jpg"

        out_ext = opts.fmt if opts.fmt else in_ext

        # Build output path (mirrors subdir structure in recursive mode)
        if opts.recursive:
            rel     = filepath.relative_to(opts.input_dir)
            out_dir = Path(opts.output_dir) / rel.parent
        else:
            out_dir = Path(opts.output_dir)

        output = out_dir / f"{stem}{opts.suffix}.{out_ext}"

        # --- Readability ---
        if not filepath.is_file() or not os.access(filepath, os.R_OK):
            self._log("err", f"{fn}: cannot read file - skipping")
            self.summary.failed += 1
            self._record(fn, "?", "?", "-", "-", "-", "-", output, "failed:unreadable")
            return

        # --- Dimensions ---
        try:
            img_w, img_h = get_image_dims(filepath)
        except Exception as e:
            self._log("err", f"{fn}: {e}")
            self.summary.failed += 1
            self._record(fn, "?", "?", "-", "-", "-", "-", output, "failed:no-dimensions")
            return

        self._log("verbose", f"{fn}  {img_w}x{img_h}")

        # --- Megapixel filter ---
        mp = (img_w * img_h) / 1_000_000
        if opts.min_mp > 0 and mp < opts.min_mp:
            self._log("verbose", f"Skipping {fn}: {mp:.2f}MP < min {opts.min_mp}MP")
            self.summary.skipped += 1
            self._record(fn, img_w, img_h, "-", "-", "-", "-", output, "skipped:below-min-mp")
            return
        if opts.max_mp > 0 and mp > opts.max_mp:
            self._log("verbose", f"Skipping {fn}: {mp:.2f}MP > max {opts.max_mp}MP")
            self.summary.skipped += 1
            self._record(fn, img_w, img_h, "-", "-", "-", "-", output, "skipped:above-max-mp")
            return

        # --- Output conflict ---
        if output.exists():
            if opts.skip:
                self._log("verbose", f"Skipping {fn}: output already exists")
                self.summary.skipped += 1
                self._record(fn, img_w, img_h, "-", "-", "-", "-", output, "skipped:exists")
                return
            elif not opts.overwrite and not opts.dry_run:
                self._log("err",
                    f"{fn}: output exists at '{output}' - use --overwrite or --skip"
                )
                self.summary.failed += 1
                self._record(fn, img_w, img_h, "-", "-", "-", "-", output, "failed:conflict")
                return

        # --- Crop dimensions ---
        a, b = (int(x) for x in opts.ratio.split(":"))
        is_lossless_jpeg = in_ext in ("jpg", "jpeg") and out_ext == "jpg"

        if is_lossless_jpeg:
            # MCU-aligned path: dimensions must be multiples of A*16 and B*16
            w_block = a * MCU
            h_block = b * MCU
            n = min(img_w // w_block, img_h // h_block)
            if n == 0:
                self._log("warn",
                    f"{fn}: too small for {opts.ratio} at MCU alignment "
                    f"({img_w}x{img_h}, need >= {w_block}x{h_block})"
                )
                self.summary.skipped += 1
                self._record(fn, img_w, img_h, "0", "0", "0", "0", output, "skipped:too-small")
                return
            crop_w = n * w_block
            crop_h = n * h_block
        else:
            # Exact pixel path: largest crop at ratio A:B that fits the image
            if img_w * b >= img_h * a:
                crop_h = img_h
                crop_w = img_h * a // b
            else:
                crop_w = img_w
                crop_h = img_w * b // a
            if crop_w == 0 or crop_h == 0:
                self._log("warn", f"{fn}: too small for ratio {opts.ratio} ({img_w}x{img_h})")
                self.summary.skipped += 1
                self._record(fn, img_w, img_h, "0", "0", "0", "0", output, "skipped:too-small")
                return

        offset_x, offset_y = compute_offsets(
            img_w, img_h, crop_w, crop_h, opts.gravity,
            snap_to_mcu=is_lossless_jpeg,
        )

        self._log("verbose",
            f"  Crop: {crop_w}x{crop_h} at +{offset_x}+{offset_y}  (gravity: {opts.gravity})"
        )

        # --- Dry run ---
        if opts.dry_run:
            self._log("info",
                f"[DRY RUN] {fn}  "
                f"{img_w}x{img_h} -> {crop_w}x{crop_h} "
                f"@ +{offset_x}+{offset_y}  ({opts.gravity})"
            )
            self.summary.processed += 1
            self._record(fn, img_w, img_h, crop_w, crop_h,
                         offset_x, offset_y, output, "dry-run")
            return

        # --- Perform crop ---
        out_dir.mkdir(parents=True, exist_ok=True)
        success = False

        if is_lossless_jpeg:
            success = self._jpegtran(filepath, output, crop_w, crop_h, offset_x, offset_y)
        else:
            if in_ext in ("jpg", "jpeg") and out_ext != "jpg":
                self._log("verbose", f"  Note: JPG -> {out_ext} will re-encode (not lossless)")
            # PNG, WEBP, TIFF: ImageMagick crops natively without roundtripping through JPEG
            success = self._pillow_crop(filepath, output, crop_w, crop_h, offset_x, offset_y)

        # --- Result ---
        if success:
            orig_size = filepath.stat().st_size
            new_size  = output.stat().st_size
            self.summary.bytes_saved += orig_size - new_size
            self._log("ok", f"{fn}  {img_w}x{img_h} -> {crop_w}x{crop_h}")
            self.summary.processed += 1
            self._record(fn, img_w, img_h, crop_w, crop_h,
                         offset_x, offset_y, output, "ok")
            if opts.preview:
                self._make_preview(filepath, fn, img_w, img_h,
                                   crop_w, crop_h, offset_x, offset_y)
        else:
            self._log("err", f"{fn}: crop command failed")
            self.summary.failed += 1
            if output.exists():
                output.unlink()
            self._record(fn, img_w, img_h, crop_w, crop_h,
                         offset_x, offset_y, output, "failed:crop-error")

    # ------------------------------------------------------------------
    def _jpegtran(self, src, dst, cw, ch, ox, oy) -> bool:
        """Lossless JPEG crop via jpegtran. Output is written to dst."""
        r = subprocess.run(
            ["jpegtran",
             "-crop", f"{cw}x{ch}+{ox}+{oy}",
             "-copy", "all",
             "-optimize",
             str(src)],
            capture_output=True
        )
        if r.returncode == 0 and r.stdout:
            Path(dst).write_bytes(r.stdout)
            return True
        return False

    def _pillow_crop(self, src, dst, cw, ch, ox, oy) -> bool:
        """Lossless-quality crop via Pillow. Handles PNG, WEBP, TIFF natively."""
        try:
            with PILImage.open(src) as img:
                box = (ox, oy, ox + cw, oy + ch)
                cropped = img.crop(box)
                # Preserve metadata where possible
                save_kwargs = {}
                fmt = img.format or Path(dst).suffix.lstrip(".").upper()
                if fmt == "JPG":
                    fmt = "JPEG"
                if fmt == "WEBP":
                    save_kwargs["quality"] = 100
                    save_kwargs["method"] = 6
                elif fmt == "TIFF":
                    save_kwargs["compression"] = "tiff_lzw"
                elif fmt == "PNG":
                    save_kwargs["optimize"] = True
                cropped.save(str(dst), format=fmt, **save_kwargs)
            return True
        except Exception as e:
            self._log("err", f"  Pillow error: {e}")
            return False

    def _make_preview(self, filepath, fn, iw, ih, cw, ch, ox, oy):
        """Generate a scaled-down preview image with the crop rect drawn on it."""
        if not PILLOW_AVAILABLE:
            self._log("warn", "  Preview skipped: Pillow not installed")
            return

        try:
            from PIL import ImageDraw, ImageFont
        except ImportError:
            self._log("warn", "  Preview skipped: Pillow not installed")
            return

        preview_dir = Path(self.opts.output_dir) / "previews"
        preview_dir.mkdir(parents=True, exist_ok=True)
        out = preview_dir / f"{Path(fn).stem}_preview.jpg"

        pmax  = 1000
        scale = min(pmax / iw, 1.0)

        try:
            with PILImage.open(filepath) as img:
                # Scale down for preview
                pw = int(iw * scale)
                ph = int(ih * scale)
                preview = img.convert("RGB").resize((pw, ph), PILImage.LANCZOS)

                # Draw crop rectangle
                rx1 = int(ox * scale)
                ry1 = int(oy * scale)
                rx2 = int((ox + cw - 1) * scale)
                ry2 = int((oy + ch - 1) * scale)

                draw = ImageDraw.Draw(preview)
                draw.rectangle([rx1, ry1, rx2, ry2], outline="#00e676", width=2)

                label = f"{cw}x{ch}  |  {self.opts.ratio}  |  {self.opts.gravity}"
                draw.text((rx1 + 6, ry1 + 6), label, fill="#00e676")

                preview.save(str(out), format="JPEG", quality=85)
            self._log("verbose", f"  Preview -> {out}")
        except Exception as e:
            self._log("warn", f"  Preview generation failed for {fn}: {e}")

    # ------------------------------------------------------------------
    def _record(self, fn, ow, oh, cw, ch, ox, oy, output, status):
        self.summary.results.append(FileResult(
            filename=str(fn), orig_width=str(ow), orig_height=str(oh),
            crop_width=str(cw), crop_height=str(ch),
            offset_x=str(ox), offset_y=str(oy),
            ratio=self.opts.ratio, gravity=self.opts.gravity,
            output_path=str(output), status=status,
        ))


# =============================================================================
# Log Writing
# =============================================================================

LOG_FIELDS = [
    "filename", "orig_width", "orig_height",
    "crop_width", "crop_height", "offset_x", "offset_y",
    "ratio", "gravity", "output_path", "status",
]


def write_log(log_file: str, results: List[FileResult]):
    ext = Path(log_file).suffix.lower()

    if ext == ".csv":
        with open(log_file, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=LOG_FIELDS)
            writer.writeheader()
            for r in results:
                writer.writerow({
                    "filename":    r.filename,   "orig_width":  r.orig_width,
                    "orig_height": r.orig_height, "crop_width":  r.crop_width,
                    "crop_height": r.crop_height, "offset_x":   r.offset_x,
                    "offset_y":    r.offset_y,   "ratio":       r.ratio,
                    "gravity":     r.gravity,     "output_path": r.output_path,
                    "status":      r.status,
                })

    elif ext == ".json":
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump(
                [
                    {
                        "filename":    r.filename,   "orig_width":  r.orig_width,
                        "orig_height": r.orig_height, "crop_width":  r.crop_width,
                        "crop_height": r.crop_height, "offset_x":   r.offset_x,
                        "offset_y":    r.offset_y,   "ratio":       r.ratio,
                        "gravity":     r.gravity,     "output_path": r.output_path,
                        "status":      r.status,
                    }
                    for r in results
                ],
                f, indent=2
            )
    else:
        raise ValueError(f"Log file must end in .csv or .json (got '{ext}')")


# =============================================================================
# CLI
# =============================================================================

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="cropia",
        description=f"crop-tool v{VERSION} - Lossless-aware batch image cropper",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
RATIO SYSTEM
  The MCU-aligned formula: W_block = A*16, H_block = B*16
  Common values:  3:2 (default)  16:9  4:5  1:1  5:4  4:3

CONFIG FILE FORMAT
  INI with [crop-tool] section (preferred):
    [crop-tool]
    ratio   = 16:9
    gravity = center
    suffix  = _web
    skip    = true

  Or bare key=value (legacy bash-compat):
    ratio=16:9
    gravity=center

EXAMPLES
  python crop_tool.py ./photos ./out
  python crop_tool.py ./photos ./out --ratio 16:9 --gravity center
  python crop_tool.py ./photos ./out --format png --suffix _web --skip
  python crop_tool.py ./photos ./out --dry-run --verbose --log results.json
  python crop_tool.py ./photos ./out --config my-shoot.conf --suffix _v2
  python crop_tool.py ./photos ./out --recursive --pattern "DSC_*" --min-mp 10
  python crop_tool.py ./photos ./out --preview
""",
    )

    p.add_argument("input_dir",  nargs="?", default="./input",   metavar="INPUT_DIR",
                   help="Source directory (default: ./input)")
    p.add_argument("output_dir", nargs="?", default="./cropped", metavar="OUTPUT_DIR",
                   help="Output directory (default: ./cropped)")

    g = p.add_argument_group("crop")
    g.add_argument("--ratio",   default="3:2",
                   help="Aspect ratio, e.g. 3:2 16:9 4:5 1:1 (default: 3:2)")
    g.add_argument("--gravity", default="bottom", choices=VALID_GRAVITIES, metavar="ANCHOR",
                   help=f"Crop anchor: {', '.join(VALID_GRAVITIES)}")

    g = p.add_argument_group("output")
    g.add_argument("--format",    dest="fmt", default="",
                   choices=VALID_FORMATS + ["jpeg"], metavar="FORMAT",
                   help="Output format: jpg, png, webp, tiff (default: preserve input)")
    g.add_argument("--suffix",    default="", metavar="TEXT",
                   help="Append before extension, e.g. _web")
    g.add_argument("--overwrite", action="store_true",
                   help="Replace existing output files")
    g.add_argument("--skip",      action="store_true",
                   help="Skip if output file already exists")

    g = p.add_argument_group("filtering")
    g.add_argument("--recursive", action="store_true",
                   help="Walk subdirectories, mirroring structure in output")
    g.add_argument("--pattern",   default="", metavar="GLOB",
                   help='Filter input filenames by glob, e.g. "DSC_*"')
    g.add_argument("--min-mp",    type=float, default=0, metavar="N",
                   help="Skip images below N megapixels")
    g.add_argument("--max-mp",    type=float, default=0, metavar="N",
                   help="Skip images above N megapixels")

    g = p.add_argument_group("modes")
    g.add_argument("--dry-run",  action="store_true",
                   help="Show what would happen without writing any files")
    g.add_argument("--preview",  action="store_true",
                   help="Save crop-overlay previews to OUTPUT_DIR/previews/")
    g.add_argument("--verbose",  action="store_true",
                   help="Print per-file processing detail")
    g.add_argument("--config",   default="", metavar="FILE",
                   help="Load options from a config file (CLI flags take precedence)")

    p.add_argument("--log",     default="", metavar="FILE",
                   help="Export per-file results log (.csv or .json)")
    p.add_argument("--version", action="version", version=f"crop-tool {VERSION}")

    return p


def _cli_log(level: str, msg: str):
    icons = {"info": "i", "ok": "+", "warn": "!", "err": "x", "verbose": " "}
    print(f"  {icons.get(level, ' ')}  {msg}")


def main():
    # Two-pass config: scan for --config first so it becomes the baseline,
    # then re-parse so explicit CLI flags override config values.
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--config", default="")
    pre_args, _ = pre.parse_known_args()

    parser  = _build_parser()
    base    = CropOptions()

    if pre_args.config:
        try:
            cfg = load_config_file(pre_args.config)
            apply_config(base, cfg)
            _cli_log("info", f"Loaded config: {pre_args.config}")
        except FileNotFoundError as e:
            _cli_log("err", str(e))
            sys.exit(1)

    # Set parser defaults from config so argparse defaults are overridden,
    # but any explicit CLI flag still wins.
    parser.set_defaults(
        ratio=base.ratio, gravity=base.gravity, fmt=base.fmt,
        suffix=base.suffix, overwrite=base.overwrite, skip=base.skip,
        dry_run=base.dry_run, verbose=base.verbose, recursive=base.recursive,
        pattern=base.pattern, min_mp=base.min_mp, max_mp=base.max_mp,
        preview=base.preview, log=base.log_file,
    )

    args = parser.parse_args()

    opts = CropOptions(
        input_dir=args.input_dir, output_dir=args.output_dir,
        ratio=args.ratio, gravity=args.gravity,
        fmt=args.fmt or "", suffix=args.suffix,
        overwrite=args.overwrite, skip=args.skip,
        dry_run=args.dry_run, verbose=args.verbose, recursive=args.recursive,
        pattern=args.pattern, min_mp=args.min_mp, max_mp=args.max_mp,
        preview=args.preview, log_file=args.log,
    )

    errors = validate(opts)
    if errors:
        for e in errors:
            _cli_log("err", e)
        sys.exit(1)

    missing = check_dependencies(opts)
    if missing:
        _cli_log("err", "Missing required dependencies:")
        for m in missing:
            print(f"      - {m}")
        sys.exit(1)

    # Header
    sep = "-" * 46
    print(f"\ncrop-tool v{VERSION}")
    print(sep)
    print(f"  Input:    {opts.input_dir}")
    print(f"  Output:   {opts.output_dir}")
    print(f"  Ratio:    {opts.ratio}    Gravity: {opts.gravity}")
    if opts.fmt:       print(f"  Format:   {opts.fmt}")
    if opts.suffix:    print(f"  Suffix:   {opts.suffix}")
    if opts.pattern:   print(f"  Pattern:  {opts.pattern}")
    if opts.min_mp:    print(f"  Min MP:   {opts.min_mp}")
    if opts.max_mp:    print(f"  Max MP:   {opts.max_mp}")
    if opts.recursive: print(f"  Recursive: yes")
    if opts.dry_run:   print(f"  ** DRY RUN - nothing will be written **")
    print(sep)
    print()

    engine  = CropEngine(opts, on_log=_cli_log)
    summary = engine.run()

    # Summary
    print()
    print(sep)
    print(f"  Found:     {summary.found}")
    print(f"  Processed: {summary.processed}")
    print(f"  Skipped:   {summary.skipped}")
    print(f"  Failed:    {summary.failed}")
    if not opts.dry_run and summary.bytes_saved != 0:
        sign = "-" if summary.bytes_saved >= 0 else "+"
        print(f"  Size diff: {sign}{human_bytes(summary.bytes_saved)}")
    if opts.dry_run:
        print("  (dry run - no files written)")
    print(sep)
    print()

    if opts.log_file and summary.results:
        try:
            write_log(opts.log_file, summary.results)
            _cli_log("ok", f"Log written -> {opts.log_file}")
        except Exception as e:
            _cli_log("err", f"Could not write log: {e}")


# needed for sips call on older Python
import os

if __name__ == "__main__":
    main()
