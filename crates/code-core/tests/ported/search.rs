//! `CodeSearchTests.swift`'s identifier under a column, and `GitMirrorTests.swift`'s grep
//! (PR workbench S13): match case, whole word, regex, no match, one hit per match with UTF-16
//! columns past multibyte text. The matcher runs in process here; git's selection of lines
//! and its records are `GrepRecords`'.

use code_core::search::{self, GrepRecords, LineMatcher, SearchOptions};

#[test]
fn word_at_finds_the_identifier_under_a_column() {
    let line = "const fooBar = $scope.ünïcode(42) + x_1;";
    assert_eq!(search::word_at(line, 6).as_deref(), Some("fooBar"));
    assert_eq!(search::word_at(line, 11).as_deref(), Some("fooBar"));
    assert_eq!(search::word_at(line, 16).as_deref(), Some("$scope"));
    assert_eq!(search::word_at(line, 24).as_deref(), Some("ünïcode"));
    assert_eq!(search::word_at(line, 37).as_deref(), Some("x_1"));
    assert_eq!(search::word_at(line, 12), None, "a space");
    assert_eq!(search::word_at(line, 31), None, "a number");
    assert_eq!(search::word_at(line, 99), None);
    assert_eq!(search::word_at(line, -1), None);
}

const SEARCH_TS: &str =
    "const fooBar = foo(1) + foo_x + Foo;\nnaïve foo ünïcode FOO\nnothing here\n";

fn spots(query: &str, options: SearchOptions, limit: usize) -> Vec<[u32; 3]> {
    let matcher = LineMatcher::new(query, options);
    search::search_text("lib/search.ts", SEARCH_TS, &matcher, limit)
        .iter()
        .map(|h| [h.line, h.column, h.length])
        .collect()
}

#[test]
fn grep_honours_match_case_whole_word_and_regex() {
    let any = search::search_text(
        "lib/search.ts",
        SEARCH_TS,
        &LineMatcher::new("foo", SearchOptions::default()),
        2_000,
    );
    assert_eq!(any[0].text, "const fooBar = foo(1) + foo_x + Foo;");
    let options = |case_sensitive, whole_word, regex| SearchOptions {
        case_sensitive,
        whole_word,
        regex,
    };
    assert_eq!(
        spots("foo", options(false, false, false), 2_000),
        [
            [1, 6, 3],
            [1, 15, 3],
            [1, 24, 3],
            [1, 32, 3],
            [2, 6, 3],
            [2, 18, 3]
        ]
    );
    assert_eq!(
        spots("foo", options(true, false, false), 2_000),
        [[1, 6, 3], [1, 15, 3], [1, 24, 3], [2, 6, 3]]
    );
    assert_eq!(
        spots("foo", options(false, true, false), 2_000),
        [[1, 15, 3], [1, 32, 3], [2, 6, 3], [2, 18, 3]]
    );
    assert_eq!(
        spots(r"f\w+_x|\bFOO\b", options(true, false, true), 2_000),
        [[1, 24, 5], [2, 18, 3]]
    );
    assert_eq!(
        spots("NAÏVE", options(false, false, false), 2_000),
        [[2, 0, 5]],
        "case folds characters, not bytes"
    );
    assert!(spots("zzz", options(false, false, false), 2_000).is_empty());
    assert_eq!(
        spots("foo", options(false, false, false), 2),
        [[1, 6, 3], [1, 15, 3]]
    );
}

/// `git grep -z -n --column` records: the head's prefix comes off the path, every match in
/// the line becomes a hit, a CR is not text, and a pattern the matcher cannot read falls
/// back to git's own first column.
#[test]
fn grep_records_become_hits_up_to_the_limit() {
    let mut records = GrepRecords::new(
        "abc123",
        3,
        LineMatcher::new("foo", SearchOptions::default()),
    );
    assert!(records.add(b"abc123:lib/a.ts\x001\x007\x00const fooBar = foo(1);\r"));
    assert!(!records.add(b"abc123:lib/b.ts\x004\x001\x00foo foo"));
    let hits: Vec<_> = records
        .hits()
        .iter()
        .map(|h| format!("{}:{}:{}:{}", h.path, h.line, h.column, h.length))
        .collect();
    assert_eq!(
        hits,
        ["lib/a.ts:1:6:3", "lib/a.ts:1:15:3", "lib/b.ts:4:0:3"]
    );
    assert_eq!(records.hits()[0].text, "const fooBar = foo(1);");
    assert!(!records.add(b"not a record"));
    assert_eq!(records.unreadable, 1);

    // Look-behind is past the regex crate: git found the line, so its column stands.
    let mut fallback = GrepRecords::new(
        "h",
        10,
        LineMatcher::new(
            "(?<=x)y",
            SearchOptions {
                regex: true,
                ..SearchOptions::default()
            },
        ),
    );
    fallback.add("h:a.txt\x002\x005\x00日xy".as_bytes());
    let hit = &fallback.hits()[0];
    assert_eq!(
        (hit.line, hit.column, hit.length),
        (2, 2, 0),
        "byte 5 is UTF-16 column 2"
    );
}
