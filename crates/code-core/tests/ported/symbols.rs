//! `SymbolIndexTests.swift` (PR workbench AC 12, D2): TS and Go fixtures resolve definitions
//! and references from the tags queries, and an ambiguous name ranks same file → imported
//! file → same directory → the rest.

use code_core::Language;
use code_core::symbols::{self, Symbol, SymbolIndexes};
use code_core::syntax::TagRole;

fn files(list: &[(&str, &str)]) -> Vec<(String, String)> {
    list.iter()
        .map(|(p, t)| ((*p).to_owned(), (*t).to_owned()))
        .collect()
}

fn typescript() -> Vec<(String, String)> {
    files(&[
        (
            "src/app/main.ts",
            "import { helper } from '../lib/util';\n\nexport function render() {\n  return helper();\n}\n\nrender();",
        ),
        (
            "src/lib/util.ts",
            "export function helper() {\n  return 1;\n}\n\nexport function render() {}\n",
        ),
        ("src/app/sibling.ts", "export function render() {}\n"),
        (
            "far/other.ts",
            "export function render() {}\nexport class Widget {}\nconst w = new Widget();\n",
        ),
        ("README.md", "# render\n"),
    ])
}

fn go() -> Vec<(String, String)> {
    files(&[
        (
            "cmd/app/main.go",
            "package main\n\nimport (\n\t\"fmt\"\n\t\"example.com/proj/internal/store\"\n)\n\nfunc Open() {}\n\nfunc main() {\n\tfmt.Println(store.Open())\n\tOpen()\n}",
        ),
        (
            "internal/store/store.go",
            "package store\n\nfunc Open() string { return \"\" }\n\ntype Store struct{}\n",
        ),
        (
            "cmd/app/util.go",
            "package main\n\ntype S struct{}\n\nfunc (s *S) Open() {}\n",
        ),
        ("other/x.go", "package other\n\nfunc Open() {}\n"),
    ])
}

fn spots(symbols: &[Symbol]) -> Vec<String> {
    symbols
        .iter()
        .map(|s| format!("{}:{}:{}", s.path, s.line, s.column))
        .collect()
}

#[test]
fn typescript_definitions_rank_same_file_imports_directory_then_the_rest() {
    let mut index = SymbolIndexes::default();
    let ts = typescript();
    assert!(index.build("o/ts", "h", &ts).is_empty());
    let imports = symbols::imports(&ts[0].1, Language::TypeScript, "src/app/main.ts");
    assert!(imports.contains(&"src/lib/util.ts".to_owned()));

    let render = index.definitions("o/ts", "h", "render", "src/app/main.ts", &imports);
    assert_eq!(
        render.iter().map(|s| s.path.as_str()).collect::<Vec<_>>(),
        [
            "src/app/main.ts",
            "src/lib/util.ts",
            "src/app/sibling.ts",
            "far/other.ts"
        ]
    );
    assert_eq!(
        render[0],
        Symbol {
            role: TagRole::Definition,
            kind: "function".into(),
            name: "render".into(),
            path: "src/app/main.ts".into(),
            line: 2,
            column: 16,
        }
    );
    let helper = index.references("o/ts", "h", "helper");
    assert_eq!(spots(&helper), ["src/app/main.ts:3:9"]);
    let calls = index.references("o/ts", "h", "render");
    assert_eq!(spots(&calls), ["src/app/main.ts:6:0"]);
    let widget = index.definitions("o/ts", "h", "Widget", "src/app/main.ts", &[]);
    assert_eq!(
        widget.iter().map(|s| s.kind.as_str()).collect::<Vec<_>>(),
        ["class"]
    );
    let uses = index.references("o/ts", "h", "Widget");
    assert_eq!(
        uses.iter()
            .map(|s| format!("{}:{}", s.path, s.line))
            .collect::<Vec<_>>(),
        ["far/other.ts:2"],
        "one spot, though two patterns tag it"
    );
}

