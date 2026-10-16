; Vendored by `cargo xtask vendor-queries` from the pinned grammar crates — never hand-edit.
; tree-sitter-json v0.24.8: queries/highlights.scm

; ---- tree-sitter-json/queries/highlights.scm ----
(pair
  key: (_) @string.special.key)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @escape

(comment) @comment
