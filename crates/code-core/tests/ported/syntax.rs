//! `SyntaxEngineTests.swift` (PR workbench AC 5): a fixture per language parses through its
//! vendored queries, and keyword / string / function captures land as their roles. Then the
//! Rust core's incremental highlighter against one-shot highlighting.

use code_core::syntax::{self, Language, LineTokens, Span, Syntax};
use code_core::{Buffer, Layout, Viewport};
use theme::SyntaxRole::{self, *};

/// A language, its source, and the role expected under the first occurrence of each needle.
type Fixture = (Language, &'static str, Vec<(&'static str, SyntaxRole)>);

fn fixtures() -> Vec<Fixture> {
    vec![
        (
            Language::Go,
            "package main\n\nimport \"fmt\"\n\nfunc greet(name string) string {\n\treturn \"hi \" + name\n}\n",
            vec![("func", Keyword), ("\"fmt\"", String), ("greet", Function)],
        ),
        (
            Language::TypeScript,
            "import { x } from \"./x\";\nexport function create(name: string): number {\n  return name.length;\n}\n",
            vec![
                ("export", Keyword),
                ("\"./x\"", String),
                ("create", Function),
            ],
        ),
        (
            Language::Tsx,
            "const Card = () => <div className=\"card\">{greet()}</div>;\n",
            vec![
                ("const", Keyword),
                ("\"card\"", String),
                ("greet", Function),
                ("div", Tag),
            ],
        ),
        (
            Language::JavaScript,
            "function render() {\n  return \"x\";\n}\n",
            vec![
                ("function", Keyword),
                ("\"x\"", String),
                ("render", Function),
            ],
        ),
        (
            Language::Html,
            "<div class=\"wide\">hi</div>\n",
            vec![("div", Tag), ("class", Attribute), ("wide", String)],
        ),
        (
            Language::Json,
            "{\"name\": \"pultik\", \"count\": 3}\n",
            vec![
                ("\"name\"", Property),
                ("\"pultik\"", String),
                ("3", Number),
            ],
        ),
        (
            Language::Yaml,
            "name: pultik\ncount: 3\n",
            vec![("name", Property), ("3", Number)],
        ),
        (
            Language::Markdown,
            "# Title\n\nSome *emphasis* and `code`.\n",
            vec![
                ("Title", Heading),
                ("emphasis", Emphasis),
                ("code", Literal),
            ],
        ),
        (
            Language::Rust,
            "fn main() {\n    let s = \"x\";\n    greet(s);\n}\n",
            vec![("fn", Keyword), ("\"x\"", String), ("main", Function)],
        ),
        (
            Language::Bash,
            "#!/bin/bash\nfunction greet() {\n  echo \"hi\"\n}\n",
            vec![
                ("function", Keyword),
                ("\"hi\"", String),
                ("greet", Function),
            ],
        ),
        (
            Language::Php,
            "<?php\nfunction greet($name) {\n    return \"hi\";\n}\n",
            vec![
                ("function", Keyword),
                ("\"hi\"", String),
                ("greet", Function),
            ],
        ),
    ]
}

/// The role under the first occurrence of `needle`; `None` is plain.
fn role_of(needle: &str, source: &str, tokens: &LineTokens) -> Option<SyntaxRole> {
    let at = source.find(needle).expect("the needle is in the source");
    let line = source[..at].matches('\n').count();
    let column = at - source[..at].rfind('\n').map_or(0, |n| n + 1);
    tokens
        .runs(line)
        .iter()
        .find(|r| r.start as usize <= column && column < (r.start + r.len) as usize)
        .map(|r| r.role)
}

#[test]
fn every_language_highlights_its_fixture() {
    for (language, source, expected) in fixtures() {
        let tokens = syntax::highlight(source, language).expect("highlights");
        for (needle, role) in expected {
            assert_eq!(
                role_of(needle, source, &tokens),
                Some(role),
                "{}: {needle}",
                language.name()
            );
        }
    }
}

/// For one node the deeper pattern wins whichever order the grammar writes it in; every
/// vendored query counts the patterns tree-sitter does.
#[test]
fn specificity_ranks_structure_over_order() {
    assert_eq!(
        syntax::specificity(
            "; comment (with parens)\n\
             (identifier) @variable\n\
             (call_expression function: (identifier) @function)\n\
             ((identifier) @builtin (#match? @builtin \"^(a|b)$\"))\n\
             [(null) (true)] @constant\n\
             \"func\" @keyword"
        ),
        vec![1, 2, 2, 1, 0]
    );
    for language in Language::ALL {
        syntax::highlight("", language).unwrap_or_else(|e| panic!("{}: {e}", language.name()));
    }
}

