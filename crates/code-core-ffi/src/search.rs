//! Code search's in-process half: `code_core::search`, Pultík's `CodeSearch.wordAt`,
//! `GrepLineMatcher` and `GrepCollector`. Running git stays the app's: it hands each
//! `git grep -z -n --column` record to a `CodeCoreGrep`.

use crate::{CodeCoreStatus, CodeCoreStr, Failure, call, handle, owned, put, slice};
use code_core::search::{self, GrepRecords, Hit, LineMatcher, SearchOptions};
use std::ffi::c_char;

/// How a search reads its query: an editor's three toggles.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CodeCoreSearchOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    /// The `regex` crate's dialect; a pattern it cannot read finds only git's first match.
    pub regex: bool,
}

impl From<CodeCoreSearchOptions> for SearchOptions {
    fn from(o: CodeCoreSearchOptions) -> Self {
        SearchOptions {
            case_sensitive: o.case_sensitive,
            whole_word: o.whole_word,
            regex: o.regex,
        }
    }
}

/// A range of UTF-16 units.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CodeCoreRange {
    pub start: u32,
    pub end: u32,
}

#[repr(C)]
pub struct CodeCoreRanges {
    pub ranges: *const CodeCoreRange,
    pub count: usize,
}

/// A compiled search: immutable, so any thread may use it.
pub struct CodeCoreMatcher(LineMatcher);

/// `git grep` records turning into hits; one thread at a time.
pub struct CodeCoreGrep(GrepRecords);

/// One match: one per match, so a line matching twice is two hits.
#[repr(C)]
pub struct CodeCoreHit {
    pub path: CodeCoreStr,
    /// 1-based.
    pub line: u32,
    /// The match's UTF-16 offset in `text`, and its UTF-16 length.
    pub column: u32,
    pub length: u32,
    /// The whole line, without its line ending.
    pub text: CodeCoreStr,
}

#[repr(C)]
pub struct CodeCoreHits {
    pub hits: *const CodeCoreHit,
    pub count: usize,
}

type HitsData = (Vec<Hit>, Vec<CodeCoreHit>);

/// The identifier under UTF-16 `column` of a line given as its UTF-16 units: letters,
/// digits, `_` and `$`, not starting with a digit. `found` is false off one.
///
/// # Safety
/// `units` is null with `count` 0, or `count` units valid for the call; the out parameters
/// are valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_word_at(
    units: *const u16,
    count: usize,
    column: i64,
    found: *mut bool,
    word: *mut CodeCoreRange,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let units = unsafe { slice(units, count) }?;
        let range = search::word_range(units, isize::try_from(column).unwrap_or(-1));
        let range = range.map_or(CodeCoreRange { start: 0, end: 0 }, |r| CodeCoreRange {
            start: r.start as u32,
            end: r.end as u32,
        });
        // SAFETY: per this function's contract.
        unsafe {
            put(found, range.end > range.start)?;
            put(word, range)
        }
    })
}

/// Compile a search.
///
/// # Safety
/// `query` is valid for the call; `out` is valid for a write. Free the matcher with
/// `code_core_matcher_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_matcher_new(
    query: CodeCoreStr,
    options: CodeCoreSearchOptions,
    out: *mut *mut CodeCoreMatcher,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let matcher = LineMatcher::new(unsafe { query.text() }?, options.into());
        // SAFETY: per this function's contract.
        unsafe { put(out, Box::into_raw(Box::new(CodeCoreMatcher(matcher)))) }
    })
}

/// Free a matcher; null is a no-op.
///
/// # Safety
/// `matcher` is null or came from `code_core_matcher_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_matcher_free(matcher: *mut CodeCoreMatcher) {
    if !matcher.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(matcher) });
    }
}

