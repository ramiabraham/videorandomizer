# VideoRandomizer

Native macOS app (Swift, AppKit + AVFoundation, no dependencies) that plays every `.mp4`
under a folder and its subfolders in random order as one continuous, gapless stream.

    ./build.sh                 # builds VideoRandomizer.app (universal, ad-hoc signed)
    open VideoRandomizer.app

The folder defaults to `../scene-detect/scenes`; change it in **Settings… (⌘,)**.
Controls: Play/Pause (Space), Stop (⌘.), Restart with a new shuffle (⌘R), Next clip (⌘→),
full screen (⌃⌘F).

On another Mac the app is not notarized: right-click → Open the first time, or allow it in
System Settings → Privacy & Security.

## How it works

- `Sources/Library.swift` — indexes file names only (~5 MB for 77k clips, 0.3 s scan) and
  hands out a lazy shuffle in which every clip plays once before any repeats.
- `Sources/PlayerController.swift` — demuxes each clip with `AVAssetReader`, re-stamps its
  samples onto one running timeline and feeds an `AVSampleBufferDisplayLayer` (hardware
  decode) and audio renderer. At most two files are open at once.
- `Sources/main.swift` — window, transport controls, menu, settings.
- `Icon/` — the app icon; `Icon/make-icon.sh` redraws it from `make-icon.swift`.

## Self-test

    VideoRandomizer.app/Contents/MacOS/VideoRandomizer --selftest 300
    VideoRandomizer.app/Contents/MacOS/VideoRandomizer --selftest 60 --skip-every 0.2

The first plays normally and reports late frames, seam accuracy, clock drift, CPU and memory;
the second cycles through all transport controls five times a second. `--root DIR` overrides
the folder. Exit status is 0 on PASS.

## Author and license

By ramiabraham. Released under the [MIT License](LICENSE).
