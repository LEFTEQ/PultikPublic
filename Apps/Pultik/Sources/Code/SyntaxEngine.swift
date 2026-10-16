import CodeCore

/// One tree-sitter parse per text (PR workbench D2, WP2), now the code core's
/// (`crates/code-core`, workbench WP3b): `highlight` paints each line's runs through the
/// vendored queries, for one node the most specific pattern then the later one
/// (`specificity`); `tags` names the definitions and references the symbol index reads.
/// Thread-safe; callers run it off the main thread (`HighlightCache`).
typealias SyntaxEngine = CodeCore.SyntaxEngine
