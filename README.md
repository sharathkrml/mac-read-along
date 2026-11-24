# Read Along

A macOS menu-bar app that follows your voice while you read: the three words you are reading now are marked in amber, the next three wait more faintly, and a dotted rule tracks the exact word under your voice, so losing focus never loses your place.

## Status

Everything in the v1 spec is built:

- Read-along over any window with text — a browser, an editor, or a PDF open in Preview. The app attaches to the window, follows your voice, and draws the highlights in place over it.
- Local Phonon speech engine (English, Phonon-2) with live streaming, installed and supervised by the app.
- Sentence tracking with the agreed rules: finishing a sentence advances the cursor; a three-word phrase moves it anywhere, forward or back; one or two stray words never move it.
- Within the tracked sentence, the overlay follows the voice word by word: a three-word breath group in amber, the next group faintly, and a dotted rule under the exact word. Word geometry comes from Vision and falls back to the sentence rectangles when unavailable.
- Auto-scroll on every surface with a manual-scroll back-off.
- The Setup window on every app open: live permission statuses, an engine that loads itself, and a live microphone test (waveform plus transcription). Start reading leads straight into picking a window; cancel brings it back.
- Highlights adapt to the captured window's brightness, so light PDFs stay readable and dark apps still get a visible cue.
- A single Setup window — permissions, a live voice test, and every setting (model, microphone, hotkey, status-card visibility) editable in place — plus a draggable status card with a live waveform, a microphone picker, and the last words heard.

Deliberately deferred: appearance customization, custom breath-group size, and image-only PDFs (they show a clear unsupported state).

## Build and run

Requires macOS 15+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run       # generate, build, and (re)launch the app
```

Other targets: `make build`, `make generate`, `make test`, `make clean`. Or open `ReadAlong.xcodeproj` in Xcode and run.

## Use

1. Open Read Along. The setup window shows permissions, warms the local engine, and lets you say a few words to watch the live waveform and transcription. The microphone test stops when you leave the screen.

2. Click **Start reading** (or press **⌥⌘R**), then click the browser, editor, or Preview window you want to follow. The column you click is the one that gets tracked — sidebars, terminals, and other panels stay out of the way. Preview is just another window: open your PDF there, start reading, and the app tracks it in place.

3. Read aloud. The three words under your voice get the amber wash and solid rule; the next three get the faint cue, and a dotted rule plus a deeper wash mark the exact word being spoken. The page scrolls itself as you go; scrolling by hand backs it off for a moment.

## Tests

`make test` runs 87 tests: display-coordinate conversion, window filtering, sentence splitting, word tokenization, OCR surface building (including multi-column windows, word boxes, and the clicked-column rule), surface-tone classification, frame-change detection (including the OCR skip on still frames), auto-scroll thresholds, the tracking rules (advance, relocation, single-word safety, short sentences, fuzzy tolerance, re-capture survival), word-marker alignment, breath-group windows and band merging, highlight placement on a secondary screen, audio-level scaling, the cache-capped speech-engine launch and memory watchdog, and settings persistence.

## Docs

- Spec and tickets: GitHub issues, starting at [#1](https://github.com/sharathkrml/mac-read-along/issues/1)
- Domain vocabulary: [GLOSSARY.md](GLOSSARY.md)
- Decisions: [docs/adr](docs/adr)
