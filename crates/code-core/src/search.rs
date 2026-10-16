//! Code search's in-process half, ported from Pultík (PR workbench D3, S13): the identifier
//! under a column (`CodeSearch.wordAt`), every match of a search in one line
//! (`GrepLineMatcher`), and `git grep -z -n --column` records turned into hits
//! (`GrepCollector`). Running git, the mirror and its backfill stay the app's. [`search_text`]
//! runs the same matcher over a text in process, the way git selects lines.
//!
//! Columns and lengths are UTF-16 units, as Pultík's `GrepHit` counts; [`Hit::bytes`] is the
//! same match in bytes.

use regex::{Regex, RegexBuilder};
use std::ops::Range;

/// How a search reads its query: match case, whole word and regex, the three toggles of an
/// editor's search field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct SearchOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    /// Perl-like (the `regex` crate's dialect: no look-around or backreferences; a pattern it
    /// cannot read finds only git's own first match, as Pultík's ICU fallback does).
    pub regex: bool,
}

/// One match: one hit per match, so a line matching twice is two hits.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Hit {
    pub path: String,
    /// 1-based, as an editor counts.
    pub line: u32,
    /// 0-based UTF-16 offset of the match in `text`.
    pub column: u32,
    /// The match's UTF-16 length.
    pub length: u32,
    /// The match in bytes of `text`.
    pub bytes: Range<usize>,
    /// The whole line, without its line ending.
    pub text: String,
}

/// Every match of a search in one line, found the way git walks a line: leftmost first, the
/// next from the previous match's end. Under whole word a rejected match retries one char
/// later, past the word it sits in (git's `-w`), and a word is ASCII letters, digits and `_`,
/// as git counts them.
#[derive(Debug, Clone)]
pub struct LineMatcher {
    query: String,
    options: SearchOptions,
    /// `None` for a case-sensitive literal (plain `find`), or a regex the crate cannot read.
    regex: Option<Regex>,
}

impl LineMatcher {
    pub fn new(query: &str, options: SearchOptions) -> Self {
        let pattern = match options.regex {
            true => Some(query.to_owned()),
            false => (!options.case_sensitive).then(|| regex::escape(query)),
        };
        let regex = pattern.and_then(|p| {
            RegexBuilder::new(&p)
                .case_insensitive(!options.case_sensitive)
                .build()
                .ok()
        });
        Self {
            query: query.to_owned(),
            options,
            regex,
        }
    }

    /// The byte ranges of every match in `line`.
    pub fn find(&self, line: &str) -> Vec<Range<usize>> {
        let mut found = Vec::new();
        let mut at = 0;
        while at < line.len() {
            let Some(m) = self.next(line, at) else {
                break;
            };
            if m.is_empty() {
                break;
            }
            if !self.options.whole_word || is_word(line, &m) {
                at = m.end;
                found.push(m);
            } else {
                at = m.start + line[m.start..].chars().next().map_or(1, char::len_utf8);
                while at < line.len() && is_word_byte(line.as_bytes()[at - 1]) {
                    at += 1;
                }
            }
        }
        found
    }

    /// The UTF-16 ranges of every match in `line`; `first_column` is git's own 0-based UTF-16
    /// column of the first match, the answer when this matcher finds none git did.
    pub fn ranges(&self, line: &str, first_column: usize) -> Vec<Range<usize>> {
        let found = self.find(line);
        if found.is_empty() {
            let length = line.encode_utf16().count();
            let column = first_column.min(length);
            let width = match self.options.regex {
                true => 0,
                false => self.query.encode_utf16().count().min(length - column),
            };
            return vec![Range {
                start: column,
                end: column + width,
            }];
        }
        let mut units = Utf16Cursor::default();
        found
            .into_iter()
            .map(|m| units.at(line, m.start)..units.at(line, m.end))
            .collect()
    }

    fn next(&self, line: &str, at: usize) -> Option<Range<usize>> {
        match (&self.regex, self.options.regex) {
            (Some(regex), _) => regex.find_at(line, at).map(|m| m.range()),
            (None, true) => None,
            (None, false) => line[at..]
                .find(&self.query)
                .map(|i| at + i..at + i + self.query.len()),
        }
    }
}

/// A forward-only byte → UTF-16 offset map over one line.
#[derive(Default)]
struct Utf16Cursor {
    byte: usize,
    unit: usize,
}

impl Utf16Cursor {
    fn at(&mut self, line: &str, byte: usize) -> usize {
        if byte < self.byte {
            *self = Self::default();
        }
        self.unit += line[self.byte..byte].encode_utf16().count();
        self.byte = byte;
        self.unit
    }
}

fn is_word_byte(b: u8) -> bool {
    b == b'_' || b.is_ascii_alphanumeric()
}

fn is_word(line: &str, m: &Range<usize>) -> bool {
    let bytes = line.as_bytes();
    (m.start == 0 || !is_word_byte(bytes[m.start - 1]))
        && (m.end == bytes.len() || !is_word_byte(bytes[m.end]))
}

/// Turns `git grep -z -n --column` records into hits as git prints them, stopping once
/// `limit` are in.
#[derive(Debug)]
pub struct GrepRecords {
    prefix: String,
    limit: usize,
    matcher: LineMatcher,
    hits: Vec<Hit>,
    /// Records that did not read as `<head>:<path>\0<line>\0<column>\0<text>`: the caller
    /// reports them.
    pub unreadable: usize,
}

