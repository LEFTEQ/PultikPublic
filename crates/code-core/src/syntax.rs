//! Tree-sitter highlighting and tags, ported from Pultík's `SyntaxEngine` (workbench W13, PR
//! workbench D2). Both apps read the same vendored queries: `Apps/Pultik/Resources/Queries`
//! is compiled in here (`include_str!`), never copied, and the grammars are the crates at
//! Pultík's exact pins.
//!
//! **The paint rule**, exactly as Pultík paints: every capture of the highlights query that
//! styles something paints its node's bytes. Longer nodes paint first, so the innermost node
//! wins; for nodes of one length the more specific pattern ([`specificity`]) paints later,
//! then the later pattern. The grammars disagree on order (JavaScript writes its generic
//! `(identifier) @variable` first, Go and JSON last), but both mean the structural pattern to
//! beat the bare one. A `none` capture paints plain. Markdown's inline grammar parses the
//! whole text too and fills only the bytes the block grammar left plain.
//!
//! **One-shot** ([`highlight`], [`tags`]): one parse of a whole text, as Pultík's diff reads a
//! blob. **Incremental** ([`Syntax`]), as the editor reads a [`Buffer`]: the text is parsed
//! in regions of about [`REGION_LINES`] lines, each starting at a column-0 line, because one
//! tree's reparse costs time in proportion to the whole file. Each [`Edit`] is applied to its
//! region's tree as tree-sitter's `InputEdit`, and the next read reparses that region with
//! its old tree. Only the lines asked for are highlighted, in blocks of [`BLOCK_LINES`] lines
//! cached per tree generation (a bounded LRU). A large file parses on a background thread
//! ([`Syntax::parse_in_background`]); until it lands, the lines asked for are parsed alone, as
//! a window, so the viewport is coloured first.
//!
//! Offsets are bytes. Rows and columns follow tree-sitter: rows split at `\n` only, as
//! [`crate::LineIndex`]'s do.

use crate::buffer::{Buffer, Edit, TextChunks};
use crate::layout::{Layout, Row};
use ropey::Rope;
use std::fmt;
use std::ops::Range;
use std::sync::OnceLock;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use theme::SyntaxRole;
use tree_sitter::{
    InputEdit, Node, Parser, Point as TsPoint, Query, QueryCursor, Range as TsRange,
    StreamingIterator, TextProvider, Tree,
};

/// Lines per highlighted block: the unit the cache holds and a scroll recomputes.
pub const BLOCK_LINES: usize = 64;
/// Blocks the cache keeps (least recently used goes first): a few screens either way.
const CACHED_BLOCKS: usize = 48;
/// Lines a window parse reaches beyond the lines asked for, and how far back it looks for a
/// line that starts at column 0 (a likely top-level item) to start from.
const WINDOW_MARGIN: usize = 2 * BLOCK_LINES;
const WINDOW_LOOKBACK: usize = 512;

/// A language with a grammar and vendored queries; everything else draws plain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Language {
    Go,
    TypeScript,
    Tsx,
    JavaScript,
    Html,
    Json,
    Yaml,
    Markdown,
    Rust,
    Bash,
    Php,
}

impl Language {
    pub const ALL: [Language; 11] = [
        Language::Go,
        Language::TypeScript,
        Language::Tsx,
        Language::JavaScript,
        Language::Html,
        Language::Json,
        Language::Yaml,
        Language::Markdown,
        Language::Rust,
        Language::Bash,
        Language::Php,
    ];

    /// By the file's extension (or name); `None` is plain text.
    pub fn from_path(path: &str) -> Option<Self> {
        let name = path.rsplit('/').next().unwrap_or(path).to_lowercase();
        let ext = match name.rfind('.') {
            Some(at) if at > 0 => &name[at + 1..],
            _ => "",
        };
        Some(match ext {
            "go" => Language::Go,
            "ts" | "mts" | "cts" => Language::TypeScript,
            "tsx" => Language::Tsx,
            "js" | "mjs" | "cjs" | "jsx" => Language::JavaScript,
            "html" | "htm" => Language::Html,
            // JSONL parses as JSON: the grammar's document is any run of values.
            "json" | "jsonc" | "jsonl" | "ndjson" | "json5" => Language::Json,
            "yaml" | "yml" => Language::Yaml,
            "md" | "markdown" | "mdx" => Language::Markdown,
            "rs" => Language::Rust,
            "sh" | "bash" | "zsh" => Language::Bash,
            "php" => Language::Php,
            _ if [".bashrc", ".zshrc", ".profile", "dockerfile.sh"].contains(&name.as_str()) => {
                Language::Bash
            }
            _ => return None,
        })
    }

    /// The queries' directory name, Pultík's `SyntaxLanguage.rawValue`.
    pub fn name(self) -> &'static str {
        match self {
            Language::Go => "go",
            Language::TypeScript => "typescript",
            Language::Tsx => "tsx",
            Language::JavaScript => "javascript",
            Language::Html => "html",
            Language::Json => "json",
            Language::Yaml => "yaml",
            Language::Markdown => "markdown",
            Language::Rust => "rust",
            Language::Bash => "bash",
            Language::Php => "php",
        }
    }

    /// The tags query names definitions and references (the symbol index); the data and
    /// prose grammars ship none.
    pub fn has_tags(self) -> bool {
        matches!(
            self,
            Language::Go
                | Language::TypeScript
                | Language::Tsx
                | Language::JavaScript
                | Language::Rust
                | Language::Php
        )
    }

    fn grammar(self) -> Grammar {
        match self {
            Language::Go => Grammar::Go,
            Language::TypeScript => Grammar::TypeScript,
            Language::Tsx => Grammar::Tsx,
            Language::JavaScript => Grammar::JavaScript,
            Language::Html => Grammar::Html,
            Language::Json => Grammar::Json,
            Language::Yaml => Grammar::Yaml,
            Language::Markdown => Grammar::Markdown,
            Language::Rust => Grammar::Rust,
            Language::Bash => Grammar::Bash,
            Language::Php => Grammar::Php,
        }
    }
}

/// A grammar: one per language, plus Markdown's inline grammar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Grammar {
    Go,
    TypeScript,
    Tsx,
    JavaScript,
    Html,
    Json,
    Yaml,
    Markdown,
    MarkdownInline,
    Rust,
    Bash,
    Php,
}

const GRAMMARS: usize = 12;

macro_rules! queries {
    ($dir:literal, $kind:literal) => {
        include_str!(concat!(
            "../../../Apps/Pultik/Resources/Queries/",
            $dir,
            "/",
            $kind,
            ".scm"
        ))
    };
}

impl Grammar {
    fn index(self) -> usize {
        self as usize
    }

