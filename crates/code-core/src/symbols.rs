//! Definitions and references per repo@head, ported from Pultík's `SymbolIndex` (PR workbench
//! D2): what the tags query ([`crate::syntax::tags`]) names in every file of a tagged
//! language — search-based navigation, never a language server. An ambiguous name lists
//! every candidate, ranked same file → imported files → same directory → the rest.
//!
//! Compact on purpose: a tag is a small entry under its name, its path an index into the file
//! table. [`SymbolIndexes`] keeps at most [`CAPACITY`] indexes, the least recently used going
//! first. Reading files and running off the main thread are the caller's (Pultík's mirror and
//! actor); this is the data and its rules.

use crate::syntax::{self, Language, SyntaxError, Tag, TagRole};
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// Indexes kept at once.
pub const CAPACITY: usize = 2;
/// A larger file is generated or minified: nobody navigates it.
pub const FILE_LIMIT: usize = 512 << 10;

/// A definition or a use of a name, where it is.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Symbol {
    pub role: TagRole,
    /// `function`, `method`, `class`, `call`, `type`, … as the tags query says.
    pub kind: String,
    pub name: String,
    pub path: String,
    /// 0-based, as a code view counts rows.
    pub line: u32,
    /// The name's UTF-16 column.
    pub column: u32,
}

#[derive(Debug, Clone, Copy)]
struct Entry {
    file: u32,
    line: u32,
    column: u32,
    kind: u8,
    role: TagRole,
}

/// One repo@head's symbols.
#[derive(Debug, Default)]
pub struct Index {
    files: Vec<String>,
    kinds: Vec<String>,
    kind_ids: HashMap<String, u8>,
    by_name: HashMap<String, Vec<Entry>>,
    used: u64,
}

impl Index {
    /// Index `path`'s tags. Two patterns can name one spot (JS and TS both tag `new X`): it
    /// counts once.
    pub fn add(&mut self, path: &str, tags: &[Tag]) {
        if tags.is_empty() {
            return;
        }
        let file = self.files.len() as u32;
        self.files.push(path.to_owned());
        let mut seen = HashSet::new();
        for tag in tags {
            if !seen.insert((tag.role == TagRole::Definition, tag.line, tag.column)) {
                continue;
            }
            let kind = self.kind(&tag.kind);
            self.by_name
                .entry(tag.name.clone())
                .or_default()
                .push(Entry {
                    file,
                    line: tag.line,
                    column: tag.column,
                    kind,
                    role: tag.role,
                });
        }
    }

    fn kind(&mut self, name: &str) -> u8 {
        if let Some(&id) = self.kind_ids.get(name) {
            return id;
        }
        if self.kinds.len() >= usize::from(u8::MAX) {
            return u8::MAX;
        }
        let id = self.kinds.len() as u8;
        self.kinds.push(name.to_owned());
        self.kind_ids.insert(name.to_owned(), id);
        id
    }

    /// Drop every name's list's growth slack.
    pub fn compact(&mut self) {
        for entries in self.by_name.values_mut() {
            entries.shrink_to_fit();
        }
        self.by_name.shrink_to_fit();
    }

    fn symbol(&self, entry: &Entry, name: &str) -> Symbol {
        Symbol {
            role: entry.role,
            kind: self
                .kinds
                .get(usize::from(entry.kind))
                .cloned()
                .unwrap_or_default(),
            name: name.to_owned(),
            path: self.files[entry.file as usize].clone(),
            line: entry.line,
            column: entry.column,
        }
    }