#[test]
fn go_definitions_rank_the_package_imported_over_the_directory() {
    let mut index = SymbolIndexes::default();
    let go = go();
    assert!(index.build("o/go", "h", &go).is_empty());
    let imports = symbols::imports(&go[0].1, Language::Go, "cmd/app/main.go");
    assert_eq!(imports, ["fmt", "internal/store"]);

    let open = index.definitions("o/go", "h", "Open", "cmd/app/main.go", &imports);
    assert_eq!(
        open.iter().map(|s| s.path.as_str()).collect::<Vec<_>>(),
        [
            "cmd/app/main.go",
            "internal/store/store.go",
            "cmd/app/util.go",
            "other/x.go"
        ]
    );
    assert_eq!(
        open.iter().map(|s| s.kind.as_str()).collect::<Vec<_>>(),
        ["function", "function", "method", "function"]
    );
    let calls = index.references("o/go", "h", "Open");
    assert_eq!(
        spots(&calls),
        ["cmd/app/main.go:10:19", "cmd/app/main.go:11:1"]
    );
    let store = index.definitions("o/go", "h", "Store", "cmd/app/main.go", &imports);
    assert_eq!(
        store.iter().map(|s| s.kind.as_str()).collect::<Vec<_>>(),
        ["type"]
    );
    assert_eq!(
        index.references("o/go", "h", "Store"),
        [],
        "a type's own name is its definition, not a use"
    );
}

#[test]
fn imports_resolve_relative_modules_only() {
    let source = "import a from './a.js';\nimport type { B } from \"../b\";\nconst c = require('./c');\nimport x from 'react';\nimport y from '@app/alias';";
    let imports = symbols::imports(source, Language::Tsx, "web/src/view.tsx");
    let has = |p: &str| imports.iter().any(|i| i == p);
    assert!(has("web/src/a.ts"), "ESM `.js` names a `.ts` file");
    assert!(has("web/b/index.tsx"));
    assert!(has("web/src/c.js"));
    assert!(
        !imports
            .iter()
            .any(|i| i.contains("react") || i.contains("alias"))
    );
    assert!(symbols::imported(
        "backend/internal/store/db.go",
        &["internal/store".into()]
    ));
    assert!(!symbols::imported(
        "pkg/store/db.go",
        &["internal/store".into()]
    ));
}

#[test]
fn indexes_stay_bounded_least_recently_used_first() {
    let mut index = SymbolIndexes::default();
    let files = files(&[("a.ts", "export function a() {}\n")]);
    index.build("o/r", "1", &files);
    index.build("o/r", "2", &files);
    let _ = index.definitions("o/r", "1", "a", "a.ts", &[]);
    index.build("o/r", "3", &files);
    assert_eq!(
        ["1", "2", "3"].map(|h| index.is_built("o/r", h)),
        [true, false, true]
    );
    index.purge();
    assert!(!index.is_built("o/r", "1"));
}

/// The Rust core's own: Rust's `mod` and `crate::` imports, PHP's `use` classes.
#[test]
fn rust_and_php_imports_name_their_files() {
    let rust = "mod lines;\npub(crate) mod layout;\nuse crate::syntax::Span;\n";
    assert_eq!(
        symbols::imports(rust, Language::Rust, "src/lib.rs"),
        [
            "src/lines.rs",
            "src/lines/mod.rs",
            "src/layout.rs",
            "src/layout/mod.rs",
            "syntax.rs",
            "syntax/mod.rs",
            "syntax/Span.rs",
            "syntax/Span/mod.rs"
        ]
    );
    let php = "<?php\nuse App\\Models\\User;\nuse Lib\\Thing as Other;\n";
    assert_eq!(
        symbols::imports(php, Language::Php, "app/x.php"),
        [
            "App/Models/User.php",
            "Models/User.php",
            "Lib/Thing.php",
            "Thing.php"
        ]
    );
}