impl GrepRecords {
    pub fn new(head: &str, limit: usize, matcher: LineMatcher) -> Self {
        Self {
            prefix: format!("{head}:"),
            limit,
            matcher,
            hits: Vec::new(),
            unreadable: 0,
        }
    }

    /// Take one record; false once `limit` hits are in (stop git).
    pub fn add(&mut self, record: &[u8]) -> bool {
        let fields: Vec<&[u8]> = record.splitn(4, |&b| b == 0).collect();
        let number = |f: &[u8]| std::str::from_utf8(f).ok()?.parse::<usize>().ok();
        let (Some(line), Some(byte_column), [name, _, _, text]) = (
            fields.get(1).and_then(|f| number(f)),
            fields.get(2).and_then(|f| number(f)),
            fields.as_slice(),
        ) else {
            self.unreadable += 1;
            return self.hits.len() < self.limit;
        };
        let name = String::from_utf8_lossy(name);
        let path = name.strip_prefix(&self.prefix).unwrap_or(&name).to_owned();
        let text = text.strip_suffix(b"\r").unwrap_or(text);
        let first = &text[..byte_column.saturating_sub(1).min(text.len())];
        let first_column = String::from_utf8_lossy(first).encode_utf16().count();
        let text = String::from_utf8_lossy(text).into_owned();
        let room = self.limit.saturating_sub(self.hits.len());
        let mut units = Utf16Cursor::default();
        let hits: Vec<Hit> = match self.matcher.find(&text) {
            found if !found.is_empty() => found
                .into_iter()
                .take(room)
                .map(|m| {
                    let column = units.at(&text, m.start);
                    let end = units.at(&text, m.end);
                    hit(&path, line, column..end, m, &text)
                })
                .collect(),
            _ => self
                .matcher
                .ranges(&text, first_column)
                .into_iter()
                .take(room)
                .map(|r| {
                    let bytes = byte_at(&text, r.start)..byte_at(&text, r.end);
                    hit(&path, line, r, bytes, &text)
                })
                .collect(),
        };
        self.hits.extend(hits);
        self.hits.len() < self.limit
    }

    pub fn hits(&self) -> &[Hit] {
        &self.hits
    }

    pub fn into_hits(self) -> Vec<Hit> {
        self.hits
    }
}

fn hit(path: &str, line: usize, units: Range<usize>, bytes: Range<usize>, text: &str) -> Hit {
    Hit {
        path: path.to_owned(),
        line: line as u32,
        column: units.start as u32,
        length: units.len() as u32,
        bytes,
        text: text.to_owned(),
    }
}

/// The byte offset of UTF-16 offset `unit` in `text` (clamped to a char boundary at or after).
fn byte_at(text: &str, unit: usize) -> usize {
    let mut units = 0;
    for (at, c) in text.char_indices() {
        if units >= unit {
            return at;
        }
        units += c.len_utf16();
    }
    text.len()
}

/// Every match of `matcher` in `text`'s lines, as `path`'s hits: the lines git would select,
/// at most `limit` hits.
pub fn search_text(path: &str, text: &str, matcher: &LineMatcher, limit: usize) -> Vec<Hit> {
    let mut hits = Vec::new();
    for (n, line) in text.split('\n').enumerate() {
        let line = line.strip_suffix('\r').unwrap_or(line);
        let mut units = Utf16Cursor::default();
        for m in matcher.find(line) {
            if hits.len() >= limit {
                return hits;
            }
            let start = units.at(line, m.start);
            let end = units.at(line, m.end);
            hits.push(hit(path, n + 1, start..end, m, line));
        }
    }
    hits
}

/// The identifier under UTF-16 `column` of `line`: what hover peeks and ⌘-click follows;
/// `None` off an identifier or on a number. Letters, digits, `_` and `$` (JavaScript, PHP)
/// make an identifier.
pub fn word_at(line: &str, column: isize) -> Option<String> {
    let units: Vec<u16> = line.encode_utf16().collect();
    word_range(&units, column).and_then(|r| String::from_utf16(&units[r]).ok())
}

/// [`word_at`]'s identifier as a UTF-16 range of `units` (a line's code units), for a caller
/// that holds the line already.
pub fn word_range(units: &[u16], column: isize) -> Option<Range<usize>> {
    let column = usize::try_from(column).ok()?;
    if !units.get(column).is_some_and(|&u| is_identifier(u)) {
        return None;
    }
    let (mut start, mut end) = (column, column + 1);
    while start > 0 && is_identifier(units[start - 1]) {
        start -= 1;
    }
    while end < units.len() && is_identifier(units[end]) {
        end += 1;
    }
    (!(0x30..=0x39).contains(&units[start])).then_some(start..end)
}

fn is_identifier(unit: u16) -> bool {
    // A surrogate half is no scalar: astral identifiers are not worth a pair walk.
    char::from_u32(u32::from(unit)).is_some_and(is_identifier_char)
}

/// A char an identifier is made of: ASCII letters, digits, `_` and `$`, and any other
/// alphabetic char. [`word_at`] reads identifiers by it, and the editor's word moves too.
pub fn is_identifier_char(c: char) -> bool {
    match c.is_ascii() {
        true => c == '_' || c == '$' || c.is_ascii_alphanumeric(),
        false => c.is_alphabetic(),
    }
}
