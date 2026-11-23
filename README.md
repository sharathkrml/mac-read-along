# Read Along

A macOS menu-bar app that follows your voice while you read: the current sentence is marked in amber, the next one waits more faintly, so losing focus never loses your place.

## Status

Everything in the v1 spec is built:

- Read-along over any window with text — a browser, an editor, or a PDF open in Preview. The app attaches to the window, follows your voice, and draws the highlights in place over it.
- Local Phonon speech engine (English, Phonon-2) with live streaming, installed and supervised by the app.
- Sentence tracking with the agreed rules: finishing a sentence advances the cursor; a three-word phrase moves it anywhere, forward or back; one or two stray words never move it.
- Auto-scroll on every surface with a manual-scroll back-off.
- A launcher on every app open: live permission statuses, an engine that loads itself, and a live microphone test (waveform plus transcription). Start reading leads straight into picking a window; cancel brings the launcher back.
- Highlights adapt to the captured window's brightness, so light PDFs stay readable and dark apps still get a visible cue.
- A Settings window (model, microphone, hotkey, status-card visibility) and a draggable status card with a live waveform, a microphone picker, and the last words heard.

Deliberately deferred: appearance customization, word-level karaoke highlighting, and image-only PDFs (they show a clear unsupported state).

## Build and run

Requires macOS 15+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run       # generate, build, and (re)launch the app
```

Other targets: `make build`, `make generate`, `make test`, `make clean`. Or open `ReadAlong.xcodeproj` in Xcode and run.

## Use

1. Open Read Along. The launcher shows permissions, warms the local engine, and lets you say a few words to watch the live waveform and transcription. The microphone test stops when you leave the screen.

2. Click **Start reading** (or press **⌥⌘R**), then click the browser, editor, or Preview window you want to follow. Preview is just another window: open your PDF there, start reading, and the app tracks it in place.

3. Read aloud. The current sentence gets the amber wash and underline; the next sentence gets the faint cue. The page scrolls itself as you go; scrolling by hand backs it off for a moment.

## Tests

`make test` runs 62 tests: display-coordinate conversion, window filtering, sentence splitting, OCR surface building (including multi-column windows), surface-tone classification, frame-change detection (including the OCR skip on still frames), auto-scroll thresholds, the tracking rules (advance, relocation, single-word safety, short sentences, fuzzy tolerance, re-capture survival), audio-level scaling, and settings persistence.

## Docs

- Spec and tickets: GitHub issues, starting at [#1](https://github.com/sharathkrml/mac-read-along/issues/1)
- Domain vocabulary: [GLOSSARY.md](GLOSSARY.md)
- Decisions: [docs/adr](docs/adr)
