//! Highlighting and tags: `code_core::syntax`'s one-shot half, Pultík's `SyntaxEngine`.
//! Languages cross as `CODE_CORE_LANGUAGE_*`; a run's kind is its `theme::SyntaxRole` plus
//! one (0 is plain), which is Pultík's `TokenKind` raw value.

use crate::{
    CODE_CORE_NONE, CodeCoreNumbers, CodeCoreStatus, CodeCoreStr, Failure, call, numbers_result,
    owned, put, utf16,
};
use code_core::syntax::{self, Language, LineTokens, Tag, TagRole};
use std::ffi::c_char;

pub const CODE_CORE_LANGUAGE_GO: u32 = 0;
pub const CODE_CORE_LANGUAGE_TYPESCRIPT: u32 = 1;
pub const CODE_CORE_LANGUAGE_TSX: u32 = 2;
pub const CODE_CORE_LANGUAGE_JAVASCRIPT: u32 = 3;
pub const CODE_CORE_LANGUAGE_HTML: u32 = 4;
pub const CODE_CORE_LANGUAGE_JSON: u32 = 5;
pub const CODE_CORE_LANGUAGE_YAML: u32 = 6;
pub const CODE_CORE_LANGUAGE_MARKDOWN: u32 = 7;
pub const CODE_CORE_LANGUAGE_RUST: u32 = 8;
pub const CODE_CORE_LANGUAGE_BASH: u32 = 9;
pub const CODE_CORE_LANGUAGE_PHP: u32 = 10;

/// A tag defines its name.
pub const CODE_CORE_TAG_DEFINITION: u8 = 0;
/// A tag uses its name.
pub const CODE_CORE_TAG_REFERENCE: u8 = 1;

pub(crate) fn language(code: u32) -> Result<Language, Failure> {
    usize::try_from(code)
        .ok()
        .and_then(|i| Language::ALL.get(i).copied())
        .ok_or(Failure::Invalid("an unknown language code"))
}

pub(crate) fn code(language: Language) -> u32 {
    Language::ALL
        .iter()
        .position(|&l| l == language)
        .expect("ALL lists every language") as u32
}

pub(crate) fn role(role: TagRole) -> u8 {
    match role {
        TagRole::Definition => CODE_CORE_TAG_DEFINITION,
        TagRole::Reference => CODE_CORE_TAG_REFERENCE,
    }
}

/// The language a path's extension (or name) highlights as, or `CODE_CORE_NONE` for plain
/// text.
///
/// # Safety
/// `path` is valid for the call; `language` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_language(
    path: CodeCoreStr,
    language: *mut u32,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let found = Language::from_path(unsafe { path.text() }?);
        // SAFETY: per this function's contract.
        unsafe { put(language, found.map_or(CODE_CORE_NONE, code)) }
    })
}

/// Whether a language's tags query names definitions and references (the data and prose
/// grammars ship none).
///
/// # Safety
/// `has_tags` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_language_has_tags(
    language: u32,
    has_tags: *mut bool,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        let tagged = self::language(language)?.has_tags();
        // SAFETY: per this function's contract.
        unsafe { put(has_tags, tagged) }
    })
}

/// One run of a kind inside a line, in UTF-16 units from the line's start.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CodeCoreTokenRun {
    pub start: u32,
    pub length: u32,
    /// `theme::SyntaxRole` + 1 (Pultík's `TokenKind`); never 0, plain draws no run.
    pub kind: u8,
}

/// A text's runs by line: line `i`'s are `runs[line_starts[i] .. line_starts[i + 1]]`, so
/// `line_starts` holds one entry more than the text has lines.
#[repr(C)]
pub struct CodeCoreTokens {
    pub runs: *const CodeCoreTokenRun,
    pub run_count: usize,
    pub line_starts: *const u32,
    pub line_start_count: usize,
}

type TokensData = (Vec<CodeCoreTokenRun>, Vec<u32>);