/// Pultík logs and falls back to order when a count misses; here every vendored file must
/// count right, so that fallback never runs.
#[test]
fn every_vendored_query_counts_its_patterns() {
    let root = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Apps/Pultik/Resources/Queries"
    );
    for entry in std::fs::read_dir(root).expect("the vendored queries") {
        let dir = entry.expect("a directory entry").path();
        let name = dir.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        let grammar: tree_sitter::Language = match name {
            "go" => tree_sitter_go::LANGUAGE.into(),
            "typescript" => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            "tsx" => tree_sitter_typescript::LANGUAGE_TSX.into(),
            "javascript" => tree_sitter_javascript::LANGUAGE.into(),
            "html" => tree_sitter_html::LANGUAGE.into(),
            "json" => tree_sitter_json::LANGUAGE.into(),
            "yaml" => tree_sitter_yaml::LANGUAGE.into(),
            "markdown" => tree_sitter_md::LANGUAGE.into(),
            "markdown-inline" => tree_sitter_md::INLINE_LANGUAGE.into(),
            "rust" => tree_sitter_rust::LANGUAGE.into(),
            "bash" => tree_sitter_bash::LANGUAGE.into(),
            "php" => tree_sitter_php::LANGUAGE_PHP.into(),
            other => panic!("a vendored query with no grammar here: {other}"),
        };
        for kind in ["highlights", "tags"] {
            let Ok(source) = std::fs::read_to_string(dir.join(format!("{kind}.scm"))) else {
                continue;
            };
            let query = tree_sitter::Query::new(&grammar, &source)
                .unwrap_or_else(|e| panic!("{name}/{kind}: {e}"));
            assert_eq!(
                syntax::specificity(&source).len(),
                query.pattern_count(),
                "{name}/{kind}"
            );
        }
    }
}

#[test]
fn languages_come_from_paths() {
    let cases = [
        ("src/main.rs", Some(Language::Rust)),
        ("web/App.TSX", Some(Language::Tsx)),
        ("a/b.mjs", Some(Language::JavaScript)),
        ("events.jsonl", Some(Language::Json)),
        ("home/.zshrc", Some(Language::Bash)),
        ("README", None),
        ("Makefile", None),
        (".rs", None),
    ];
    for (path, expected) in cases {
        assert_eq!(Language::from_path(path), expected, "{path}");
    }
}

/// The one-shot runs of a text, as absolute spans.
fn one_shot(text: &str, language: Language) -> Vec<(usize, usize, SyntaxRole)> {
    let tokens = syntax::highlight(text, language).expect("highlights");
    let mut line_start = 0;
    let mut spans = Vec::new();
    for (line, content) in text.split('\n').enumerate() {
        for r in tokens.runs(line) {
            let start = line_start + r.start as usize;
            spans.push((start, start + r.len as usize, r.role));
        }
        line_start += content.len() + 1;
    }
    spans
}

fn all_lines(syntax: &mut Syntax, buf: &Buffer) -> Vec<(usize, usize, SyntaxRole)> {
    let mut out: Vec<Span> = Vec::new();
    syntax
        .highlight(buf, 0..buf.lines().len_lines(), &mut out)
        .expect("highlights");
    out.iter().map(|s| (s.start, s.end, s.role)).collect()
}

const RUST: &str = "use std::fmt;\n\n/// A point.\n#[derive(Debug)]\npub struct Point {\n    x: i32,\n}\n\nimpl Point {\n    pub fn new(x: i32) -> Self {\n        let label = \"日本 ✅\"; // a comment\n        println!(\"{label} {}\", x + 0x1f);\n        Self { x }\n    }\n}\n";