/// Every match in `line`, the way git walks a line, as UTF-16 ranges; when the matcher finds
/// none, git's own first match at UTF-16 `first_column`.
///
/// # Safety
/// `matcher` is live; `line` is valid for the call; `out` is valid for a write. Free the
/// result with `code_core_ranges_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_matcher_ranges(
    matcher: *const CodeCoreMatcher,
    line: CodeCoreStr,
    first_column: usize,
    out: *mut *mut CodeCoreRanges,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let matcher = unsafe { matcher.as_ref() }.ok_or(Failure::Invalid("a null handle"))?;
        // SAFETY: per this function's contract.
        let found = matcher.0.ranges(unsafe { line.text() }?, first_column);
        let ranges: Vec<CodeCoreRange> = found
            .into_iter()
            .map(|r| CodeCoreRange {
                start: r.start as u32,
                end: r.end as u32,
            })
            .collect();
        // SAFETY: per this function's contract.
        unsafe { put(out, ranges_result(ranges)) }
    })
}

pub(crate) fn ranges_result(ranges: Vec<CodeCoreRange>) -> *mut CodeCoreRanges {
    owned::into_raw(ranges, |ranges| CodeCoreRanges {
        ranges: ranges.as_ptr(),
        count: ranges.len(),
    })
}

/// Free ranges; null is a no-op.
///
/// # Safety
/// `ranges` is null or came from this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_ranges_free(ranges: *mut CodeCoreRanges) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreRanges, Vec<CodeCoreRange>>(ranges) }
}

/// Start collecting `git grep -z -n --column` records of `head`'s search for `query`; at most
/// `limit` hits.
///
/// # Safety
/// Texts are valid for the call; `out` is valid for a write. Free the collector with
/// `code_core_grep_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_grep_new(
    head: CodeCoreStr,
    limit: usize,
    query: CodeCoreStr,
    options: CodeCoreSearchOptions,
    out: *mut *mut CodeCoreGrep,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (head, query) = unsafe { (head.text()?, query.text()?) };
        let records = GrepRecords::new(head, limit, LineMatcher::new(query, options.into()));
        // SAFETY: per this function's contract.
        unsafe { put(out, Box::into_raw(Box::new(CodeCoreGrep(records)))) }
    })
}

/// Free a collector; null is a no-op.
///
/// # Safety
/// `grep` is null or came from `code_core_grep_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_grep_free(grep: *mut CodeCoreGrep) {
    if !grep.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(grep) });
    }
}

/// Take one record, `<head>:<path>\0<line>\0<byte column>\0<text>` as git printed it (any
/// bytes). `more` is false once `limit` hits are in (stop git); `readable` is false for a
/// record of another shape, which adds nothing.
///
/// # Safety
/// `grep` is live and used by one thread; `record` is valid for the call; the out
/// parameters are valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_grep_add(
    grep: *mut CodeCoreGrep,
    record: CodeCoreStr,
    more: *mut bool,
    readable: *mut bool,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (grep, record) = unsafe { (handle(grep)?, record.bytes()?) };
        let unreadable = grep.0.unreadable;
        let wants_more = grep.0.add(record);
        // SAFETY: per this function's contract.
        unsafe {
            put(more, wants_more)?;
            put(readable, grep.0.unreadable == unreadable)
        }
    })
}