    fn name(self) -> &'static str {
        match self {
            Grammar::Go => "go",
            Grammar::TypeScript => "typescript",
            Grammar::Tsx => "tsx",
            Grammar::JavaScript => "javascript",
            Grammar::Html => "html",
            Grammar::Json => "json",
            Grammar::Yaml => "yaml",
            Grammar::Markdown => "markdown",
            Grammar::MarkdownInline => "markdown-inline",
            Grammar::Rust => "rust",
            Grammar::Bash => "bash",
            Grammar::Php => "php",
        }
    }

    fn language(self) -> tree_sitter::Language {
        match self {
            Grammar::Go => tree_sitter_go::LANGUAGE.into(),
            Grammar::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Grammar::Tsx => tree_sitter_typescript::LANGUAGE_TSX.into(),
            Grammar::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            Grammar::Html => tree_sitter_html::LANGUAGE.into(),
            Grammar::Json => tree_sitter_json::LANGUAGE.into(),
            Grammar::Yaml => tree_sitter_yaml::LANGUAGE.into(),
            Grammar::Markdown => tree_sitter_md::LANGUAGE.into(),
            Grammar::MarkdownInline => tree_sitter_md::INLINE_LANGUAGE.into(),
            Grammar::Rust => tree_sitter_rust::LANGUAGE.into(),
            Grammar::Bash => tree_sitter_bash::LANGUAGE.into(),
            Grammar::Php => tree_sitter_php::LANGUAGE_PHP.into(),
        }
    }

    fn highlights(self) -> &'static str {
        match self {
            Grammar::Go => queries!("go", "highlights"),
            Grammar::TypeScript => queries!("typescript", "highlights"),
            Grammar::Tsx => queries!("tsx", "highlights"),
            Grammar::JavaScript => queries!("javascript", "highlights"),
            Grammar::Html => queries!("html", "highlights"),
            Grammar::Json => queries!("json", "highlights"),
            Grammar::Yaml => queries!("yaml", "highlights"),
            Grammar::Markdown => queries!("markdown", "highlights"),
            Grammar::MarkdownInline => queries!("markdown-inline", "highlights"),
            Grammar::Rust => queries!("rust", "highlights"),
            Grammar::Bash => queries!("bash", "highlights"),
            Grammar::Php => queries!("php", "highlights"),
        }
    }

    fn tags(self) -> Option<&'static str> {
        Some(match self {
            Grammar::Go => queries!("go", "tags"),
            Grammar::TypeScript => queries!("typescript", "tags"),
            Grammar::Tsx => queries!("tsx", "tags"),
            Grammar::JavaScript => queries!("javascript", "tags"),
            Grammar::Rust => queries!("rust", "tags"),
            Grammar::Php => queries!("php", "tags"),
            _ => return None,
        })
    }
}

/// Why a language could not be highlighted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyntaxError {
    /// A vendored query did not compile against its grammar (a pin moved without the queries).
    Query { name: String, message: String },
    /// The grammar's ABI is not one this tree-sitter reads.
    Grammar { name: String, message: String },
    /// The parser gave up (it has no timeout or cancellation set, so this is unexpected).
    Parse(&'static str),
    /// The background parse's thread could not start or panicked.
    Thread(String),
}

impl fmt::Display for SyntaxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SyntaxError::Query { name, message } => {
                write!(f, "tree-sitter query {name}: {message}")
            }
            SyntaxError::Grammar { name, message } => {
                write!(f, "tree-sitter grammar {name}: {message}")
            }
            SyntaxError::Parse(name) => write!(f, "tree-sitter could not parse {name}"),
            SyntaxError::Thread(message) => write!(f, "background parse: {message}"),
        }
    }
}

impl std::error::Error for SyntaxError {}

// ---- queries ------------------------------------------------------------------------------

/// What a capture lays on its bytes: 0 is plain (`none`), `n` is `SyntaxRole::ALL[n - 1]`.
const PLAIN: u8 = 0;
/// A capture that styles nothing (`spell`, `embedded`, `injection.*`).
const NO_PAINT: u8 = u8::MAX;

fn role_of(paint: u8) -> SyntaxRole {
    SyntaxRole::ALL[usize::from(paint - 1)]
}

/// A capture name → what it paints, most specific prefix first (Pultík's `TokenKind`).
/// `None` styles nothing; `Some(PLAIN)` paints plain (Markdown clears fenced code with it).
fn capture_paint(name: &str) -> Option<u8> {
    use SyntaxRole::*;
    let mut parts = name.split('.').filter(|p| !p.is_empty());
    let head = parts.next()?;
    let second = parts.next().unwrap_or("");
    let last = name.rsplit('.').find(|p| !p.is_empty()).unwrap_or("");
    let role = match head {
        "none" => return Some(PLAIN),
        "keyword" | "conditional" | "repeat" | "include" | "exception" | "storageclass" => Keyword,
        "string" => match second {
            "escape" => Escape,
            "special" if last == "key" => Property,
            _ => String,
        },
        "character" | "escape" => Escape,
        "function" | "method" | "constructor" => Function,
        "type" => Type,
        "variable" => match second {
            "builtin" => Builtin,
            "parameter" => Parameter,
            "member" => Property,
            _ => Variable,
        },
        "parameter" => Parameter,
        "property" | "field" => Property,
        "number" | "float" | "boolean" => Number,
        "constant" => match second {
            "builtin" => Number,
            _ => Constant,
        },
        "comment" => Comment,
        "operator" => Operator,
        "punctuation" | "delimiter" => Punctuation,
        "tag" => Tag,
        "attribute" => Attribute,
        "module" | "namespace" | "label" => Module,
        "text" | "markup" => match second {
            "title" | "heading" => Heading,
            "literal" | "raw" => Literal,
            "emphasis" | "italic" => Emphasis,
            "strong" | "bold" => Strong,
            "uri" | "reference" | "link" => Link,
            _ => return None,
        },
        _ => return None,
    };
    Some(role as u8 + 1)
}

/// Each top-level pattern's depth of node structure, in pattern order: `(identifier)` is 1,
/// `(call function: (identifier))` 2, a predicate grouping `((identifier) (#eq? …))` 2,
/// `"func"` 0. Alternations (`[…]`), fields and predicates themselves add nothing.
pub fn specificity(source: &str) -> Vec<u32> {
    #[derive(PartialEq)]
    enum Bracket {
        Node,
        Group,
        Other,
    }
    let chars: Vec<char> = source.chars().collect();
    let mut depths = Vec::new();
    let mut stack: Vec<Bracket> = Vec::new();
    let (mut deepest, mut started, mut i) = (0, false, 0);
    while i < chars.len() {
        let c = chars[i];
        if c == ';' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if stack.is_empty() && matches!(c, '(' | '[' | '"') {
            // A new top-level pattern: the previous one is complete.
            if started {
                depths.push(deepest);
            }
            started = true;
            deepest = 0;
        }
        match c {
            '"' => {
                i += 1;
                while i < chars.len() && chars[i] != '"' {
                    i += if chars[i] == '\\' { 2 } else { 1 };
                }
                i += 1;
                continue;
            }
            '(' => {
                let mut next = i + 1;
                while next < chars.len() && chars[next].is_whitespace() {
                    next += 1;
                }
                stack.push(match chars.get(next).copied().unwrap_or(' ') {
                    '#' => Bracket::Other,
                    '(' | '[' | '"' => Bracket::Group,
                    _ => Bracket::Node,
                });
            }
            '[' => stack.push(Bracket::Other),
            ')' | ']' => {
                stack.pop();
            }
            _ => {}
        }
        deepest = deepest.max(stack.iter().filter(|b| **b != Bracket::Other).count() as u32);
        i += 1;
    }
    if started {
        depths.push(deepest);
    }
    depths
}

/// A compiled highlights query: each pattern's rank (specificity, then index) and what each
/// capture paints.
struct Highlights {
    query: Query,
    rank: Vec<u32>,
    paint: Vec<u8>,
}

