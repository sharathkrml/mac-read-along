# Read Along

A macOS app that follows a person reading aloud from any window on screen: it listens to their speech and keeps a highlight on the sentence they are reading, with a preview of the next one, so losing focus never means losing their place.

## Language

**Read-along session**:
A period in which the app listens to the reader's speech and tracks their position on a reading surface, started and ended by the reader.
_Avoid_: reading mode, listening mode

**Reading surface**:
A window whose text is being tracked — an app window such as a browser or editor, or the app's own reader window.
_Avoid_: source, target, document

**Reader window**:
The app's own window for displaying a local text, Markdown, or PDF file for reading.
_Avoid_: viewer, library

**Reading cursor**:
The app's current belief about which sentence the reader is on.
_Avoid_: position, location, pointer

**Sentence**:
The unit of tracking: one sentence of the reading surface's text, highlighted as a whole.
_Avoid_: line (screen lines wrap arbitrarily and depend on window width)

**Current sentence**:
The sentence under the reading cursor; the strongest highlight.
_Avoid_: active line, current line

**Next-sentence cue**:
The sentence after the current sentence, pre-highlighted in a weaker style to anchor the reader's eyes.
_Avoid_: upcoming highlight, queued line

**Relocation**:
The reading cursor jumping to a sentence other than the next one because the reader's speech matched it — a forward skip or a re-read.
_Avoid_: scroll jump, correction

**Highlight overlay**:
The translucent highlight the app draws over a reading surface's sentences.
_Avoid_: mask, marker

**Speech engine**:
The local component that turns the reader's speech into text; swappable for another model or provider.
_Avoid_: transcriber, ASR, model
