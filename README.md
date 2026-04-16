# cropia

**Precision batch image cropper for photographers and visual creatives.**

Most image editors crop by eye - you drag a handle and hope the result looks right. cropia is different. It enforces an exact mathematical aspect ratio across an entire folder of images, guaranteed to the pixel, every time. Whether you are preparing a portfolio for print, exporting for a web gallery with strict dimension requirements, or delivering client work to a spec, every output file will have the exact same ratio with no rounding errors and no silent misalignments.

For JPEG files, cropia goes further - it uses jpegtran to perform a fully lossless crop. This means the image data is never decompressed and recompressed. Your pixel quality is 100% identical to the original file. Not visually identical - mathematically identical. For PNG, WEBP, and TIFF, Pillow handles the crop natively within each format's own lossless pipeline.

---

## What makes this different from a regular crop

A standard crop tool lets you drag a box. cropia calculates. You give it a ratio and it finds the largest possible crop at that exact ratio that fits within each image, then positions it according to your chosen anchor point (gravity). Every image in the batch gets the same treatment, the same ratio, the same anchor logic.

For JPEG, the MCU block system means the crop also has to align to 16-pixel boundaries to stay lossless. cropia handles this automatically - you never have to think about it.

---

## Files

| File | Description |
|---|---|
| `cropia.sh` | Standalone bash script, no Python required |
| `cropia.py` | Python CLI + core engine |

---

## Installation

**1. Clone or download**
```bash
git clone https://github.com/rajawski/cropia
cd cropia
```

**2. Install Python dependencies**
```bash
pip install -r requirements.txt
```

Or manually:
```bash
pip install Pillow
```

**3. Install jpegtran**

jpegtran is required for lossless JPEG cropping. It is not a Python package - install it via your system package manager.

```bash
# macOS
brew install jpeg

# Ubuntu / Debian
sudo apt install libjpeg-turbo-progs

# Fedora / RHEL
sudo dnf install libjpeg-turbo-utils
```

Verify it is installed:
```bash
which jpegtran
```

**4. Make the bash script executable (optional)**
```bash
chmod +x cropia.sh
```

**5. Verify everything is working**
```bash
python3 cropia.py --help
```

---

## Requirements

**Always required:**
- `jpegtran` - for lossless JPEG cropping
- `Pillow` - for PNG, WEBP, and TIFF cropping

**Install jpegtran:**
```bash
# macOS
brew install jpeg

# Linux
apt install libjpeg-turbo-progs
```

**Install Pillow:**
```bash
pip install Pillow
```

**Dimension reading (one of the following):**
- `sips` - built-in on macOS, nothing to install
- `identify` - part of ImageMagick, only needed on Linux

Python 3.6+ required for `.py` files. No other dependencies.

---

## How lossless JPEG cropping works

JPEG images are stored internally as a grid of 16x16 pixel blocks called MCU blocks. If you crop at an arbitrary pixel offset, the encoder has to break those blocks apart, forcing a full decompress-and-recompress cycle that degrades image quality.

cropia avoids this by:

1. Computing crop dimensions as multiples of the ratio times 16 - for 3:2 this means width = N x 48, height = N x 32
2. Snapping the crop offset to the nearest 16px boundary
3. Passing these aligned values to `jpegtran`, which cuts exactly between blocks without touching pixel data

The result is a cropped JPEG with zero quality loss and typically a smaller file size than the original.

**This MCU constraint only applies to JPEG.** PNG, WEBP, and TIFF have no block structure, so Pillow crops them at exact pixel offsets with no rounding.

---

## Format behavior

| Input | Output | Tool | Lossless | MCU alignment |
|---|---|---|---|---|
| JPG | JPG | jpegtran | Yes - fully lossless | Required |
| PNG | PNG | Pillow | Yes | Not needed |
| WEBP | WEBP | Pillow | Yes (quality=100) | Not needed |
| TIFF | TIFF | Pillow | Yes (LZW compression) | Not needed |
| JPG | PNG/WEBP/TIFF | Pillow | No - re-encodes | Not needed |
| PNG/WEBP/TIFF | JPG | jpegtran | No - re-encodes | Applied |

cropia tells you in verbose mode whenever a re-encode will happen.

---

## Ratio system

Any integer A:B ratio works. The MCU block sizes for JPEG are computed as A x 16 and B x 16. For non-JPEG formats, the ratio is applied as exact pixel math with no block constraints.

| Ratio | Use case |
|---|---|
| `3:2` | Standard photo, 35mm film (default) |
| `16:9` | Widescreen, video, modern displays |
| `4:5` | Portrait, Instagram vertical |
| `1:1` | Square, Instagram grid |
| `5:4` | Large format print |
| `4:3` | Classic print, medium format |

---

## Gravity anchors

```
top-left    top    top-right
left       center      right
bottom-left  bottom  bottom-right
```

Default is `bottom` - ideal for landscapes and portraits where the horizon and subject sit in the lower half of the frame.

---

## cropia.sh

```bash
./cropia.sh [OPTIONS] INPUT_DIR OUTPUT_DIR
```

```
--ratio A:B         Aspect ratio (default: 3:2)
--gravity ANCHOR    Crop anchor position (default: bottom)
--format FORMAT     Output format: jpg, png, webp, tiff
--suffix TEXT       Append before extension, e.g. _web
--overwrite         Replace existing output files
--skip              Skip if output file already exists
--recursive         Walk subdirectories
--pattern GLOB      Filter filenames, e.g. "DSC_*"
--min-mp N          Skip images below N megapixels
--max-mp N          Skip images above N megapixels
--dry-run           Preview without writing files
--preview           Save crop-overlay previews to OUTPUT_DIR/previews/
--verbose           Print per-file detail
--config FILE       Load options from a config file
--log FILE          Export results log (.csv or .json)
--help              Show help
--version           Show version
```

---

## cropia.py (CLI)

```bash
python3 cropia.py [OPTIONS] INPUT_DIR OUTPUT_DIR
```

Options are identical to the bash script. Run `python3 cropia.py --help` for the full list.

---

## Config file format

```ini
[cropia]
ratio     = 3:2
gravity   = bottom
format    = jpg
suffix    = _crop
skip      = true
verbose   = true
```

CLI flags always take precedence over config file values.

---

## Log export

Pass `--log results.csv` or `--log results.json` to save a per-file results log.

**Status values:**

| Status | Meaning |
|---|---|
| `ok` | Cropped successfully |
| `dry-run` | Would have been processed |
| `skipped:exists` | Output existed and --skip was set |
| `skipped:too-small` | Image too small for the ratio |
| `skipped:below-min-mp` | Below --min-mp threshold |
| `skipped:above-max-mp` | Above --max-mp threshold |
| `failed:conflict` | Output exists, no --overwrite or --skip set |
| `failed:no-dimensions` | Could not read image dimensions |
| `failed:crop-error` | Crop operation failed |
| `failed:unreadable` | File could not be read |

---

## Notes

- Input formats: JPG, JPEG, PNG, WEBP, TIFF, TIF
- In recursive mode, the output directory mirrors the input subdirectory structure
- `--overwrite` and `--skip` are mutually exclusive
- If neither is set and an output file already exists, the file is skipped with an error - intentional to prevent silent overwrites
- WEBP output uses quality=100 and method=6 for maximum fidelity
- TIFF output uses LZW compression for lossless storage