/// A compiled tags query: each capture's role and kind (`definition.function` → definition,
/// "function"), and which capture is the name.
struct TagsQuery {
    query: Query,
    name: Option<u32>,
    roles: Vec<Option<(TagRole, String)>>,
}

fn grammar_language(grammar: Grammar) -> Result<tree_sitter::Language, SyntaxError> {
    // A parser accepts the language only if its ABI is one this tree-sitter reads.
    let language = grammar.language();
    Parser::new()
        .set_language(&language)
        .map_err(|e| SyntaxError::Grammar {
            name: grammar.name().into(),
            message: e.to_string(),
        })?;
    Ok(language)
}

fn compile(
    grammar: Grammar,
    kind: &str,
    source: &str,
) -> Result<(Query, tree_sitter::Language), SyntaxError> {
    let language = grammar_language(grammar)?;
    let query = Query::new(&language, source).map_err(|e| SyntaxError::Query {
        name: format!("{}/{kind}", grammar.name()),
        message: e.to_string(),
    })?;
    Ok((query, language))
}

fn highlights(grammar: Grammar) -> Result<&'static Highlights, SyntaxError> {
    static COMPILED: [OnceLock<Result<Highlights, SyntaxError>>; GRAMMARS] =
        [const { OnceLock::new() }; GRAMMARS];
    COMPILED[grammar.index()]
        .get_or_init(|| {
            let source = grammar.highlights();
            let (query, _) = compile(grammar, "highlights", source)?;
            let mut depths = specificity(source);
            if depths.len() != query.pattern_count() {
                // A miscount would rank the wrong patterns: order alone decides instead
                // (`every_vendored_query_counts_its_patterns` holds every vendored file).
                depths = vec![0; query.pattern_count()];
            }
            let rank = depths
                .iter()
                .enumerate()
                .map(|(i, d)| d << 20 | i as u32)
                .collect();
            let paint = query
                .capture_names()
                .iter()
                .map(|n| capture_paint(n).unwrap_or(NO_PAINT))
                .collect();
            Ok(Highlights { query, rank, paint })
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn tags_query(grammar: Grammar) -> Result<Option<&'static TagsQuery>, SyntaxError> {
    static COMPILED: [OnceLock<Result<Option<TagsQuery>, SyntaxError>>; GRAMMARS] =
        [const { OnceLock::new() }; GRAMMARS];
    COMPILED[grammar.index()]
        .get_or_init(|| {
            let Some(source) = grammar.tags() else {
                return Ok(None);
            };
            let (query, _) = compile(grammar, "tags", source)?;
            let names = query.capture_names();
            let name = names.iter().position(|n| *n == "name").map(|i| i as u32);
            let roles = names
                .iter()
                .map(|label| {
                    let (role, kind) = label.split_once('.')?;
                    let role = match role {
                        "definition" => TagRole::Definition,
                        "reference" => TagRole::Reference,
                        _ => return None,
                    };
                    (*label != "name" && !kind.is_empty()).then(|| (role, kind.to_owned()))
                })
                .collect();
            Ok(Some(TagsQuery { query, name, roles }))
        })
        .as_ref()
        .map(Option::as_ref)
        .map_err(Clone::clone)
}

// ---- text, parsing and painting -----------------------------------------------------------

/// A rope's text for query predicates, chunk by chunk; a tree's byte 0 is `base` in the rope.
struct RopeText<'a> {
    rope: &'a Rope,
    base: usize,
}

impl<'a> TextProvider<&'a [u8]> for RopeText<'a> {
    type I = std::iter::Map<TextChunks<'a>, fn(&'a str) -> &'a [u8]>;

    fn text(&mut self, node: Node) -> Self::I {
        let range = node.start_byte() + self.base..node.end_byte() + self.base;
        TextChunks::new(self.rope, range).map(str::as_bytes as fn(&'a str) -> &'a [u8])
    }
}

/// Parse bytes `range` of `rope` as one document (its byte 0 is `range.start`).
fn parse_part(
    parser: &mut Parser,
    rope: &Rope,
    range: Range<usize>,
    old: Option<&Tree>,
) -> Option<Tree> {
    parser.parse_with_options(
        &mut |byte: usize, _: TsPoint| -> &[u8] {
            let at = range.start + byte;
            if at >= range.end {
                return &[];
            }
            let (chunk, start, _, _) = rope.chunk_at_byte(at);
            let bytes = &chunk.as_bytes()[at - start..];
            &bytes[..bytes.len().min(range.end - at)]
        },
        old,
        None,
    )
}

fn new_parser(grammar: Grammar) -> Result<Parser, SyntaxError> {
    let mut parser = Parser::new();
    parser
        .set_language(&grammar_language(grammar)?)
        .map_err(|e| SyntaxError::Grammar {
            name: grammar.name().into(),
            message: e.to_string(),
        })?;
    Ok(parser)
}

/// A highlighted run: bytes `start..end`, never across a line end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub role: SyntaxRole,
}

#[derive(Debug, Clone, Copy)]
struct Capture {
    start: usize,
    end: usize,
    rank: u32,
    seq: u32,
    paint: u8,
}

/// The trees of one parsed piece of text: its grammar's, and Markdown's inline one.
type Parsed = (Tree, Option<Tree>);

/// A language's compiled highlights: its grammar's, and Markdown's inline one.
#[derive(Clone, Copy)]
struct Queries {
    main: &'static Highlights,
    inline: Option<&'static Highlights>,
}

impl Queries {
    fn new(language: Language) -> Result<Self, SyntaxError> {
        Ok(Self {
            main: highlights(language.grammar())?,
            inline: match language {
                Language::Markdown => Some(highlights(Grammar::MarkdownInline)?),
                _ => None,
            },
        })
    }
}

/// The parsers of one language: its grammar's, and Markdown's inline one.
struct Parsers {
    language: Language,
    main: Parser,
    inline: Option<Parser>,
}

impl Parsers {
    fn new(language: Language) -> Result<Self, SyntaxError> {
        Ok(Self {
            language,
            main: new_parser(language.grammar())?,
            inline: match language {
                Language::Markdown => Some(new_parser(Grammar::MarkdownInline)?),
                _ => None,
            },
        })
    }

    /// Parse `range` of the rope as one document, reusing `old` (already edited) if any.
    fn parse(
        &mut self,
        rope: &Rope,
        range: Range<usize>,
        old: Option<&Parsed>,
    ) -> Result<Parsed, SyntaxError> {
        let main = parse_part(&mut self.main, rope, range.clone(), old.map(|o| &o.0))
            .ok_or(SyntaxError::Parse(self.language.name()))?;
        let inline = match &mut self.inline {
            Some(p) => Some(
                parse_part(p, rope, range, old.and_then(|o| o.1.as_ref()))
                    .ok_or(SyntaxError::Parse("markdown-inline"))?,
            ),
            None => None,
        };
        Ok((main, inline))
    }
}

/// The buffers one paint reuses: a paint byte per text byte, for each grammar.
#[derive(Default)]
struct Painter {
    cursor: Option<QueryCursor>,
    captures: Vec<Capture>,
    paint: Vec<u8>,
    inline: Vec<u8>,
}

impl Painter {
    /// Start painting `n` bytes.
    fn begin(&mut self, n: usize) {
        self.paint.clear();
        self.paint.resize(n, PLAIN);
        self.inline.clear();
        self.inline.resize(n, PLAIN);
    }