/// Highlight `text` in one parse (Pultík's `SyntaxEngine.highlight`): every line's runs.
///
/// # Safety
/// `text` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_tokens_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_highlight(
    text: CodeCoreStr,
    language: u32,
    out: *mut *mut CodeCoreTokens,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let text = unsafe { text.text() }?;
        let tokens = syntax::highlight(text, self::language(language)?)
            .map_err(|e| Failure::Core(e.to_string()))?;
        let data = units(text, &tokens);
        let result = owned::into_raw(data, |(runs, starts): &TokensData| CodeCoreTokens {
            runs: runs.as_ptr(),
            run_count: runs.len(),
            line_starts: starts.as_ptr(),
            line_start_count: starts.len(),
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// The core's byte runs as UTF-16 runs, one line at a time.
fn units(text: &str, tokens: &LineTokens) -> TokensData {
    let mut runs = Vec::with_capacity(tokens.all_runs().len());
    let mut starts = Vec::with_capacity(tokens.line_count() + 1);
    let mut lines = text.split('\n');
    for line in 0..tokens.line_count() {
        starts.push(runs.len() as u32);
        let text = lines.next().unwrap_or("");
        let ascii = text.is_ascii();
        let mut cursor = utf16::Cursor::default();
        for run in tokens.runs(line) {
            let (start, end) = (run.start as usize, (run.start + run.len) as usize);
            let (start, end) = match ascii {
                true => (start, end),
                false => (cursor.at(text, start), cursor.at(text, end)),
            };
            runs.push(CodeCoreTokenRun {
                start: start as u32,
                length: (end - start) as u32,
                kind: run.role as u8 + 1,
            });
        }
    }
    starts.push(runs.len() as u32);
    (runs, starts)
}

/// Free a highlight; null is a no-op.
///
/// # Safety
/// `tokens` is null or came from `code_core_highlight`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_tokens_free(tokens: *mut CodeCoreTokens) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreTokens, TokensData>(tokens) }
}

/// A definition or reference the tags query names.
#[repr(C)]
pub struct CodeCoreTag {
    /// `CODE_CORE_TAG_DEFINITION` or `CODE_CORE_TAG_REFERENCE`.
    pub role: u8,
    /// `function`, `class`, `method`, `call`, `type`, … as the query says.
    pub kind: CodeCoreStr,
    pub name: CodeCoreStr,
    /// 0-based line of the name.
    pub line: u32,
    /// The name's UTF-16 column on its line.
    pub column: u32,
}

#[repr(C)]
pub struct CodeCoreTags {
    pub tags: *const CodeCoreTag,
    pub count: usize,
}

type TagsData = (Vec<Tag>, Vec<CodeCoreTag>);

/// The definitions and references `text`'s tags query names (Pultík's
/// `SyntaxEngine.tags`); none for a language without one.
///
/// # Safety
/// `text` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_tags_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_tags(
    text: CodeCoreStr,
    language: u32,
    out: *mut *mut CodeCoreTags,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let text = unsafe { text.text() }?;
        let tags = syntax::tags(text, self::language(language)?)
            .map_err(|e| Failure::Core(e.to_string()))?;
        let views = tags
            .iter()
            .map(|t| CodeCoreTag {
                role: role(t.role),
                kind: CodeCoreStr::of(&t.kind),
                name: CodeCoreStr::of(&t.name),
                line: t.line,
                column: t.column,
            })
            .collect();
        let result = owned::into_raw((tags, views), |(_, views): &TagsData| CodeCoreTags {
            tags: views.as_ptr(),
            count: views.len(),
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// Free tags; null is a no-op.
///
/// # Safety
/// `tags` is null or came from `code_core_tags`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_tags_free(tags: *mut CodeCoreTags) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreTags, TagsData>(tags) }
}

/// Each top-level pattern's depth of node structure in a query source, in pattern order: the
/// paint rule's tie-break (`syntax::specificity`).
///
/// # Safety
/// `source` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_numbers_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_specificity(
    source: CodeCoreStr,
    out: *mut *mut CodeCoreNumbers,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let depths = syntax::specificity(unsafe { source.text() }?);
        // SAFETY: per this function's contract.
        unsafe { put(out, numbers_result(depths)) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{message, read, s};
    use crate::{CODE_CORE_INVALID, CODE_CORE_OK, code_core_numbers_free};
    use std::ptr::null_mut;

    fn highlight(text: &str, language: u32) -> Vec<Vec<(u32, u32, u8)>> {
        let mut out = null_mut();
        // SAFETY: valid arguments; freed below.
        let status = unsafe { code_core_highlight(s(text), language, &mut out, null_mut()) };
        assert_eq!(status, CODE_CORE_OK);
        // SAFETY: a live result.
        let tokens = unsafe { &*out };
        // SAFETY: arrays of the result's counts.
        let (runs, starts) = unsafe {
            (
                std::slice::from_raw_parts(tokens.runs, tokens.run_count),
                std::slice::from_raw_parts(tokens.line_starts, tokens.line_start_count),
            )
        };
        let lines = starts
            .windows(2)
            .map(|w| {
                runs[w[0] as usize..w[1] as usize]
                    .iter()
                    .map(|r| (r.start, r.length, r.kind))
                    .collect()
            })
            .collect();
        // SAFETY: freed once.
        unsafe { code_core_tokens_free(out) };
        lines
    }

    #[test]
    fn languages_come_from_paths_with_their_tags() {
        let read = |path: &str| {
            let (mut language, mut tags) = (0, false);
            // SAFETY: valid out parameters.
            let status = unsafe { code_core_language(s(path), &mut language, null_mut()) };
            assert_eq!(status, CODE_CORE_OK);
            if language != CODE_CORE_NONE {
                // SAFETY: as above.
                unsafe { code_core_language_has_tags(language, &mut tags, null_mut()) };
            }
            (language, tags)
        };
        assert_eq!(read("web/App.TSX"), (CODE_CORE_LANGUAGE_TSX, true));
        assert_eq!(read("notes.txt"), (CODE_CORE_NONE, false));
        assert_eq!(read("x.json"), (CODE_CORE_LANGUAGE_JSON, false));
        for (i, l) in Language::ALL.iter().enumerate() {
            assert_eq!(code(*l), i as u32);
        }
    }

    /// Runs leave in UTF-16 units: a string after a two-unit emoji starts two units on, not
    /// four bytes.
    #[test]
    fn runs_count_utf16_units() {
        let ascii = highlight("let s = \"x\";\n", CODE_CORE_LANGUAGE_JAVASCRIPT);
        let string = theme::SyntaxRole::String as u8 + 1;
        assert!(ascii[0].contains(&(8, 3, string)), "{ascii:?}");
        assert_eq!(ascii.len(), 2, "the line after the last newline");
        let wide = highlight("/*😀*/ let s = \"é\";\n", CODE_CORE_LANGUAGE_JAVASCRIPT);
        assert!(
            wide[0].contains(&(0, 6, theme::SyntaxRole::Comment as u8 + 1)),
            "{wide:?}"
        );
        assert!(wide[0].contains(&(15, 3, string)), "{wide:?}");
    }

    #[test]
    fn tags_and_refusals() {
        let mut out = null_mut();
        let text = "function render() {}\nrender();\n";
        // SAFETY: valid arguments; freed below.
        let status =
            unsafe { code_core_tags(s(text), CODE_CORE_LANGUAGE_JAVASCRIPT, &mut out, null_mut()) };
        assert_eq!(status, CODE_CORE_OK);
        // SAFETY: a live result.
        let tags = unsafe { std::slice::from_raw_parts((*out).tags, (*out).count) };
        let read: Vec<_> = tags
            .iter()
            .map(|t| (t.role, read(t.kind), read(t.name), t.line, t.column))
            .collect();
        assert!(read.contains(&(
            CODE_CORE_TAG_DEFINITION,
            "function".into(),
            "render".into(),
            0,
            9
        )));
        assert!(read.contains(&(
            CODE_CORE_TAG_REFERENCE,
            "call".into(),
            "render".into(),
            1,
            0
        )));
        // SAFETY: freed once.
        unsafe { code_core_tags_free(out) };

        let mut error = null_mut();
        let mut tokens = null_mut();
        // SAFETY: an unknown language is refused before any output.
        let status = unsafe { code_core_highlight(s("x"), 99, &mut tokens, &mut error) };
        assert_eq!(status, CODE_CORE_INVALID);
        assert!(tokens.is_null());
        assert_eq!(message(error).as_deref(), Some("an unknown language code"));
        let bad = crate::CodeCoreStr {
            ptr: [0xFFu8].as_ptr(),
            len: 1,
        };
        // SAFETY: invalid UTF-8 is refused.
        let status = unsafe { code_core_highlight(bad, 0, &mut tokens, null_mut()) };
        assert_eq!(status, CODE_CORE_INVALID);
    }

    #[test]
    fn specificity_ranks_structure() {
        let mut out = null_mut();
        let source = "(identifier) @v\n(call function: (identifier) @f)\n\"func\" @k\n";
        // SAFETY: valid arguments; freed below.
        let status = unsafe { code_core_specificity(s(source), &mut out, null_mut()) };
        assert_eq!(status, CODE_CORE_OK);
        // SAFETY: a live result.
        let depths = unsafe { std::slice::from_raw_parts((*out).values, (*out).count) };
        assert_eq!(depths, [1, 2, 0]);
        // SAFETY: freed once.
        unsafe { code_core_numbers_free(out) };
    }
}
