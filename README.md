# FreeScan

An open-source, native macOS app for scanning **35mm color-negative and black-&-white-negative
film** on the **Epson Perfection V500 Photo** scanner, using its built-in transparency unit
(TPU). It aims to reproduce the core film-scanning workflow of commercial suites (e.g.
SilverFast SE): prescan → mark frame(s) → adjust → scan → positive image out.

macOS only, Apple Silicon, MIT-licensed. Built against Apple's **ImageCaptureCore** framework.

> **Status:** work in progress. The scanner-control layer and Step 0 diagnostic are implemented;
> the full color/curve/export pipeline is under active development. See the build brief and the
> plan in `.claude/plans/` for scope.

---

## What it does

- **Prescan** the full TPU area at low resolution and display it.
- **Mark frames** by dragging one or more crop rectangles over the prescan (a 35mm strip holds
  several frames).
- **Convert negatives to positives** — color negatives get orange-mask removal + per-channel
  normalization + auto-balance; B&W negatives get inversion + contrast/gamma.
- **Gradation / tone curve** — interactive multi-point curve (Catmull-Rom spline → 16-bit LUT)
  with a live histogram, applied before the final scan.
- **Export** JPEG / PNG / TIFF at 8- or 16-bit per channel (48-bit color, 16-bit grayscale).
- **Batch** (stretch) — scan each marked frame in sequence to its own file.

## Prerequisites

1. **macOS 14 (Sonoma) or later**, with Xcode 16+ (command-line tools suffice for the CLI).
2. **Epson's official ICA Scanner Driver for the V500 Photo**, so macOS's Image Capture stack
   recognizes the device. Download from
   https://epson.com/Support/Scanners/Perfection-Series/Epson-Perfection-V500-Photo/s/SPT_B11B189011
   — note that the newer "Epson Scan 2" utility does **not** support this model; only the ICA
   driver + the Image Capture path do.
3. **XcodeGen** to generate the Xcode project (see below).

## Build

There are **two** build systems:

### SwiftPM (no Xcode required — Command Line Tools suffice)

The shared core, the diagnostic CLI, the SwiftUI views, and the self-checks all build and run
with plain `swift`:

```bash
swift build            # builds FreeScanCore, FreeScanUI, FreeScanDiag, FreeScanApp, FreeScanVerify
swift run FreeScanApp      # LAUNCH THE APP — no Xcode needed
swift run FreeScanDiag     # the Step 0 diagnostic
swift run FreeScanVerify  # 27 self-checks of the core math + 16-bit export round-trips
swift test             # runs the XCTest suite (NOTE: needs full Xcode for the XCTest module)
```

`swift run FreeScanApp` runs the GUI unsandboxed, so the USB scanner is reachable without any
entitlements. It launches as a plain process (no dock icon / signed bundle) — fine for use and
development.

### XcodeGen → Xcode (for the runnable macOS `.app`)

The `.xcodeproj` is **generated, not checked in** (standard XcodeGen workflow) and produces the
signed, sandboxed app bundle:

```bash
brew install xcodegen        # one-time
xcodegen generate            # produces FreeScan.xcodeproj from project.yml
open FreeScan.xcodeproj      # build & run the app in Xcode
```

Full Xcode is required for this path (the sandboxed app + entitlements + code signing). From the
command line:

```bash
xcodebuild -project FreeScan.xcodeproj -scheme FreeScan -configuration Debug build
```

## Step 0 — validate against the real scanner

`FreeScanDiag` discovers the V500 over USB, prints every functional unit (flatbed / positive- /
negative-transparency) with its supported resolutions, bit depths, and document types, and runs
one overview scan to disk. The app's resolution/bit-depth options are populated from this output.

```bash
swift run FreeScanDiag
```

If the negative-transparency unit is **not** listed, that's the signal to fall back to a SANE
path — see the build brief.

## Architecture

```
Sources/
  FreeScanCore/   Scanner control (ImageCaptureCore), color/curve/histogram, export. No UI.
  FreeScanUI/     SwiftUI: prescan view, crop overlay, histogram, curve editor, settings.
  FreeScanApp/    The @main app entry + Info.plist + entitlements (built via XcodeGen).
  FreeScanDiag/   The Step 0 command-line diagnostic.
  FreeScanVerify/ CLT-runnable self-checks (mirror of the XCTest suite; needs no Xcode).
Tests/
  FreeScanCoreTests/  XCTest unit tests (needs full Xcode for the XCTest module).
Package.swift    Primary build: FreeScanCore / FreeScanUI / FreeScanDiag / FreeScanVerify + tests.
project.yml      XcodeGen spec → FreeScan.xcodeproj (the runnable, signed .app).
```

The pure-logic pipeline (negative inversion, tone-curve LUT, histogram, 16-bit export) lives in
`FreeScanCore` and is unit-testable without hardware. The scanner layer talks to
ImageCaptureCore; selecting `ICScannerFunctionalUnitNegativeTransparency` *is* "scan via the TPU
in negative mode." All device delegate callbacks are documented (ICDevice.h) to run on the main
thread, so the `@MainActor` controller handles them via `@preconcurrency` conformances.

## License

MIT — see [LICENSE](LICENSE).