    /// Paint `part` (absolute bytes, inside the painted range that starts at `origin`) from
    /// `trees`, whose byte 0 is `base` in the rope.
    fn part(
        &mut self,
        queries: Queries,
        trees: &Parsed,
        rope: &Rope,
        base: usize,
        part: Range<usize>,
        origin: usize,
    ) {
        let cursor = self.cursor.get_or_insert_with(QueryCursor::new);
        let at = part.start - origin..part.end - origin;
        let text = RopeText { rope, base };
        let out = &mut self.paint[at.clone()];
        paint(
            cursor,
            &mut self.captures,
            queries.main,
            &trees.0,
            text,
            part.clone(),
            out,
        );
        if let (Some(query), Some(tree)) = (queries.inline, &trees.1) {
            let text = RopeText { rope, base };
            let out = &mut self.inline[at];
            paint(cursor, &mut self.captures, query, tree, text, part, out);
        }
    }

    /// Fold the painted `range` into spans.
    fn finish(&mut self, rope: &Rope, range: Range<usize>, out: &mut Vec<Span>) {
        // Emphasis, code spans and links live in Markdown's inline grammar; they only fill
        // what the block grammar left plain (the buffer stays plain for other languages).
        for (p, i) in self.paint.iter_mut().zip(&self.inline) {
            if *p == PLAIN {
                *p = *i;
            }
        }
        fold(rope, range, &self.paint, out);
    }
}

/// Paint `range` (absolute) into `out` from `tree`'s captures: outer first, so inner nodes
/// overwrite; for one length the deepest, then latest, pattern last.
fn paint(
    cursor: &mut QueryCursor,
    captures: &mut Vec<Capture>,
    highlights: &'static Highlights,
    tree: &Tree,
    text: RopeText<'_>,
    range: Range<usize>,
    out: &mut [u8],
) {
    let base = text.base;
    captures.clear();
    cursor.set_byte_range(range.start - base..range.end - base);
    let mut seq = 0;
    let mut matches = cursor.matches(&highlights.query, tree.root_node(), text);
    while let Some(m) = matches.next() {
        let rank = highlights.rank[m.pattern_index];
        for c in m.captures {
            let paint = highlights.paint[c.index as usize];
            let (start, end) = (c.node.start_byte() + base, c.node.end_byte() + base);
            if paint == NO_PAINT || end <= start {
                continue;
            }
            captures.push(Capture {
                start,
                end,
                rank,
                seq,
                paint,
            });
            seq += 1;
        }
    }
    captures.sort_unstable_by(|a, b| {
        (b.end - b.start)
            .cmp(&(a.end - a.start))
            .then(a.rank.cmp(&b.rank))
            .then(a.seq.cmp(&b.seq))
    });
    for c in captures.iter() {
        let (start, end) = (c.start.max(range.start), c.end.min(range.end));
        if start < end {
            out[start - range.start..end - range.start].fill(c.paint);
        }
    }
}

/// Runs of one paint in `range`, split at line ends, as spans.
fn fold(rope: &Rope, range: Range<usize>, paint: &[u8], out: &mut Vec<Span>) {
    fn close(run: Option<(usize, u8)>, end: usize, out: &mut Vec<Span>) {
        if let Some((start, p)) = run
            && p != PLAIN
        {
            out.push(Span {
                start,
                end,
                role: role_of(p),
            });
        }
    }
    out.clear();
    let mut run: Option<(usize, u8)> = None;
    let mut at = range.start;
    for chunk in TextChunks::new(rope, range.clone()) {
        for (i, &b) in chunk.as_bytes().iter().enumerate() {
            let pos = at + i;
            let p = if b == b'\n' {
                PLAIN
            } else {
                paint[pos - range.start]
            };
            match run {
                Some((_, q)) if q == p => {}
                _ => {
                    close(run, pos, out);
                    run = Some((pos, p));
                }
            }
        }
        at += chunk.len();
    }
    close(run, range.end, out);
}

// ---- one-shot -----------------------------------------------------------------------------

/// A run of one role inside a line, in bytes from the line's start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TokenRun {
    pub start: u32,
    pub len: u32,
    pub role: SyntaxRole,
}

/// A text's runs by line (0-based); a line with none is plain. Flat: one run list, and each
/// line's first run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LineTokens {
    runs: Vec<TokenRun>,
    /// Line `i`'s runs are `runs[lines[i]..lines[i + 1]]`.
    lines: Vec<u32>,
}

impl LineTokens {
    pub fn line_count(&self) -> usize {
        self.lines.len().saturating_sub(1)
    }

    pub fn runs(&self, line: usize) -> &[TokenRun] {
        match (self.lines.get(line), self.lines.get(line + 1)) {
            (Some(&a), Some(&b)) => &self.runs[a as usize..b as usize],
            _ => &[],
        }
    }

    /// Every run, line by line: what a C caller copies out with [`LineTokens::line_starts`].
    pub fn all_runs(&self) -> &[TokenRun] {
        &self.runs
    }

    /// Runs already split by line, each line's in its own bytes, sorted: a host's highlights
    /// brought back into code-core's terms (canvas-ffi's diff).
    pub fn from_lines<L: IntoIterator<Item = TokenRun>>(
        lines: impl IntoIterator<Item = L>,
    ) -> Self {
        let mut tokens = LineTokens {
            runs: Vec::new(),
            lines: vec![0],
        };
        for line in lines {
            tokens.runs.extend(line);
            tokens.lines.push(tokens.runs.len() as u32);
        }
        tokens
    }

    /// Each line's first index into [`LineTokens::all_runs`], then the end.
    pub fn line_starts(&self) -> &[u32] {
        &self.lines
    }

    /// How many lines and runs it holds: a cache's cost.
    pub fn weight(&self) -> usize {
        self.line_count() + self.runs.len()
    }
}

/// Highlight a whole text in one parse: Pultík's `SyntaxEngine.highlight`.
pub fn highlight(text: &str, language: Language) -> Result<LineTokens, SyntaxError> {
    let rope = Rope::from_str(text);
    let whole = 0..rope.len_bytes();
    let trees = Parsers::new(language)?.parse(&rope, whole.clone(), None)?;
    let mut painter = Painter::default();
    painter.begin(whole.len());
    painter.part(Queries::new(language)?, &trees, &rope, 0, whole.clone(), 0);
    let mut spans = Vec::new();
    painter.finish(&rope, whole, &mut spans);
    let starts: Vec<usize> = std::iter::once(0)
        .chain(text.match_indices('\n').map(|(at, _)| at + 1))
        .collect();
    let mut tokens = LineTokens {
        runs: Vec::with_capacity(spans.len()),
        lines: vec![0],
    };
    let mut line = 0;
    for s in spans {
        // Spans never cross a line end: the line is the last one starting at or before it.
        while line + 1 < starts.len() && starts[line + 1] <= s.start {
            tokens.lines.push(tokens.runs.len() as u32);
            line += 1;
        }
        tokens.runs.push(TokenRun {
            start: (s.start - starts[line]) as u32,
            len: (s.end - s.start) as u32,
            role: s.role,
        });
    }
    while tokens.lines.len() <= starts.len() {
        tokens.lines.push(tokens.runs.len() as u32);
    }
    Ok(tokens)
}

/// What a tag says of its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TagRole {
    Definition,
    Reference,
}

