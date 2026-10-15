# CodeCore

The code core for Swift: tree-sitter highlighting and tags, the symbol index, code search's
in-process half and the diff model. None of it is implemented here. The Rust crate
`crates/code-core` computes everything, behind the C ABI of `crates/code-core-ffi`. This
package wraps that ABI in Swift values and owns every allocation it hands back.

- `CCodeCore` is a module map over `crates/code-core-ffi/include/code_core.h`. cbindgen
  generates the header (`cargo xtask code-core-header`); never edit it by hand.
  `--check` fails when it drifts from the crate.
- `CodeCore` holds the Swift wrappers. Every C call goes through `Core.call`: it checks the
  status and frees the error message. Every result is freed with its `*_free` before the
  wrapper returns.

The package links nothing. Its host links `libcode_core_ffi.a`: Pultík's `Project.swift`
builds it with a cargo phase (`dev` for Debug, `ffi-release` for Release; one slice per arch,
joined by `lipo`) and passes it in `OTHER_LDFLAGS`. `tools/test-foundation.sh` builds and links it
for the Foundation harness.

## Contract

- **Text in** is UTF-8 (`String.withCore`); **positions out** are UTF-16 code units, the
  unit `NSString` and `NSRange` count. The core counts bytes and converts once, in the ABI.
- **Columns** follow the core's width rule: a tab runs to the next stop of 4, East Asian
  wide chars and emoji take two, combining marks none.
- **Failures:** a core refusal or a caught Rust panic throws `CodeCoreError`. Lookups that
  cannot fail (a path's language, a column count, the word at a column) log a failure and
  answer a neutral value instead.
- **Threads:** `SyntaxEngine`, `CodeText`, `DiffLine.parse`, `DiffRows`, `DiffLayout` and
  `LineMatcher` are safe from any thread. `SymbolIndexes`, `SymbolIndexBuilder` and
  `GrepRecords` wrap one handle each: one owner (an actor, or a lock) uses it at a time.

## API

```swift
import CodeCore

SyntaxLanguage(path: "web/App.tsx")                        // .tsx; nil is plain text
try SyntaxEngine.highlight(text, language: .rust)          // LineTokens: runs(line:) in UTF-16
try SyntaxEngine.tags(text, language: .go)                 // definitions and references

let indexes = SymbolIndexes()                              // the last two repo@heads, LRU
let builder = try SymbolIndexBuilder()
try builder.add(batch)                                     // returns the files that failed
indexes.install(builder, repo: "o/r", head: sha)
indexes.definitions(of: "render", repo: "o/r", head: sha, from: path, imports: imports)

CodeText.wordAt(line, column: 12)                          // the identifier under a column
CodeText.expandTabs(line)                                  // (text, UTF-16 offset map)
let grep = try GrepRecords(head: sha, limit: 2000, query: q, toggles: SearchToggles())

DiffLine.parse(patch)                                      // drawn lines with gutter numbers
let rows = DiffRows(files, truncated: false, toggled: [])  // a change set as rows
DiffLayout(rows.shape, width: 900, wraps: true, metrics: .init())
try TextDiff(old: before, new: after)                      // hunks, word diffs, split rows
```

Pultík names these types in its own code through typealiases (`Sources/Code/`). The record
is `docs/specs/2026-10-15-workbench-wp3b-pultik-on-code-core.md`.
