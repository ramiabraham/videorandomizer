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

## Installation
- Download the latest stable release on the (Releases page](https://github.com/ramiabraham/videorandomizer/releases/tag/v1.0.0).
- Install
- Right-click and click Open to allow the app to open. Currently, the install package has no Apple Developer ID signature, so double-clicking it shows a Gatekeeper warning. Right-click → Open, or allow the app to run in System Settings → Privacy & Security.

- ## Usage
- Specify a root directory for your video files in Settings.
- VideoRandomizer will auto-play all video files in this directory, including sub-directories. Playback will continue until you quit the app or press pause or stop in the app's playback controls (or via the top menu).
- Play, pause, or stop playback with the hover controls in the video player.
  - Playback controls are also present in the top menu.
- Fullscreen option, if needed.

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