/// A definition or reference the tags query names, by its identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tag {
    pub role: TagRole,
    /// `function`, `class`, `method`, `call`, `type`, … as the query says.
    pub kind: String,
    pub name: String,
    /// 0-based line of the name.
    pub line: u32,
    /// The name's column on its line in UTF-16 units (Pultík's and LSP's unit).
    pub column: u32,
    /// The same column in bytes.
    pub byte_column: u32,
}

/// The definitions and references a language's tags query names: Pultík's
/// `SyntaxEngine.tags`. Empty for a language without one.
pub fn tags(text: &str, language: Language) -> Result<Vec<Tag>, SyntaxError> {
    let grammar = language.grammar();
    let Some(query) = tags_query(grammar)? else {
        return Ok(Vec::new());
    };
    let Some(name_index) = query.name else {
        return Ok(Vec::new());
    };
    let tree = new_parser(grammar)?
        .parse(text, None)
        .ok_or(SyntaxError::Parse(grammar.name()))?;
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query.query, tree.root_node(), text.as_bytes());
    let mut tags = Vec::new();
    while let Some(m) = matches.next() {
        let Some(name) = m.captures.iter().find(|c| c.index == name_index) else {
            continue;
        };
        for capture in m.captures {
            let Some((role, kind)) = &query.roles[capture.index as usize] else {
                continue;
            };
            let (start, end) = (name.node.start_byte(), name.node.end_byte());
            // A point's column is in bytes, from its row's start.
            let at = name.node.start_position();
            let line_start = start - at.column;
            tags.push(Tag {
                role: *role,
                kind: kind.clone(),
                name: text[start..end].to_owned(),
                line: at.row as u32,
                column: text[line_start..start].encode_utf16().count() as u32,
                byte_column: at.column as u32,
            });
        }
    }
    Ok(tags)
}

// ---- incremental: regions -----------------------------------------------------------------

/// A region grows to this many lines (or bytes), then closes at its next boundary line.
/// tree-sitter's reparse after an edit walks the whole tree it reuses (about 0.2 ms per 2,000
/// lines of Rust, 190 ms for 1M lines on the WP3 bench), so one tree per file cannot reparse
/// within a frame; a region's can.
pub const REGION_LINES: usize = 2_048;
const REGION_BYTES: usize = 96 << 10;
/// Regions merged to heal a boundary stop growing past this many lines.
const REGION_MAX_LINES: usize = 16 * REGION_LINES;

/// A line a region may start at: one that begins at column 0 with neither space nor a closing
/// bracket, where a top-level item (or a comment above one) likely starts.
fn is_boundary(first: u8) -> bool {
    !matches!(first, b' ' | b'\t' | b'\n' | b'\r' | b'}' | b')' | b']')
}

/// Lines of the text parsed as one document: `lines` lines from `line`, its first byte
/// `byte`. Regions tile the buffer in order.
struct Region {
    line: usize,
    lines: usize,
    byte: usize,
    /// `None` until parsed, or after a merge: the next reparse parses it afresh.
    trees: Option<Parsed>,
    /// Edits applied to `trees` since it was parsed.
    edited: bool,
    /// The row the last edit in it ended on: where a slow region splits.
    hot: Option<usize>,
    /// The region a split cut it from: [`Syntax::settle`] merges a group back.
    group: Option<u32>,
}

/// The regions of a whole text: each at least [`REGION_LINES`] lines or [`REGION_BYTES`]
/// bytes, closing at the next boundary line.
fn partition(rope: &Rope) -> Vec<Region> {
    let mut regions = vec![Region {
        line: 0,
        lines: 0,
        byte: 0,
        trees: None,
        edited: false,
        hot: None,
        group: None,
    }];
    let (mut line, mut byte, mut line_start) = (0, 0, true);
    for chunk in rope.chunks() {
        for &b in chunk.as_bytes() {
            if line_start {
                let open = regions.last().expect("one region at least");
                let full = line - open.line >= REGION_LINES || byte - open.byte >= REGION_BYTES;
                if full && is_boundary(b) {
                    regions.last_mut().expect("one region at least").lines = line - open.line;
                    regions.push(Region {
                        line,
                        lines: 0,
                        byte,
                        trees: None,
                        edited: false,
                        hot: None,
                        group: None,
                    });
                }
            }
            line_start = b == b'\n';
            line += usize::from(line_start);
            byte += 1;
        }
    }
    let last = regions.last_mut().expect("one region at least");
    last.lines = line + 1 - last.line;
    regions
}

/// Region `i`'s bytes.
fn region_range(regions: &[Region], i: usize, len: usize) -> Range<usize> {
    regions[i].byte..regions.get(i + 1).map_or(len, |r| r.byte)
}

/// Whether `trees` has a syntax error in its first or its last top-level node: the sign of a
/// boundary inside a construct (a string or comment that spans lines).
fn boundary_errors(trees: &Parsed) -> (bool, bool) {
    let root = trees.0.root_node();
    if !root.has_error() {
        return (false, false);
    }
    let n = root.child_count();
    match (root.child(0), n.checked_sub(1).and_then(|i| root.child(i))) {
        (Some(first), Some(last)) if !root.is_error() => (first.has_error(), last.has_error()),
        _ => (true, true),
    }
}

/// Parse every region without trees, on up to eight threads, then merge neighbours across a
/// boundary that broke a construct.
fn parse_regions(
    language: Language,
    rope: &Rope,
    regions: &mut Vec<Region>,
) -> Result<(), SyntaxError> {
    let todo: Vec<(usize, Range<usize>)> = (0..regions.len())
        .filter(|&i| regions[i].trees.is_none())
        .map(|i| (i, region_range(regions, i, rope.len_bytes())))
        .collect();
    let threads = std::thread::available_parallelism()
        .map_or(1, |n| n.get())
        .clamp(1, 8)
        .min(todo.len());
    let next = std::sync::atomic::AtomicUsize::new(0);
    let work = || -> Result<Vec<(usize, Parsed)>, SyntaxError> {
        let mut parsers = Parsers::new(language)?;
        let mut done = Vec::new();
        loop {
            let k = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let Some((i, range)) = todo.get(k) else {
                return Ok(done);
            };
            done.push((*i, parsers.parse(rope, range.clone(), None)?));
        }
    };
    let parsed: Vec<Result<Vec<(usize, Parsed)>, SyntaxError>> = if threads <= 1 {
        vec![work()]
    } else {
        std::thread::scope(|s| {
            let handles: Vec<_> = (0..threads).map(|_| s.spawn(work)).collect();
            handles
                .into_iter()
                .map(|h| {
                    h.join().unwrap_or_else(|_| {
                        Err(SyntaxError::Thread("a parse thread panicked".into()))
                    })
                })
                .collect()
        })
    };
    for batch in parsed {
        for (i, trees) in batch? {
            regions[i].trees = Some(trees);
        }
    }
    heal(language, rope, regions)
}

