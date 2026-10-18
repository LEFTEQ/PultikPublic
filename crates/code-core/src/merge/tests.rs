use super::*;

fn kinds(m: &Merge) -> Vec<RegionKind> {
    m.regions.iter().map(|r| r.kind).collect()
}

#[test]
fn separate_edits_merge_and_the_regions_tile_every_text() {
    let base = "a\nb\nc\nd\ne\n";
    let ours = "A\nb\nc\nd\ne\n";
    let theirs = "a\nb\nc\nd\nE\n";
    let m = Merge::new(base, ours, theirs, None);
    assert_eq!(m.result, "A\nb\nc\nd\nE\n");
    assert_eq!(
        kinds(&m),
        [RegionKind::Ours, RegionKind::Unchanged, RegionKind::Theirs]
    );
    for side in [Side::Base, Side::Ours, Side::Theirs] {
        let mut at = 0;
        for r in &m.regions {
            assert_eq!(r.range(side).start, at);
            at = r.range(side).end;
        }
        assert_eq!(at, 5);
    }
}

proptest::proptest! {
    /// Any three texts merge into regions that tile each of them in order, and the result is
    /// the regions' lines.
    #[test]
    fn regions_tile_every_text(
        base in proptest::collection::vec(0u8..4, 0..12),
        ours in proptest::collection::vec(0u8..4, 0..12),
        theirs in proptest::collection::vec(0u8..4, 0..12),
    ) {
        let text = |v: &[u8]| v.iter().map(|&c| format!("{}\n", (b'a' + c) as char)).collect::<String>();
        let (b, o, t) = (text(&base), text(&ours), text(&theirs));
        let m = Merge::new(&b, &o, &t, None);
        let lens = [base.len(), ours.len(), theirs.len()];
        for (side, len) in [Side::Base, Side::Ours, Side::Theirs].into_iter().zip(lens) {
            let mut at = 0;
            for r in &m.regions {
                proptest::prop_assert_eq!(r.range(side).start, at);
                at = r.range(side).end;
            }
            proptest::prop_assert_eq!(at, len);
        }
        let mut at = 0;
        for r in &m.regions {
            proptest::prop_assert_eq!(r.result.start, at);
            at = r.result.end;
        }
        proptest::prop_assert_eq!(at, m.result.lines().count());
    }
}

/// The one resolved region of `m`, its kind and scope.
fn resolved(m: &Merge) -> (ResolutionKind, Option<String>) {
    let mut found = m.regions.iter().filter_map(|r| r.resolution.as_ref());
    let r = found.next().expect("a resolved region");
    assert!(found.next().is_none(), "one resolution");
    assert_eq!(m.conflicts(), 0);
    (r.kind, r.scope.clone())
}

#[test]
fn imports_both_sides_changed_are_unioned_in_order() {
    let base = "use a;\nuse c;\n\nfn main() {}\n";
    let ours = "use a;\nuse b;\nuse c;\n\nfn main() {}\n";
    let theirs = "use a;\nuse d;\n\nfn main() {}\n";
    let m = Merge::new(base, ours, theirs, Some(Language::Rust));
    // Theirs dropped `c` and added `d`; ours added `b`.
    assert_eq!(m.result, "use a;\nuse b;\nuse d;\n\nfn main() {}\n");
    assert_eq!(resolved(&m).0, ResolutionKind::Imports);
}

#[test]
fn items_both_sides_added_at_one_place_keep_ours_then_theirs() {
    let base = "export function a() {}\n";
    let ours = "export function a() {}\n\nexport function b() {}\n";
    let theirs = "export function a() {}\n\nexport function c() {}\n";
    let m = Merge::new(base, ours, theirs, Some(Language::TypeScript));
    assert_eq!(
        m.result,
        "export function a() {}\n\nexport function b() {}\n\nexport function c() {}\n"
    );
    assert_eq!(resolved(&m).0, ResolutionKind::BothAdded);
}