/// The hits so far, in git's order.
///
/// # Safety
/// `grep` is live and used by one thread; `out` is valid for a write. Free the result with
/// `code_core_hits_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_grep_hits(
    grep: *mut CodeCoreGrep,
    out: *mut *mut CodeCoreHits,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let hits = unsafe { handle(grep) }?.0.hits().to_vec();
        let views = hits
            .iter()
            .map(|h| CodeCoreHit {
                path: CodeCoreStr::of(&h.path),
                line: h.line,
                column: h.column,
                length: h.length,
                text: CodeCoreStr::of(&h.text),
            })
            .collect();
        let result = owned::into_raw((hits, views), |(_, views): &HitsData| CodeCoreHits {
            hits: views.as_ptr(),
            count: views.len(),
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// Free hits; null is a no-op.
///
/// # Safety
/// `hits` is null or came from `code_core_grep_hits`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_hits_free(hits: *mut CodeCoreHits) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreHits, HitsData>(hits) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CODE_CORE_OK;
    use crate::testing::{read, s};
    use std::ptr::null_mut;

    fn word(line: &str, column: i64) -> Option<String> {
        let units: Vec<u16> = line.encode_utf16().collect();
        let (mut found, mut range) = (false, CodeCoreRange { start: 0, end: 0 });
        // SAFETY: valid units and out parameters.
        let status = unsafe {
            code_core_word_at(
                units.as_ptr(),
                units.len(),
                column,
                &mut found,
                &mut range,
                null_mut(),
            )
        };
        assert_eq!(status, CODE_CORE_OK);
        found.then(|| {
            String::from_utf16(&units[range.start as usize..range.end as usize]).expect("UTF-16")
        })
    }

    #[test]
    fn the_word_under_a_utf16_column() {
        let line = "const fooBar = $scope.ünïcode(42) + x_1;";
        assert_eq!(word(line, 11).as_deref(), Some("fooBar"));
        assert_eq!(word(line, 16).as_deref(), Some("$scope"));
        assert_eq!(word(line, 24).as_deref(), Some("ünïcode"));
        assert_eq!(word(line, 31), None, "a number");
        assert_eq!((word(line, 99), word(line, -1)), (None, None));
    }

    /// Records become hits as git printed them: every match of the line in UTF-16, the
    /// limit stops git, and an unreadable record is flagged.
    #[test]
    fn records_become_hits_up_to_the_limit() {
        let options = CodeCoreSearchOptions {
            case_sensitive: false,
            whole_word: false,
            regex: false,
        };
        let mut grep = null_mut();
        // SAFETY: valid arguments; every result is freed.
        unsafe {
            code_core_grep_new(s("abc"), 3, s("render"), options, &mut grep, null_mut());
            let (mut more, mut readable) = (false, false);
            let record = "abc:src/é.ts\x001\x005\x00é = Render(render)";
            code_core_grep_add(grep, s(record), &mut more, &mut readable, null_mut());
            assert!(more && readable);
            code_core_grep_add(grep, s("garbage"), &mut more, &mut readable, null_mut());
            assert!(more && !readable);
            code_core_grep_add(
                grep,
                s("abc:b\x002\x001\x00render render"),
                &mut more,
                &mut readable,
                null_mut(),
            );
            assert!(!more, "the limit is in");
            let mut hits = null_mut();
            assert_eq!(
                code_core_grep_hits(grep, &mut hits, null_mut()),
                CODE_CORE_OK
            );
            let read: Vec<String> = std::slice::from_raw_parts((*hits).hits, (*hits).count)
                .iter()
                .map(|h| {
                    format!(
                        "{}:{}:{}+{} {}",
                        read(h.path),
                        h.line,
                        h.column,
                        h.length,
                        read(h.text)
                    )
                })
                .collect();
            assert_eq!(
                read,
                [
                    "src/é.ts:1:4+6 é = Render(render)",
                    "src/é.ts:1:11+6 é = Render(render)",
                    "b:2:0+6 render render"
                ]
            );
            code_core_hits_free(hits);
            code_core_grep_free(grep);

            let mut matcher = null_mut();
            let whole = CodeCoreSearchOptions {
                whole_word: true,
                ..options
            };
            code_core_matcher_new(s("ab"), whole, &mut matcher, null_mut());
            let mut ranges = null_mut();
            code_core_matcher_ranges(matcher, s("abc ab é ab"), 0, &mut ranges, null_mut());
            let found = std::slice::from_raw_parts((*ranges).ranges, (*ranges).count);
            assert_eq!(
                found,
                [
                    CodeCoreRange { start: 4, end: 6 },
                    CodeCoreRange { start: 9, end: 11 }
                ]
            );
            code_core_ranges_free(ranges);
            code_core_matcher_free(matcher);
        }
    }
}