/// Merge neighbouring regions whose shared boundary shows a syntax error, and parse the
/// union, until none does or the union would pass [`REGION_MAX_LINES`].
fn heal(language: Language, rope: &Rope, regions: &mut Vec<Region>) -> Result<(), SyntaxError> {
    let mut parsers: Option<Parsers> = None;
    let mut i = 0;
    while i + 1 < regions.len() {
        let errors = |r: &Region| r.trees.as_ref().map_or((false, false), boundary_errors);
        let broken = errors(&regions[i]).1 || errors(&regions[i + 1]).0;
        if !broken || regions[i].lines + regions[i + 1].lines > REGION_MAX_LINES {
            i += 1;
            continue;
        }
        let next = regions.remove(i + 1);
        regions[i].lines += next.lines;
        let range = region_range(regions, i, rope.len_bytes());
        let parsers = match &mut parsers {
            Some(p) => p,
            None => parsers.insert(Parsers::new(language)?),
        };
        regions[i].trees = Some(parsers.parse(rope, range, None)?);
    }
    Ok(())
}

/// Apply a buffer's edit to the regions: shift those after it, apply it to its region's
/// trees (in that region's own coordinates), and merge the regions it spans into one that
/// parses afresh.
fn edit_regions(regions: &mut Vec<Region>, e: &Edit) {
    if regions.is_empty() {
        return;
    }
    let find = |row: usize| regions.partition_point(|r| r.line <= row).saturating_sub(1);
    let (a, b) = (find(e.start.point.row), find(e.old_end.point.row));
    if b > a {
        let lines: usize = regions[a..=b].iter().map(|r| r.lines).sum();
        regions.drain(a + 1..=b);
        regions[a].lines = lines;
        regions[a].trees = None;
        regions[a].group = None;
    }
    let region = &mut regions[a];
    if let Some((tree, inline)) = &mut region.trees {
        let (byte, line) = (region.byte, region.line);
        let point = |p: crate::Point| TsPoint {
            row: p.row - line,
            column: p.column,
        };
        let local = InputEdit {
            start_byte: e.start.byte - byte,
            old_end_byte: e.old_end.byte - byte,
            new_end_byte: e.new_end.byte - byte,
            start_position: point(e.start.point),
            old_end_position: point(e.old_end.point),
            new_end_position: point(e.new_end.point),
        };
        tree.edit(&local);
        if let Some(t) = inline {
            t.edit(&local);
        }
        region.edited = true;
    }
    region.lines = region.lines + e.lines_added - e.lines_removed;
    region.hot = Some(e.new_end.point.row);
    for r in &mut regions[a + 1..] {
        r.line = r.line + e.lines_added - e.lines_removed;
        r.byte = r.byte + e.new_end.byte - e.old_end.byte;
        r.hot = r.hot.map(|h| h + e.lines_added - e.lines_removed);
    }
}

/// A reparse slower than this splits its region around the edit ([`Syntax::reparse`]).
/// tree-sitter never reuses an ERROR or fragile subtree, so text an edit leaves broken (typing
/// mid-statement) is parsed again, error recovery and all, by every later reparse of its
/// region: 1.7 µs a keystroke piled at one spot on the WP3 bench, 7 ms after 4,000.
pub const SPLIT_AFTER: Duration = Duration::from_millis(1);
/// How many lines a split looks through for a boundary line on either side of the edit.
const SPLIT_SCAN_LINES: usize = 4_096;

/// The start of the line before the one starting at `at` (`at > 0`).
fn line_start_before(rope: &Rope, at: usize) -> usize {
    let mut bytes = rope.bytes_at(at - 1);
    let mut pos = at - 1;
    while let Some(b) = bytes.prev() {
        pos -= 1;
        if b == b'\n' {
            return pos + 1;
        }
    }
    0
}

/// The start of the line after the one starting at `at`, if there is one.
fn line_start_after(rope: &Rope, at: usize) -> Option<usize> {
    let mut pos = at;
    for b in rope.bytes_at(at) {
        pos += 1;
        if b == b'\n' {
            return Some(pos);
        }
    }
    None
}

/// A line a region may split at: (line, its first byte).
type Cut = Option<(usize, usize)>;

/// Where a region splits around row `hot`: the nearest boundary line at or before `hot - 1`
/// (past the region's first line) and the nearest after `hot + 1` (inside the region). The
/// line on either side of the edit stays with it, so joining or splitting the edited line
/// stays inside one region.
fn cuts(buf: &Buffer, line: usize, lines: usize, hot: usize) -> (Cut, Cut) {
    let (rope, index) = (buf.rope(), buf.lines());
    let boundary = |at: usize| at < rope.len_bytes() && is_boundary(rope.byte(at));
    let mut before = None;
    if hot > line + 1 && hot < line + lines {
        let (mut l, mut at) = (hot - 1, index.line_to_byte(hot - 1));
        while l > line && hot - l <= SPLIT_SCAN_LINES {
            if boundary(at) {
                before = Some((l, at));
                break;
            }
            (l, at) = (l - 1, line_start_before(rope, at));
        }
    }
    let mut after = None;
    if hot + 2 < line + lines {
        let (mut l, mut at) = (hot + 1, index.line_to_byte(hot + 1));
        while let Some(next) = line_start_after(rope, at) {
            (l, at) = (l + 1, next);
            if l >= line + lines || l - hot > SPLIT_SCAN_LINES {
                break;
            }
            if boundary(at) {
                after = Some((l, at));
                break;
            }
        }
    }
    (before, after)
}

// ---- incremental: the highlighter ---------------------------------------------------------

/// A whole-text parse running on its own thread, and the edits made since it started.
struct Background {
    handle: JoinHandle<Result<Vec<Region>, SyntaxError>>,
    edits: Vec<Edit>,
}

/// Lines parsed on their own (absolute positions) while the whole-text parse runs.
struct Window {
    trees: Parsed,
    lines: Range<usize>,
    revision: u64,
}

/// One cached block of highlighted lines.
struct Block {
    index: usize,
    generation: u64,
    used: u64,
    spans: Vec<Span>,
}

/// Highlighting for one [`Buffer`]: its regions' trees, kept in step with its edits, and the
/// highlighted blocks of the current tree generation.
pub struct Syntax {
    language: Language,
    queries: Queries,
    parsers: Parsers,
    /// Empty until the whole text is parsed.
    regions: Vec<Region>,
    background: Option<Background>,
    window: Option<Window>,
    /// Bumped whenever a tree highlighting reads changes: a cached block names its own.
    generation: u64,
    painter: Painter,
    blocks: Vec<Block>,
    clock: u64,
    split_after: Duration,
    /// The last split group handed out.
    groups: u32,
}

impl Syntax {
    pub fn new(language: Language) -> Result<Self, SyntaxError> {
        Ok(Self {
            language,
            queries: Queries::new(language)?,
            parsers: Parsers::new(language)?,
            regions: Vec::new(),
            background: None,
            window: None,
            generation: 0,
            painter: Painter::default(),
            blocks: Vec::new(),
            clock: 0,
            split_after: SPLIT_AFTER,
            groups: 0,
        })
    }

    /// Split a region whose reparse takes longer than `after` ([`SPLIT_AFTER`] by default).
    pub fn set_split_after(&mut self, after: Duration) {
        self.split_after = after;
    }

    pub fn language(&self) -> Language {
        self.language
    }

    /// The whole text is parsed (not a window, nor a parse still running).
    pub fn is_parsed(&self) -> bool {
        !self.regions.is_empty()
    }

    /// How many regions the text is parsed in.
    pub fn regions(&self) -> usize {
        self.regions.len()
    }

