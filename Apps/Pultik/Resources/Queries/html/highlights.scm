; Vendored by `cargo xtask vendor-queries` from the pinned grammar crates — never hand-edit.
; tree-sitter-html v0.23.2: queries/highlights.scm

; ---- tree-sitter-html/queries/highlights.scm ----
(tag_name) @tag
(erroneous_end_tag_name) @tag.error
(doctype) @constant
(attribute_name) @attribute
(attribute_value) @string
(comment) @comment

[
  "<"
  ">"
  "</"
  "/>"
] @punctuation.bracket
