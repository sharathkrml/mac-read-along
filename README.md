# Read Along

A macOS menu-bar app that follows your voice while you read: the current sentence is marked in amber, the next one waits more faintly, so losing focus never loses your place.

## Status

The core read-along loop works:

- Reader window for local `.txt` and `.md` files (status-menu Open, drag-and-drop, or `open -a`).
- Local Phonon speech engine (English, Phonon-2) with live streaming.
- Sentence tracking with the agreed rules: finishing a sentence advances the cursor; a three-word phrase moves it anywhere, forward or back; one or two stray words never move it.
- The app installs its speech runtime into `~/Library/Application Support/ReadAlong` on first Listen and shows the engine's startup/model-download lines on the card. Model weights live in `~/.cache/fermion`.

Not built yet: highlighting over other apps (the in-place overlay for Safari/VS Code), auto-scroll, PDFs, onboarding/permissions UI, and full settings.

## Build and run

Requires macOS 15+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run       # generate, build, and (re)launch the app
```

Other targets: `make build`, `make generate`, `make test`, `make clean`. Or open `ReadAlong.xcodeproj` in Xcode and run.

## Use

1. Open a document: menu-bar icon → **Open Reading…**, drag a `.txt`/`.md` onto the window, or:

   ```bash
   open -a build/Build/Products/Debug/ReadAlong.app samples/read-along-sample.txt
   ```

2. Press **Listen** and allow the microphone, then read aloud. The current sentence gets the amber wash and underline; the next sentence gets the faint cue.

## Tests

`make test` runs 28 tests: display-coordinate conversion, window filtering, sentence splitting, and the tracking rules (advance, relocation, single-word safety, short sentences, fuzzy tolerance).

## Docs

- Spec and tickets: GitHub issues, starting at [#1](https://github.com/sharathkrml/mac-read-along/issues/1)
- Domain vocabulary: [GLOSSARY.md](GLOSSARY.md)
- Decisions: [docs/adr](docs/adr)
