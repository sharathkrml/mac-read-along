# Read Along

A macOS app that follows a person reading aloud from any window on screen: it listens to their speech and keeps a highlight on the three-word group they are reading, with a preview of the next one and a dotted rule under the exact word, so losing focus never means losing their place.

## Language

**Read-along session**:
A period in which the app listens to the reader's speech and tracks their position on a reading surface, started and ended by the reader.
_Avoid_: reading mode, listening mode

**Reading surface**:
A window whose text is being tracked — an app window such as a browser, an editor, or a PDF open in Preview.
_Avoid_: source, target, document

**Reading cursor**:
The app's current belief about which sentence the reader is on.
_Avoid_: position, location, pointer

**Sentence**:
The unit of tracking: one sentence of the reading surface's text. The overlay paints parts of it, never moves the sentence cursor on a single word.
_Avoid_: line (screen lines wrap arbitrarily and depend on window width), stanza

**Current sentence**:
The sentence under the reading cursor; its current breath group gets the strongest highlight.
_Avoid_: active line, current line

**Breath group**:
Up to three consecutive words of the current sentence starting at the word under the voice; the overlay's strongest highlight.
_Avoid_: chunk, phrase highlight

**Word marker**:
The dotted rule and deeper wash under the exact word the reader is speaking. Display only: a single word may move it, never the sentence cursor.
_Avoid_: cursor, karaoke highlight

**Next group cue**:
The breath group after the current one, pre-highlighted in a weaker style; at a sentence end it is the next sentence's first group.
_Avoid_: upcoming highlight, next-sentence cue, queued line

**Relocation**:
The reading cursor jumping to a sentence other than the next one because the reader's speech matched it — a forward skip or a re-read.
_Avoid_: scroll jump, correction

**Highlight overlay**:
The translucent highlight the app draws over a reading surface's sentences.
_Avoid_: mask, marker

**Speech engine**:
The local component that turns the reader's speech into text; swappable for another model or provider.
_Avoid_: transcriber, ASR, model