/// The editor's highlighter, reparsing after every edit, colours the text exactly as a fresh
/// one-shot parse of the edited text does.
#[test]
fn incremental_highlighting_matches_a_fresh_parse_after_each_edit() {
    let mut text = RUST.repeat(40);
    let mut buf = Buffer::from_text(&text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    // Exact reparses: no split for latency (`a_slow_region_splits_around_its_edit`).
    syntax.set_split_after(std::time::Duration::MAX);
    syntax.parse(&buf).expect("parses");
    assert_eq!(
        all_lines(&mut syntax, &buf),
        one_shot(&text, Language::Rust)
    );
    // Typing inside a string, breaking a line, deleting across lines, a comment opener.
    let edits: [(usize, usize, &str); 5] = [
        (300, 300, "abc"),
        (1_000, 1_000, "\n"),
        (2_000, 2_150, ""),
        (4_000, 4_000, "/* "),
        (4_500, 4_500, " */"),
    ];
    for (start, end, insert) in edits {
        let (cs, ce) = (buf.rope().byte_to_char(start), buf.rope().byte_to_char(end));
        let edit = buf.edit(cs..ce, insert);
        syntax.edit(&edit);
        assert!(syntax.reparse(&buf).expect("reparses"));
        text = buf.rope().to_string();
        assert_eq!(
            all_lines(&mut syntax, &buf),
            one_shot(&text, Language::Rust),
            "after replacing {start}..{end} with {insert:?}"
        );
    }
}

/// A background parse that edits overtake still lands on the edited text, and until it does
/// the lines asked for are coloured from a window parse.
#[test]
fn a_background_parse_catches_up_with_edits_made_meanwhile() {
    let text = RUST.repeat(200);
    let mut buf = Buffer::from_text(&text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    // Exact reparses: no split for latency (`a_slow_region_splits_around_its_edit`).
    syntax.set_split_after(std::time::Duration::MAX);
    syntax.parse_in_background(&buf).expect("spawns");
    let mut window = Vec::new();
    // Lines inside the 100th copy: the window starts at a column-0 line before them.
    let lines = 15 * 100..15 * 100 + 15;
    syntax
        .highlight(&buf, lines.clone(), &mut window)
        .expect("highlights a window");
    let start = buf.lines().line_to_byte(lines.start);
    let end = buf.lines().line_to_byte(lines.end);
    let fresh: Vec<_> = one_shot(&text, Language::Rust)
        .into_iter()
        .filter(|s| s.0 >= start && s.1 <= end)
        .collect();
    let windowed: Vec<_> = window
        .iter()
        .map(|s| (s.start, s.end, s.role))
        .filter(|s| s.0 >= start && s.1 <= end)
        .collect();
    assert_eq!(
        windowed, fresh,
        "the window colours its lines as the whole parse does"
    );
    let edit = buf.edit(10..10, "\nfn added() {}\n");
    syntax.edit(&edit);
    syntax.wait(&buf).expect("installs");
    assert!(syntax.is_parsed());
    let edited = buf.rope().to_string();
    assert_eq!(
        all_lines(&mut syntax, &buf),
        one_shot(&edited, Language::Rust)
    );
}

/// Markdown's inline grammar fills only what the block grammar left plain, incrementally too.
#[test]
fn markdown_reads_both_grammars_incrementally() {
    let text = "# Title\n\nSome *emphasis* and `code`.\n\n```rust\nlet x = 1;\n```\n";
    let mut buf = Buffer::from_text(text);
    let mut syntax = Syntax::new(Language::Markdown).expect("markdown");
    // Exact reparses: no split for latency (`a_slow_region_splits_around_its_edit`).
    syntax.set_split_after(std::time::Duration::MAX);
    syntax.parse(&buf).expect("parses");
    assert_eq!(
        all_lines(&mut syntax, &buf),
        one_shot(text, Language::Markdown)
    );
    let edit = buf.edit(9..9, "More **strong** text.\n");
    syntax.edit(&edit);
    let edited = buf.rope().to_string();
    let spans = all_lines(&mut syntax, &buf);
    assert_eq!(spans, one_shot(&edited, Language::Markdown));
    let strong = edited.find("strong").expect("the edit");
    assert!(
        spans
            .iter()
            .any(|s| s.0 <= strong && strong < s.1 && s.2 == Strong)
    );
}

/// Spans map onto the laid-out row's columns: tabs and wide chars shift them.
#[test]
fn row_spans_follow_the_layouts_columns() {
    let text = "\tlet s = \"日本\"; // done\n";
    let buf = Buffer::from_text(text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    syntax.parse(&buf).expect("parses");
    let mut spans = Vec::new();
    syntax
        .highlight(&buf, 0..1, &mut spans)
        .expect("highlights");
    let mut layout = Layout::default();
    layout.build(
        &buf,
        &Viewport {
            top: 0,
            offset: 0.0,
            rows: 1,
            cols: 80,
            wrap: false,
        },
    );
    let row = &layout.rows()[0];
    let mut cols = Vec::new();
    syntax::row_spans(&layout, row, &spans, |a, b, role| cols.push((a, b, role)));
    // `let` after a tab (column 4); the string's CJK chars are two columns each.
    assert_eq!(cols.first(), Some(&(4, 7, Keyword)));
    assert!(cols.contains(&(12, 18, String)), "{cols:?}");
    assert!(cols.contains(&(20, 27, Comment)), "{cols:?}");
}

/// Regions: a file past one region parses in several, edits inside one region and across a
/// boundary (which merges the regions it spans) still colour as a fresh parse does.
#[test]
fn regions_reparse_alone_and_merge_across_an_edit() {
    let text = RUST.repeat(500);
    let mut buf = Buffer::from_text(&text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    // Exact reparses: no split for latency (`a_slow_region_splits_around_its_edit`).
    syntax.set_split_after(std::time::Duration::MAX);
    syntax.parse(&buf).expect("parses");
    let regions = syntax.regions();
    assert!(regions >= 3, "7,500 lines parse in {regions} regions");
    assert_eq!(
        all_lines(&mut syntax, &buf),
        one_shot(&text, Language::Rust)
    );
    let boundary = buf.lines().line_to_byte(syntax::REGION_LINES + 7);
    let edits: [(usize, usize, &str); 4] = [
        (
            buf.lines().line_to_byte(3_000) + 4,
            buf.lines().line_to_byte(3_000) + 4,
            "x",
        ),
        (100, 100, "\n\n\n"),
        (boundary - 300, boundary + 300, ""),
        (boundary - 5, boundary - 5, "// line\n"),
    ];
    for (start, end, insert) in edits {
        let (cs, ce) = (buf.rope().byte_to_char(start), buf.rope().byte_to_char(end));
        let edit = buf.edit(cs..ce, insert);
        syntax.edit(&edit);
        let edited = buf.rope().to_string();
        assert_eq!(
            all_lines(&mut syntax, &buf),
            one_shot(&edited, Language::Rust),
            "after replacing {start}..{end} with {insert:?}"
        );
    }
    assert!(
        syntax.regions() < regions,
        "the edit across a boundary merged two regions"
    );
}

/// A boundary that falls inside a construct spanning lines (a string whose lines start at
/// column 0) breaks both regions' parses; the two merge, so it colours as a whole parse.
#[test]
fn a_boundary_inside_a_string_heals_by_merging() {
    let mut text = "fn f() -> u32 { 1 }\n".repeat(syntax::REGION_LINES - 3);
    text.push_str("const S: &str = \"\nline at column 0\nanother one\n\";\n");
    text.push_str(&"fn g() -> u32 { 2 }\n".repeat(50));
    let buf = Buffer::from_text(&text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    syntax.parse(&buf).expect("parses");
    assert_eq!(syntax.regions(), 1, "the broken boundary merged");
    assert_eq!(
        all_lines(&mut syntax, &buf),
        one_shot(&text, Language::Rust)
    );
}

/// The vendored queries are the pinned grammar crates' own, in the order `cargo xtask
/// vendor-queries` composes them: a Cargo pin that moves without the queries moving with it
/// fails here.
#[test]
fn the_vendored_queries_are_the_pinned_grammars_own() {
    use tree_sitter_javascript as js;
    use tree_sitter_typescript as ts;
    let cases: [(&str, &str, &[&str]); 17] = [
        ("go", "highlights", &[tree_sitter_go::HIGHLIGHTS_QUERY]),
        ("go", "tags", &[tree_sitter_go::TAGS_QUERY]),
        (
            "typescript",
            "highlights",
            &[js::HIGHLIGHT_QUERY, ts::HIGHLIGHTS_QUERY],
        ),
        ("typescript", "tags", &[js::TAGS_QUERY, ts::TAGS_QUERY]),
        (
            "tsx",
            "highlights",
            &[
                js::HIGHLIGHT_QUERY,
                js::JSX_HIGHLIGHT_QUERY,
                ts::HIGHLIGHTS_QUERY,
            ],
        ),
        ("tsx", "tags", &[js::TAGS_QUERY, ts::TAGS_QUERY]),
        (
            "javascript",
            "highlights",
            &[js::HIGHLIGHT_QUERY, js::JSX_HIGHLIGHT_QUERY],
        ),
        ("javascript", "tags", &[js::TAGS_QUERY]),
        ("html", "highlights", &[tree_sitter_html::HIGHLIGHTS_QUERY]),
        ("json", "highlights", &[tree_sitter_json::HIGHLIGHTS_QUERY]),
        ("yaml", "highlights", &[tree_sitter_yaml::HIGHLIGHTS_QUERY]),
        (
            "markdown",
            "highlights",
            &[tree_sitter_md::HIGHLIGHT_QUERY_BLOCK],
        ),
        (
            "markdown-inline",
            "highlights",
            &[tree_sitter_md::HIGHLIGHT_QUERY_INLINE],
        ),
        ("rust", "highlights", &[tree_sitter_rust::HIGHLIGHTS_QUERY]),
        ("rust", "tags", &[tree_sitter_rust::TAGS_QUERY]),
        ("bash", "highlights", &[tree_sitter_bash::HIGHLIGHT_QUERY]),
        ("php", "highlights", &[tree_sitter_php::HIGHLIGHTS_QUERY]),
    ];
    let root = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Apps/Pultik/Resources/Queries"
    );
    for (language, kind, sources) in cases {
        let path = format!("{root}/{language}/{kind}.scm");
        let vendored = std::fs::read_to_string(&path).expect("a vendored query");
        let mut at = 0;
        for (i, source) in sources.iter().enumerate() {
            let found = vendored[at..].find(source);
            assert!(found.is_some(), "{language}/{kind}: source {i} drifted");
            at += found.unwrap_or(0) + source.len();
        }
    }
    assert!(
        std::fs::read_to_string(format!("{root}/php/tags.scm"))
            .expect("php tags")
            .contains(tree_sitter_php::TAGS_QUERY)
    );
}

/// A slow reparse splits its region at the boundary lines around the edit (here every reparse
/// counts as slow): the pieces reuse the region's tree, later edits reparse only the piece
/// they land in, and valid code still colours exactly as a fresh parse.
#[test]
fn a_slow_region_splits_around_its_edit() {
    let text = RUST.repeat(100);
    let mut buf = Buffer::from_text(&text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    syntax.set_split_after(std::time::Duration::ZERO);
    syntax.parse(&buf).expect("parses");
    assert_eq!(syntax.regions(), 1);
    // Inside `new`'s body in the 50th copy, then a line break, then the copy after it.
    for line in [15 * 50 + 10, 15 * 50 + 11, 15 * 51 + 12] {
        let at = buf.lines().line_to_byte(line) + 8;
        let c = buf.rope().byte_to_char(at);
        let edit = buf.edit(c..c, if line % 2 == 0 { "x" } else { "\n" });
        syntax.edit(&edit);
        assert!(syntax.reparse(&buf).expect("reparses"));
        let edited = buf.rope().to_string();
        assert_eq!(
            all_lines(&mut syntax, &buf),
            one_shot(&edited, Language::Rust),
            "after an edit at line {line}"
        );
    }
    assert!(syntax.regions() >= 3, "{} regions", syntax.regions());
}

/// A split can cut through a construct the edits are building (a comment opened in one piece,
/// closed in the next); `settle` merges the pieces back and parses them whole, so the text
/// colours as a fresh parse does again.
#[test]
fn settling_merges_split_pieces_and_restores_a_whole_parse() {
    let text = RUST.repeat(100);
    let mut buf = Buffer::from_text(&text);
    let mut syntax = Syntax::new(Language::Rust).expect("rust");
    syntax.set_split_after(std::time::Duration::ZERO);
    syntax.parse(&buf).expect("parses");
    let type_at = |line: usize, insert: &str, buf: &mut Buffer, syntax: &mut Syntax| {
        let at = buf.lines().line_to_byte(line) + 8;
        let c = buf.rope().byte_to_char(at);
        let edit = buf.edit(c..c, insert);
        syntax.edit(&edit);
        syntax.reparse(buf).expect("reparses");
    };
    type_at(15 * 40 + 10, "/* ", &mut buf, &mut syntax);
    type_at(15 * 60 + 10, " */", &mut buf, &mut syntax);
    assert!(syntax.regions() > 1, "the slow reparses split");
    assert!(syntax.settle(&buf).expect("settles"));
    assert_eq!(syntax.regions(), 1);
    let edited = buf.rope().to_string();
    assert_eq!(
        all_lines(&mut syntax, &buf),
        one_shot(&edited, Language::Rust)
    );
    assert!(
        !syntax.settle(&buf).expect("settles"),
        "nothing left to merge"
    );
}
