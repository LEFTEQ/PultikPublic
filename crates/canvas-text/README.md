# canvas-text

One shaping/cache/atlas owner for `canvas-gpu`.

- macOS uses Core Text; its backend and font metrics are unchanged.
- Other native targets retain the existing fixed-advance, inkless fallback.
- `wasm32-unknown-unknown` uses browser Canvas2D to measure and rasterize text
  into the existing alpha atlas. No font assets or second GPU stack are bundled.
  Construct `TextSystem` on the browser main thread, after required web fonts
  have loaded. Browser font selection and rasterization are platform-dependent.

Browser UI labels are shaped as whole runs, preserving contextual shaping and
ligatures. Runs must fit a 1022-pixel atlas interior; use `max_width`/truncation
for long labels. Cell/code runs are split at grapheme boundaries so each cluster
can be pinned and tinted by the existing cell renderer. Cross-cell ligatures and
contextual shaping are not supported there. Emoji are coverage-tinted, not colour.
Prefix-based caret measurements are suitable for LTR labels, not a complete bidi
editor. Do not use this backend as a browser code editor's bidi/IME engine.

The `code_view`, `editor_view`, `diff_view` and `merge_view` adapters are native
only: their `code-core` dependency includes native tree-sitter C grammars.
Browser hosts may still submit pre-laid-out `Op::Code` rows through the same
renderer. Labels, cells, sprites, images and atlas APIs remain available on Wasm.
There are no crate features; platform selection uses target cfgs.

See `../canvas-gpu/README.md` for the browser build and pixel qualification.