    /// Parse the whole text now (its regions on up to eight threads).
    pub fn parse(&mut self, buf: &Buffer) -> Result<(), SyntaxError> {
        let rope = buf.rope();
        self.background = None;
        self.window = None;
        let mut regions = partition(rope);
        parse_regions(self.language, rope, &mut regions)?;
        self.regions = regions;
        self.generation += 1;
        Ok(())
    }

    /// Parse the whole text on a background thread; until [`Syntax::poll`] installs it,
    /// [`Syntax::highlight`] parses the lines it is asked for on their own.
    pub fn parse_in_background(&mut self, buf: &Buffer) -> Result<(), SyntaxError> {
        let rope = buf.rope().clone();
        let language = self.language;
        let handle = std::thread::Builder::new()
            .name("code-core-parse".into())
            .spawn(move || {
                let mut regions = partition(&rope);
                parse_regions(language, &rope, &mut regions)?;
                Ok(regions)
            })
            .map_err(|e| SyntaxError::Thread(e.to_string()))?;
        self.regions.clear();
        self.background = Some(Background {
            handle,
            edits: Vec::new(),
        });
        Ok(())
    }

    /// Install the background parse once it has finished, catching it up with the edits made
    /// since it started. True when it was installed by this call.
    pub fn poll(&mut self, buf: &Buffer) -> Result<bool, SyntaxError> {
        match &self.background {
            Some(b) if b.handle.is_finished() => self.finish(buf).map(|()| true),
            _ => Ok(false),
        }
    }

    /// Wait for the background parse and install it (nothing when none is running).
    pub fn wait(&mut self, buf: &Buffer) -> Result<(), SyntaxError> {
        match self.background {
            Some(_) => self.finish(buf),
            None => Ok(()),
        }
    }

    fn finish(&mut self, buf: &Buffer) -> Result<(), SyntaxError> {
        let Some(background) = self.background.take() else {
            return Ok(());
        };
        let mut regions = background
            .handle
            .join()
            .map_err(|_| SyntaxError::Thread("the parse thread panicked".into()))??;
        for e in &background.edits {
            edit_regions(&mut regions, e);
        }
        self.regions = regions;
        self.window = None;
        self.generation += 1;
        self.reparse(buf)?;
        Ok(())
    }

    /// Apply a buffer's edit to the trees (cheap); the next [`Syntax::reparse`] or
    /// [`Syntax::highlight`] reparses the region it touched.
    pub fn edit(&mut self, edit: &Edit) {
        edit_regions(&mut self.regions, edit);
        if let Some(b) = &mut self.background {
            b.edits.push(*edit);
        }
    }

    /// Reparse the regions edits touched, reusing their old trees: true when it parsed. A
    /// region whose reparse took longer than [`SPLIT_AFTER`] then splits at the boundary lines
    /// nearest its last edit, so what an edit left broken there is parsed again only while
    /// the edits stay near it.
    pub fn reparse(&mut self, buf: &Buffer) -> Result<bool, SyntaxError> {
        let rope = buf.rope();
        let mut parsed = false;
        let mut i = 0;
        while i < self.regions.len() {
            let region = &self.regions[i];
            if region.trees.is_some() && !region.edited {
                i += 1;
                continue;
            }
            let edited = region.trees.is_some();
            let range = region_range(&self.regions, i, rope.len_bytes());
            let t = Instant::now();
            let trees = self.parsers.parse(rope, range, region.trees.as_ref())?;
            let slow = t.elapsed() > self.split_after;
            let region = &mut self.regions[i];
            (region.trees, region.edited) = (Some(trees), false);
            parsed = true;
            i += 1;
            if edited && slow {
                i += self.split(i - 1, buf)?;
            }
        }
        if parsed {
            self.generation += 1;
        }
        Ok(parsed)
    }

    /// Merge the regions slow reparses split ([`Syntax::reparse`]) back into the regions they
    /// were cut from and parse those whole again (healing their boundaries as a load does),
    /// so a construct a cut broke — a comment opened in one piece and closed in the next —
    /// colours as a whole parse does again. The view calls it when idle; it costs a fresh
    /// parse of each merged region on this thread. True when anything merged.
    pub fn settle(&mut self, buf: &Buffer) -> Result<bool, SyntaxError> {
        let mut merged = false;
        let mut i = 0;
        while i < self.regions.len() {
            let Some(group) = self.regions[i].group else {
                i += 1;
                continue;
            };
            let end = (i + 1..self.regions.len())
                .find(|&j| self.regions[j].group != Some(group))
                .unwrap_or(self.regions.len());
            let lines = self.regions[i..end].iter().map(|r| r.lines).sum();
            self.regions.drain(i + 1..end);
            let region = &mut self.regions[i];
            (region.lines, region.trees, region.edited, region.group) = (lines, None, false, None);
            merged = true;
            i += 1;
        }
        if merged {
            parse_regions(self.language, buf.rope(), &mut self.regions)?;
            self.generation += 1;
        }
        Ok(merged)
    }

    /// Split region `i` (parsed) at the boundary lines around its last edit
    /// ([`cuts`]): each piece's trees are the region's with the rest deleted, reparsed, so
    /// the split reuses what it can. Returns how many regions it added.
    fn split(&mut self, i: usize, buf: &Buffer) -> Result<usize, SyntaxError> {
        let (line, lines) = (self.regions[i].line, self.regions[i].lines);
        let Some(hot) = self.regions[i].hot else {
            return Ok(0);
        };
        let (before, after) = cuts(buf, line, lines, hot);
        if before.is_none() && after.is_none() {
            return Ok(0);
        }
        let rope = buf.rope();
        let range = region_range(&self.regions, i, rope.len_bytes());
        // The region's end as a point of its own text.
        let end_point = match range.end == rope.len_bytes() {
            true => {
                let last = buf.lines().len_lines() - 1;
                let column = rope.len_bytes() - buf.lines().line_to_byte(last);
                TsPoint {
                    row: last - line,
                    column,
                }
            }
            false => TsPoint {
                row: lines,
                column: 0,
            },
        };
        let local = |l: usize, at: usize| {
            (
                at - range.start,
                TsPoint {
                    row: l - line,
                    column: 0,
                },
            )
        };
        let zero = TsPoint { row: 0, column: 0 };
        let edit = |trees: &mut Parsed, e: InputEdit| {
            trees.0.edit(&e);
            if let Some(t) = &mut trees.1 {
                t.edit(&e);
            }
        };
        let old = self.regions[i]
            .trees
            .take()
            .expect("a region splits right after it was reparsed");
        let group = match self.regions[i].group {
            Some(g) => g,
            None => {
                self.groups += 1;
                self.groups
            }
        };
        let starts: Vec<(usize, usize)> = std::iter::once((line, range.start))
            .chain(before)
            .chain(after)
            .collect();
        let mut pieces = Vec::with_capacity(starts.len());
        for (k, &(from, at)) in starts.iter().enumerate() {
            let (to, end) = starts
                .get(k + 1)
                .copied()
                .unwrap_or((line + lines, range.end));
            let mut trees = old.clone();
            // Delete what follows the piece, then what precedes it.
            if end < range.end {
                let (b, p) = local(to, end);
                edit(
                    &mut trees,
                    InputEdit {
                        start_byte: b,
                        old_end_byte: range.len(),
                        new_end_byte: b,
                        start_position: p,
                        old_end_position: end_point,
                        new_end_position: p,
                    },
                );
            }
            if at > range.start {
                let (b, p) = local(from, at);
                edit(
                    &mut trees,
                    InputEdit {
                        start_byte: 0,
                        old_end_byte: b,
                        new_end_byte: 0,
                        start_position: zero,
                        old_end_position: p,
                        new_end_position: zero,
                    },
                );
            }
            let parsed = self.parsers.parse(rope, at..end, Some(&trees))?;
            pieces.push(Region {
                line: from,
                lines: to - from,
                byte: at,
                trees: Some(parsed),
                edited: false,
                hot: (from <= hot && hot < to).then_some(hot),
                group: Some(group),
            });
        }
        let added = pieces.len() - 1;
        self.regions.splice(i..=i, pieces);
        Ok(added)
    }