    /// Where `name` is defined, best first: in `path` itself, in a file `imports` names (or
    /// inside an imported directory: a Go package, a TS barrel's folder), in `path`'s
    /// directory, then everywhere else; by path and line within a rank.
    pub fn definitions(&self, name: &str, path: &str, imports: &[String]) -> Vec<Symbol> {
        let Some(entries) = self.by_name.get(name) else {
            return Vec::new();
        };
        let dir = directory(path);
        let mut ranked: Vec<(u8, Symbol)> = entries
            .iter()
            .filter(|e| e.role == TagRole::Definition)
            .map(|e| {
                let symbol = self.symbol(e, name);
                let rank = if symbol.path == path {
                    0
                } else if imported(&symbol.path, imports) {
                    1
                } else if directory(&symbol.path) == dir {
                    2
                } else {
                    3
                };
                (rank, symbol)
            })
            .collect();
        ranked.sort_by(|(ra, a), (rb, b)| {
            (ra, &a.path, a.line, a.column).cmp(&(rb, &b.path, b.line, b.column))
        });
        ranked.into_iter().map(|(_, s)| s).collect()
    }

    /// Every use of `name`, by path and line. A spot that also defines it is left out (Go's
    /// tags query names a type's own name as a reference).
    pub fn references(&self, name: &str) -> Vec<Symbol> {
        let Some(entries) = self.by_name.get(name) else {
            return Vec::new();
        };
        let defined: HashSet<(u32, u32, u32)> = entries
            .iter()
            .filter(|e| e.role == TagRole::Definition)
            .map(|e| (e.file, e.line, e.column))
            .collect();
        let mut uses: Vec<Symbol> = entries
            .iter()
            .filter(|e| {
                e.role == TagRole::Reference && !defined.contains(&(e.file, e.line, e.column))
            })
            .map(|e| self.symbol(e, name))
            .collect();
        uses.sort_by(|a, b| (&a.path, a.line, a.column).cmp(&(&b.path, b.line, b.column)));
        uses
    }
}

/// Each file's tags, parsed on up to four threads: the files of a tagged language no larger
/// than [`FILE_LIMIT`], with the files that failed to parse (left out, for the caller to
/// report: one bad file does not cost the repo its index).
pub fn index(files: &[(String, String)]) -> (Index, Vec<(String, SyntaxError)>) {
    let mut index = Index::default();
    let failed = index.add_files(files);
    index.compact();
    (index, failed)
}

impl Index {
    /// [`index`] one batch of files into this index, so a caller reading a large repo holds
    /// one batch of texts at a time (Pultík reads its mirror 500 files a step). Returns the
    /// files that failed to parse; [`Index::compact`] once the last batch is in.
    pub fn add_files<P, T>(&mut self, files: &[(P, T)]) -> Vec<(String, SyntaxError)>
    where
        P: AsRef<str> + Sync,
        T: AsRef<str> + Sync,
    {
        let work: Vec<(&str, &str, Language)> = files
            .iter()
            .filter_map(|(path, text)| {
                let (path, text) = (path.as_ref(), text.as_ref());
                let language = Language::from_path(path).filter(|l| l.has_tags())?;
                (text.len() <= FILE_LIMIT).then_some((path, text, language))
            })
            .collect();
        self.add_parsed(&work)
    }

