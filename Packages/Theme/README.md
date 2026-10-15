# Theme

Code themes for every code surface, defined once in
`Sources/CodeThemes/Resources/themes.json`. This Swift package reads that file
as a bundled resource; the Rust crate `crates/theme` compiles the same file in
with `include_str!`. There is no second copy to keep in step.

The library is `CodeThemes`, not `Theme`: an app's own `Theme` (its design
tokens) keeps that name.

## Themes

`adeberry-amber` (the house theme), `codex-dark`, `one-dark` (Atom One Dark),
`github-dark` (GitHub Dark Default), `one-light` and `tokyo-night`. Each records
its source and licence in its `provenance`; `NOTICE.md` carries the MIT notices.

`codex-dark` ships in private builds only. The public mirror publishes this file
without it (`mirror/overrides/code-themes.json`, held equal minus that theme by
`crates/theme`'s tests), so an owner passes a fallback after it in `defaultIDs`.

A theme is:

- a **palette**: one colour per `PaletteRole` (background, foreground, gutter,
  line numbers, current line, selection, cursor, added and removed line and
  word tints, added and removed gutters and marks, hunk and header bands, find
  match, border);
- a **syntax map**: a colour, bold and italic per `SyntaxRole` (keyword,
  string, escape, function, type, …). An app maps its highlighter's kinds onto
  these roles.

Decoding fails on a missing role, an unknown role or a colour that is not
`#RRGGBB` / `#RRGGBBAA`. The Rust reader is just as strict, so the file, the
Swift enums and the Rust enums cannot drift apart.

## API

```swift
import CodeThemes

ThemeCatalog.shipped.themes                  // every theme, in file order
ThemeCatalog.shipped.theme(id: "one-dark")   // lookup by id
let store = CodeThemeStore(selectedID: saved, defaultIDs: ["codex-dark", "one-dark"])
store.theme[.background].nsColor             // palette role → NSColor / Color
store.theme[.keyword]                        // SyntaxStyle: color, bold, italic
store.observe(view) { theme in view.repaint(theme) }  // AppKit surfaces
store.select("one-light")                    // switches and notifies; SwiftUI follows via Observation
```

The store never persists; its owner saves the selected id.

## Adding a theme

Add an object to `themes.json` with every palette and syntax role, its
`provenance` (source, version, licence) and, for a third-party theme, its
licence notice in `NOTICE.md`. Use only values published under a permissive
licence. Add it to `mirror/overrides/code-themes.json` too, then run
`swift test --package-path Packages/Theme` and `cargo test -p theme`; both list
the shipped ids.