    /// The spans of `lines` (sorted, absolute bytes) into `out`. Installs a finished
    /// background parse and reparses after edits; before the whole text is parsed, parses
    /// the lines asked for (and a margin) on their own.
    pub fn highlight(
        &mut self,
        buf: &Buffer,
        lines: Range<usize>,
        out: &mut Vec<Span>,
    ) -> Result<(), SyntaxError> {
        out.clear();
        let total = buf.lines().len_lines();
        let lines = lines.start.min(total)..lines.end.min(total);
        if lines.is_empty() {
            return Ok(());
        }
        let (first, last) = (lines.start / BLOCK_LINES, (lines.end - 1) / BLOCK_LINES);
        self.poll(buf)?;
        self.reparse(buf)?;
        if self.regions.is_empty() {
            self.window(
                buf,
                first * BLOCK_LINES..((last + 1) * BLOCK_LINES).min(total),
            )?;
        }
        for block in first..=last {
            let slot = self.block(buf, block);
            out.extend_from_slice(&self.blocks[slot].spans);
        }
        Ok(())
    }

    /// Make sure a window parse covers `lines` of the buffer as it is now.
    fn window(&mut self, buf: &Buffer, lines: Range<usize>) -> Result<(), SyntaxError> {
        if let Some(w) = &self.window
            && w.revision == buf.revision()
            && w.lines.start <= lines.start
            && lines.end <= w.lines.end
        {
            return Ok(());
        }
        let index = buf.lines();
        let rope = buf.rope();
        let total = index.len_lines();
        let mut start = lines.start.saturating_sub(WINDOW_MARGIN);
        for line in (start.saturating_sub(WINDOW_LOOKBACK)..=start).rev() {
            let at = index.line_to_byte(line);
            if at < rope.len_bytes() && is_boundary(rope.byte(at)) {
                start = line;
                break;
            }
        }
        let end = (lines.end + WINDOW_MARGIN).min(total);
        let bound = |line: usize| match line < total {
            true => (
                index.line_to_byte(line),
                TsPoint {
                    row: line,
                    column: 0,
                },
            ),
            false => {
                let (row, column) = index.byte_to_point(rope.len_bytes());
                (rope.len_bytes(), TsPoint { row, column })
            }
        };
        let ((start_byte, start_point), (end_byte, end_point)) = (bound(start), bound(end));
        let included = [TsRange {
            start_byte,
            end_byte,
            start_point,
            end_point,
        }];
        // The included range keeps positions absolute: the window's trees read at base 0.
        let parse = |parser: &mut Parser, name: &'static str| {
            parser
                .set_included_ranges(&included)
                .map_err(|_| SyntaxError::Parse(name))?;
            let tree = parse_part(parser, rope, 0..rope.len_bytes(), None);
            parser
                .set_included_ranges(&[])
                .map_err(|_| SyntaxError::Parse(name))?;
            tree.ok_or(SyntaxError::Parse(name))
        };
        let tree = parse(&mut self.parsers.main, self.language.name())?;
        let inline = match &mut self.parsers.inline {
            Some(p) => Some(parse(p, "markdown-inline")?),
            None => None,
        };
        self.window = Some(Window {
            trees: (tree, inline),
            lines: start..end,
            revision: buf.revision(),
        });
        self.generation += 1;
        Ok(())
    }

    /// The cache slot holding block `index` of the current generation, highlighting it on a
    /// miss into the least recently used slot.
    fn block(&mut self, buf: &Buffer, index: usize) -> usize {
        self.clock += 1;
        let generation = self.generation;
        if let Some(slot) = self
            .blocks
            .iter()
            .position(|b| b.index == index && b.generation == generation)
        {
            self.blocks[slot].used = self.clock;
            return slot;
        }
        let slot = if self.blocks.len() < CACHED_BLOCKS {
            self.blocks.push(Block {
                index,
                generation,
                used: 0,
                spans: Vec::new(),
            });
            self.blocks.len() - 1
        } else {
            let (slot, _) = self
                .blocks
                .iter()
                .enumerate()
                .min_by_key(|(_, b)| b.used)
                .expect("the cache is full, so not empty");
            slot
        };
        let (lines, rope) = (buf.lines(), buf.rope());
        let total = lines.len_lines();
        let byte = |line: usize| match line < total {
            true => lines.line_to_byte(line),
            false => rope.len_bytes(),
        };
        let range = byte(index * BLOCK_LINES)..byte((index + 1) * BLOCK_LINES);
        let painter = &mut self.painter;
        painter.begin(range.len());
        if self.regions.is_empty() {
            if let Some(w) = &self.window {
                painter.part(self.queries, &w.trees, rope, 0, range.clone(), range.start);
            }
        } else {
            let first = self
                .regions
                .partition_point(|r| r.byte <= range.start)
                .saturating_sub(1);
            for i in first..self.regions.len() {
                let region = region_range(&self.regions, i, rope.len_bytes());
                if region.start >= range.end {
                    break;
                }
                let part = region.start.max(range.start)..region.end.min(range.end);
                if let (Some(trees), false) = (&self.regions[i].trees, part.is_empty()) {
                    painter.part(self.queries, trees, rope, region.start, part, range.start);
                }
            }
        }
        let block = &mut self.blocks[slot];
        (block.index, block.generation, block.used) = (index, generation, self.clock);
        painter.finish(rope, range, &mut block.spans);
        slot
    }
}

/// `row`'s column spans from `spans` (sorted, absolute bytes): each `(start, end, role)` in
/// the row's columns, as [`Layout::cols`] places its chars.
pub fn row_spans(
    layout: &Layout,
    row: &Row,
    spans: &[Span],
    mut emit: impl FnMut(u16, u16, SyntaxRole),
) {
    let (text, cols) = (layout.text(row), layout.cols(row));
    let base = row.bytes.start;
    let first = spans.partition_point(|s| s.end <= base);
    // A walk over the row's chars: `k` chars before byte `at`.
    let (mut k, mut at) = (0, 0);
    let col = |target: usize, k: &mut usize, at: &mut usize| {
        while *at < target {
            let Some(c) = text[*at..].chars().next() else {
                break;
            };
            *at += c.len_utf8();
            *k += 1;
        }
        cols[(*k).min(cols.len() - 1)]
    };
    for s in &spans[first..] {
        if s.start >= row.bytes.end {
            break;
        }
        let start = s.start.max(base) - base;
        let end = s.end.min(row.bytes.end) - base;
        let a = col(start, &mut k, &mut at);
        let b = col(end, &mut k, &mut at);
        if a < b {
            emit(a, b, s.role);
        }
    }
}