    fn add_parsed(&mut self, work: &[(&str, &str, Language)]) -> Vec<(String, SyntaxError)> {
        let threads = std::thread::available_parallelism()
            .map_or(2, |n| n.get() / 2)
            .clamp(2, 4)
            .min(work.len().max(1));
        let chunk = work.len().div_ceil(threads).max(1);
        let parsed: Vec<Vec<Result<Vec<Tag>, SyntaxError>>> = std::thread::scope(|s| {
            let handles: Vec<_> = work
                .chunks(chunk)
                .map(|files| {
                    s.spawn(move || {
                        files
                            .iter()
                            .map(|(_, text, language)| syntax::tags(text, *language))
                            .collect()
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().expect("a tags parse panicked"))
                .collect()
        });
        let mut failed = Vec::new();
        for ((path, _, _), tags) in work.iter().zip(parsed.into_iter().flatten()) {
            match tags {
                Ok(tags) => self.add(path, &tags),
                Err(e) => failed.push(((*path).to_owned(), e)),
            }
        }
        failed
    }
}

/// The indexes of the last few repo@heads.
#[derive(Debug, Default)]
pub struct SymbolIndexes {
    indexes: HashMap<(String, String), Index>,
    clock: u64,
}

impl SymbolIndexes {
    /// Index `files` as repo@head, replacing what it held; returns the files that failed.
    pub fn build(
        &mut self,
        repo: &str,
        head: &str,
        files: &[(String, String)],
    ) -> Vec<(String, SyntaxError)> {
        let (index, failed) = index(files);
        self.install(repo, head, index);
        failed
    }

    /// Keep `index` as repo@head, dropping the least recently used past [`CAPACITY`].
    pub fn install(&mut self, repo: &str, head: &str, mut index: Index) {
        self.clock += 1;
        index.used = self.clock;
        self.indexes
            .insert((repo.to_owned(), head.to_owned()), index);
        while self.indexes.len() > CAPACITY {
            let oldest = self
                .indexes
                .iter()
                .min_by_key(|(_, i)| i.used)
                .map(|(k, _)| k.clone())
                .expect("past capacity, so not empty");
            self.indexes.remove(&oldest);
        }
    }

    pub fn is_built(&self, repo: &str, head: &str) -> bool {
        self.indexes
            .contains_key(&(repo.to_owned(), head.to_owned()))
    }

    /// Drop every index (the panel released its tree).
    pub fn purge(&mut self) {
        self.indexes.clear();
    }

    fn get(&mut self, repo: &str, head: &str) -> Option<&Index> {
        self.clock += 1;
        let index = self.indexes.get_mut(&(repo.to_owned(), head.to_owned()))?;
        index.used = self.clock;
        Some(index)
    }

    /// [`Index::definitions`] in repo@head; empty when it is not built.
    pub fn definitions(
        &mut self,
        repo: &str,
        head: &str,
        name: &str,
        path: &str,
        imports: &[String],
    ) -> Vec<Symbol> {
        self.get(repo, head)
            .map_or_else(Vec::new, |i| i.definitions(name, path, imports))
    }

    /// [`Index::references`] in repo@head; empty when it is not built.
    pub fn references(&mut self, repo: &str, head: &str, name: &str) -> Vec<Symbol> {
        self.get(repo, head)
            .map_or_else(Vec::new, |i| i.references(name))
    }
}

// ---- imports ------------------------------------------------------------------------------

static MODULE_SPECIFIER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"\b(?:from|import|require)\s*\(?\s*["']([^"'\n]+)["']"#).expect("valid")
});
static GO_SINGLE_IMPORT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?m)^\s*import\s+(?:[\w.]+\s+)?"([^"\n]+)""#).expect("valid"));
static GO_IMPORT_BLOCK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?m)^\s*import\s*\(([^)]*)\)"#).expect("valid"));
static QUOTED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""([^"\n]+)""#).expect("valid"));
static RUST_MOD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;"#).expect("valid")
});
static RUST_CRATE_USE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"\buse\s+crate::([\w:]+)"#).expect("valid"));
static PHP_USE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?m)^\s*use\s+\\?([\w\\]+)(?:\s+as\s+\w+)?\s*;"#).expect("valid")
});

fn captures<'t>(regex: &Regex, text: &'t str) -> impl Iterator<Item = &'t str> {
    regex
        .captures_iter(text)
        .filter_map(|c| c.get(1).map(|m| m.as_str()))
}

