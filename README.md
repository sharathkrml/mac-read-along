# Read Along

A macOS menu-bar app that follows your voice while you read: the current sentence is marked in amber, the next one waits more faintly, so losing focus never loses your place.

## Status

Everything in the v1 spec is built:

- Reader window for local `.txt`, `.md`, and text-based PDF files (status-menu Open, drag-and-drop, or `open -a`).
- Read-along over external windows: pick Safari, Chrome or VS Code, capture + OCR its text, and the same two-stage highlight draws over the real page.
- Local Phonon speech engine (English, Phonon-2) with live streaming, supervised and installed by the app.
- Sentence tracking with the agreed rules: finishing a sentence advances the cursor; a three-word phrase moves it anywhere, forward or back; one or two stray words never move it.
- Auto-scroll on every surface (native in the reader, synthesized events for external windows) with a manual-scroll back-off.
- Three-step onboarding with live permission statuses, a Settings window (model, hotkey, status-card visibility), and a draggable status card for sessions.

Deliberately deferred: appearance customization, word-level karaoke highlighting, and image-only PDFs (they show a clear unsupported state).

## Build and run

Requires macOS 15+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run       # generate, build, and (re)launch the app
```

Other targets: `make build`, `make generate`, `make test`, `make clean`. Or open `ReadAlong.xcodeproj` in Xcode and run.

## Use

1. On first launch the onboarding walks you through permissions (microphone and screen recording required, accessibility recommended for auto-scroll) and the speech engine setup.

2. Press **⌥⌘R** (or your recorded hotkey), then click the window you want to read — or open a document directly: menu-bar icon → **Open Reading…**, drag a `.txt`/`.md`/PDF onto the window, or:

   ```bash
   open -a build/Build/Products/Debug/ReadAlong.app samples/read-along-sample.txt
   ```

3. Read aloud. The current sentence gets the amber wash and underline; the next sentence gets the faint cue. The page scrolls itself as you go; scrolling by hand backs it off for a moment.

## Tests

`make test` runs 55 tests: display-coordinate conversion, window filtering, sentence splitting, PDF page mapping, OCR surface building, frame-change detection, auto-scroll thresholds, the tracking rules (advance, relocation, single-word safety, short sentences, fuzzy tolerance, re-capture survival), and settings persistence.

## Docs

- Spec and tickets: GitHub issues, starting at [#1](https://github.com/sharathkrml/mac-read-along/issues/1)
- Domain vocabulary: [GLOSSARY.md](GLOSSARY.md)
- Decisions: [docs/adr](docs/adr)