#[test]
fn entries_both_sides_added_to_a_json_object_get_their_separator() {
    let base = "{\n  \"a\": 1\n}\n";
    let ours = "{\n  \"a\": 1,\n  \"b\": 2\n}\n";
    let theirs = "{\n  \"a\": 1,\n  \"c\": 3\n}\n";
    let m = Merge::new(base, ours, theirs, Some(Language::Json));
    assert_eq!(m.result, "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n");
    assert_eq!(resolved(&m).0, ResolutionKind::BothAdded);
}

#[test]
fn edits_to_neighbouring_lines_merge_and_name_their_function() {
    let base = "fn total() {\n    let a = 1;\n    let b = 2;\n}\n";
    let ours = "fn total() {\n    let a = 10;\n    let b = 2;\n}\n";
    let theirs = "fn total() {\n    let a = 1;\n    let b = 20;\n}\n";
    let m = Merge::new(base, ours, theirs, Some(Language::Rust));
    assert_eq!(
        m.result,
        "fn total() {\n    let a = 10;\n    let b = 20;\n}\n"
    );
    assert_eq!(resolved(&m), (ResolutionKind::Lines, Some("total".into())));
}

#[test]
fn edits_to_different_words_of_one_line_merge() {
    let base = "const x = f(a, b);\n";
    let ours = "const x = f(a2, b);\n";
    let theirs = "const x = f(a, b2);\n";
    let m = Merge::new(base, ours, theirs, Some(Language::TypeScript));
    assert_eq!(m.result, "const x = f(a2, b2);\n");
    assert_eq!(resolved(&m).0, ResolutionKind::Words);
}

#[test]
fn an_edit_to_a_list_one_side_reordered_lands_in_the_new_order() {
    let base = "const L = [\n  \"a\",\n  \"b\",\n  \"c\",\n];\n";
    let ours = "const L = [\n  \"c\",\n  \"a\",\n  \"b\",\n];\n";
    let theirs = "const L = [\n  \"a\",\n  \"B\",\n  \"c\",\n];\n";
    let m = Merge::new(base, ours, theirs, Some(Language::TypeScript));
    assert_eq!(m.result, "const L = [\n  \"c\",\n  \"a\",\n  \"B\",\n];\n");
    let r = m
        .regions
        .iter()
        .find_map(|r| r.resolution.as_ref())
        .expect("a resolution");
    assert_eq!(
        (r.kind, r.reordered),
        (ResolutionKind::Reordered, Some(Side::Ours))
    );
    assert_eq!(m.conflicts(), 0);
}

#[test]
fn one_word_both_sides_changed_differently_stays_a_conflict_on_the_base() {
    let base = "let x = 1;\n";
    let m = Merge::new(base, "let x = 2;\n", "let x = 3;\n", Some(Language::Rust));
    assert_eq!(kinds(&m), [RegionKind::Conflict]);
    // The result pane starts from the base's lines, as a merge tool's does.
    assert_eq!(m.result, base);
}

#[test]
fn a_past_merge_says_which_side_its_commit_took() {
    let base = "a\nx = 1\nz\n";
    let (ours, theirs) = ("a\nx = 2\nz\n", "a\nx = 3\nz\n");
    let committed = "a\nx = 3\nz\nadded in the merge\n";
    let m = Merge::new(base, ours, theirs, None).against(base, ours, theirs, committed);
    assert_eq!(m.result, committed);
    let conflict = m
        .regions
        .iter()
        .find(|r| r.kind == RegionKind::Conflict)
        .unwrap();
    assert_eq!(conflict.committed, Some(Committed::Theirs));
    assert_eq!(
        &m.result.lines().nth(conflict.result.start).unwrap(),
        &"x = 3"
    );
    // The line the commit added lands in the last region, made by hand.
    let last = m.regions.last().unwrap();
    assert_eq!(
        (last.result.end, last.committed),
        (4, Some(Committed::Hand))
    );
}