/// The repo paths a file imports, for ranking definitions: TS and JS resolve relative
/// `import … from` / `export … from` / `import()` / `require()` specifiers to candidate files
/// (and the folder, for an index barrel); Go names each import path's last two components, a
/// directory suffix; Rust its `mod` files and `crate::` module paths; PHP its `use` classes
/// as PSR-4 file suffixes. Best effort: an alias or a package resolves to nothing.
pub fn imports(text: &str, language: Language, path: &str) -> Vec<String> {
    let dir = directory(path);
    let mut found: Vec<String> = Vec::new();
    match language {
        Language::TypeScript | Language::Tsx | Language::JavaScript => {
            for specifier in captures(&MODULE_SPECIFIER, text).filter(|s| s.starts_with('.')) {
                let Some(base) = joined(dir, specifier) else {
                    continue;
                };
                let scripts = ["ts", "tsx", "js", "jsx"];
                found.push(base.clone());
                found.extend(scripts.iter().map(|e| format!("{base}.{e}")));
                found.extend(scripts.iter().map(|e| format!("{base}/index.{e}")));
                // ESM TypeScript imports `./x.js` for `x.ts`.
                for ext in [".js", ".jsx", ".mjs", ".cjs"] {
                    if let Some(stem) = base.strip_suffix(ext) {
                        found.extend(["ts", "tsx"].iter().map(|e| format!("{stem}.{e}")));
                    }
                }
            }
        }
        Language::Go => {
            let mut specs: Vec<&str> = captures(&GO_SINGLE_IMPORT, text).collect();
            for block in captures(&GO_IMPORT_BLOCK, text) {
                specs.extend(captures(&QUOTED, block));
            }
            for spec in specs {
                let parts: Vec<&str> = spec.split('/').filter(|p| !p.is_empty()).collect();
                found.push(parts[parts.len().saturating_sub(2)..].join("/"));
            }
        }
        Language::Rust => {
            for module in captures(&RUST_MOD, text) {
                match dir.is_empty() {
                    true => found.extend([format!("{module}.rs"), format!("{module}/mod.rs")]),
                    false => found.extend([
                        format!("{dir}/{module}.rs"),
                        format!("{dir}/{module}/mod.rs"),
                    ]),
                }
            }
            for used in captures(&RUST_CRATE_USE, text) {
                let parts: Vec<&str> = used
                    .split("::")
                    .filter(|p| !p.is_empty() && *p != "self")
                    .collect();
                for end in 0..parts.len() {
                    let module = parts[..=end].join("/");
                    found.extend([format!("{module}.rs"), format!("{module}/mod.rs")]);
                }
            }
        }
        Language::Php => {
            for used in captures(&PHP_USE, text) {
                let parts: Vec<&str> = used.split('\\').filter(|p| !p.is_empty()).collect();
                if parts.is_empty() {
                    continue;
                }
                found.push(format!("{}.php", parts.join("/")));
                if parts.len() > 1 {
                    found.push(format!("{}.php", parts[1..].join("/")));
                }
            }
        }
        Language::Html | Language::Json | Language::Yaml | Language::Markdown | Language::Bash => {}
    }
    let mut seen = HashSet::new();
    found
        .into_iter()
        .filter(|f| !f.is_empty() && seen.insert(f.clone()))
        .collect()
}

/// `path` is a file `imports` names, or lies in a directory it names; both as path suffixes,
/// since a Go import path or a PHP namespace names the tail of a repo path, not all of it.
pub fn imported(path: &str, imports: &[String]) -> bool {
    let dir = directory(path);
    imports.iter().any(|entry| {
        path == entry
            || path.ends_with(&format!("/{entry}"))
            || (!dir.is_empty()
                && (dir == entry
                    || dir.ends_with(&format!("/{entry}"))
                    || entry.ends_with(&format!("/{dir}"))))
    })
}

/// The directory part of a repo path; empty at the root.
pub fn directory(path: &str) -> &str {
    path.rfind('/').map_or("", |at| &path[..at])
}

/// `directory` + a relative specifier, `.` and `..` resolved; `None` past the root.
fn joined(directory: &str, specifier: &str) -> Option<String> {
    let mut parts: Vec<&str> = directory.split('/').filter(|p| !p.is_empty()).collect();
    for part in specifier.split('/').filter(|p| !p.is_empty()) {
        match part {
            "." => {}
            ".." => {
                parts.pop()?;
            }
            part => parts.push(part),
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}
