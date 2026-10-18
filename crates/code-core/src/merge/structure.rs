//! The structural resolvers (decision M6): each conflict the line merge leaves is offered, in
//! order, to an import union, a reorder, a token merge (different lines or words) and an
//! append of both sides' items. The first whose merged file parses with no more errors than
//! taking ours' or theirs' lines would leave wins; none winning leaves the conflict to the
//! reader, exactly as git does.

use super::lines::{self, Mode, Tokens};
use super::{Draft, RegionKind, Resolution, ResolutionKind, Side};
use crate::syntax::{self, Language};
use std::collections::HashSet;
use std::ops::Range;
use tree_sitter::{Node, Tree};

/// Conflicts past this many in one file stay as they are: each costs whole-file parses.
const MAX_CONFLICTS: usize = 64;
/// The longest scope name a resolution carries, in chars.
const SCOPE_CHARS: usize = 60;

/// One side's text, its lines' byte offsets and its tree.
struct Text<'a> {
    lines: &'a [&'a str],
    text: String,
    starts: Vec<usize>,
    tree: Option<Tree>,
}

impl<'a> Text<'a> {
    fn new(lines: &'a [&'a str], language: Language) -> Self {
        let text = lines.concat();
        let mut starts = Vec::with_capacity(lines.len() + 1);
        let mut at = 0;
        for l in lines {
            starts.push(at);
            at += l.len();
        }
        starts.push(at);
        let tree = syntax::tree(&text, language).ok();
        Self {
            lines,
            text,
            starts,
            tree,
        }
    }

    /// Lines `range` as bytes.
    fn bytes(&self, range: &Range<usize>) -> Range<usize> {
        self.starts[range.start]..self.starts[range.end]
    }

    fn chunk(&self, range: &Range<usize>) -> &str {
        &self.text[self.bytes(range)]
    }
}

/// Offer every conflict of `drafts` to the resolvers, last first (a reorder folds regions).
pub(super) fn resolve(language: Language, sides: &[Vec<&str>; 3], drafts: &mut Vec<Draft>) {
    let texts = [
        Text::new(&sides[0], language),
        Text::new(&sides[1], language),
        Text::new(&sides[2], language),
    ];
    if texts.iter().any(|t| t.tree.is_none()) {
        return;
    }
    let conflicts: Vec<usize> = (0..drafts.len())
        .filter(|&k| drafts[k].region.kind == RegionKind::Conflict)
        .take(MAX_CONFLICTS)
        .collect();
    // A reorder folds the regions of its list into one: conflicts at or after the first of
    // them are gone (and their indices moved).
    let mut floor = usize::MAX;
    for k in conflicts.into_iter().rev() {
        if k >= floor || drafts[k].region.kind != RegionKind::Conflict {
            continue;
        }
        let scope = scope(&texts[1], drafts[k].region.ours.start);
        if imports(language, &texts, &drafts[k].region).is_none()
            && let Some(first) = reorder(language, &texts, drafts, k, scope.clone())
        {
            floor = first;
            continue;
        }
        let r = &drafts[k].region;
        let (b, o, t) = (
            texts[0].chunk(&r.base).to_owned(),
            texts[1].chunk(&r.ours).to_owned(),
            texts[2].chunk(&r.theirs).to_owned(),
        );
        let span = k..k + 1;
        let baseline = baseline(language, &texts, drafts, &span);
        let ok = |drafts: &Vec<Draft>, text: &str| {
            errors(language, &candidate(&texts, drafts, &span, text)).is_some_and(|e| e <= baseline)
        };
        let found = imports(language, &texts, r)
            .map(|text| (ResolutionKind::Imports, text))
            .filter(|(_, text)| ok(drafts, text))
            .or_else(|| {
                tokens(&b, &o, &t)
                    .map(|(text, words)| {
                        let kind = if words {
                            ResolutionKind::Words
                        } else {
                            ResolutionKind::Lines
                        };
                        (kind, text)
                    })
                    .filter(|(_, text)| ok(drafts, text))
            })
            .or_else(|| {
                both_added(language, &texts, r, &b, &o, &t)
                    .into_iter()
                    .find(|text| ok(drafts, text))
                    .map(|text| (ResolutionKind::BothAdded, text))
            });
        if let Some((kind, text)) = found {
            let d = &mut drafts[k];
            d.region.kind = RegionKind::Resolved;
            d.region.resolution = Some(Resolution {
                kind,
                scope,
                reordered: None,
            });
            d.text = Some(text);
        }
    }
}

/// The merged file with regions `span` reading `text`: every other conflict takes ours' lines
/// (what a parser can read), every other region its result.
fn candidate(texts: &[Text<'_>; 3], drafts: &[Draft], span: &Range<usize>, text: &str) -> String {
    let mut out = String::with_capacity(texts[1].text.len() + text.len());
    for (i, d) in drafts.iter().enumerate() {
        if span.contains(&i) {
            if i == span.start {
                out.push_str(text);
            }
        } else if let Some(t) = &d.text {
            out.push_str(t);
        } else {
            let r = &d.region;
            let (side, range) = match r.kind {
                RegionKind::Theirs => (2, &r.theirs),
                _ => (1, &r.ours),
            };
            out.push_str(texts[side].chunk(range));
        }
    }
    out
}

/// The fewest errors taking one side's lines over `span` leaves: what a resolution must not
/// exceed.
fn baseline(
    language: Language,
    texts: &[Text<'_>; 3],
    drafts: &[Draft],
    span: &Range<usize>,
) -> usize {
    let (first, last) = (&drafts[span.start].region, &drafts[span.end - 1].region);
    [
        texts[1].chunk(&(first.ours.start..last.ours.end)),
        texts[2].chunk(&(first.theirs.start..last.theirs.end)),
    ]
    .iter()
    .filter_map(|side| errors(language, &candidate(texts, drafts, span, side)))
    .min()
    .unwrap_or(0)
}

/// Whether `text` over `span` parses with no more errors than either side's lines would.
fn parses(
    language: Language,
    texts: &[Text<'_>; 3],
    drafts: &[Draft],
    span: &Range<usize>,
    text: &str,
) -> bool {
    let most = baseline(language, texts, drafts, span);
    errors(language, &candidate(texts, drafts, span, text)).is_some_and(|e| e <= most)
}

/// Error and missing nodes in `text` parsed as `language`; `None` when it does not parse.
fn errors(language: Language, text: &str) -> Option<usize> {
    let tree = syntax::tree(text, language).ok()?;
    let root = tree.root_node();
    if !root.has_error() {
        return Some(0);
    }
    let mut n = 0;
    let mut cursor = root.walk();
    loop {
        let node = cursor.node();
        let descend = if node.is_error() || node.is_missing() {
            n += 1;
            false
        } else {
            node.has_error()
        };
        if descend && cursor.goto_first_child() {
            continue;
        }
        loop {
            if cursor.goto_next_sibling() {
                break;
            }
            if !cursor.goto_parent() {
                return Some(n);
            }
        }
    }
}

/// The name of the item ours' line `line` sits in: the nearest enclosing node with a name.
fn scope(text: &Text<'_>, line: usize) -> Option<String> {
    let tree = text.tree.as_ref()?;
    let at = text.starts[line.min(text.lines.len())];
    let mut node = tree.root_node().descendant_for_byte_range(at, at)?;
    while let Some(parent) = node.parent() {
        node = parent;
        let name = node.child_by_field_name("name").or_else(|| {
            (node.kind() == "impl_item")
                .then(|| node.child_by_field_name("type"))
                .flatten()
        });
        if let Some(name) = name {
            let name = text.text[name.byte_range()].lines().next()?.trim();
            if !name.is_empty() {
                return Some(name.chars().take(SCOPE_CHARS).collect());
            }
        }
    }
    None
}

// ---- imports ------------------------------------------------------------------------------

/// The node kinds that are one import each, per language.
fn import_kinds(language: Language) -> &'static [&'static str] {
    match language {
        Language::Rust => &["use_declaration", "extern_crate_declaration"],
        Language::Go => &["import_spec", "import_declaration"],
        Language::TypeScript | Language::Tsx | Language::JavaScript => &["import_statement"],
        Language::Php => &["namespace_use_declaration"],
        _ => &[],
    }
}

/// What a line of an import block is.
#[derive(PartialEq)]
enum ImportLine {
    Blank,
    Comment,
    Import,
}

/// Line `line` of `text`: blank, a comment, or one whole import; `None` for anything else.
fn import_line(text: &Text<'_>, line: usize, kinds: &[&str]) -> Option<ImportLine> {
    let raw = text.lines[line];
    let lead = raw.len() - raw.trim_start().len();
    let body = raw.trim();
    if body.is_empty() {
        return Some(ImportLine::Blank);
    }
    let (start, end) = (
        text.starts[line] + lead,
        text.starts[line] + lead + body.len(),
    );
    let mut node = text
        .tree
        .as_ref()?
        .root_node()
        .descendant_for_byte_range(start, end)?;
    loop {
        if node.kind().contains("comment") && node.start_byte() >= start && node.end_byte() <= end {
            return Some(ImportLine::Comment);
        }
        if kinds.contains(&node.kind()) {
            return (node.start_byte() >= start && node.end_byte() <= end)
                .then_some(ImportLine::Import);
        }
        if node.start_byte() < start || node.end_byte() > end {
            return None;
        }
        node = node.parent()?;
    }
}

/// Both sides changed one import block: ours' lines without those theirs removed, plus
/// theirs' new ones (in order when ours' are sorted, else after ours' last).
fn imports(language: Language, texts: &[Text<'_>; 3], r: &super::Region) -> Option<String> {
    let kinds = import_kinds(language);
    if kinds.is_empty() {
        return None;
    }
    let mut lines: [Vec<(&str, ImportLine)>; 3] = Default::default();
    for (side, range) in [&r.base, &r.ours, &r.theirs].into_iter().enumerate() {
        for line in range.clone() {
            let kind = import_line(&texts[side], line, kinds)?;
            lines[side].push((texts[side].lines[line], kind));
        }
    }
    let imports = |side: usize| -> HashSet<&str> {
        lines[side]
            .iter()
            .filter(|(_, k)| *k == ImportLine::Import)
            .map(|(l, _)| l.trim())
            .collect()
    };
    let (base, ours, theirs) = (imports(0), imports(1), imports(2));
    if ours.is_empty() && theirs.is_empty() {
        return None;
    }
    let mut out: Vec<String> = lines[1]
        .iter()
        // Every line but an import theirs removed (in the base, gone from theirs).
        .filter(|(l, k)| {
            *k != ImportLine::Import || !base.contains(l.trim()) || theirs.contains(l.trim())
        })
        .map(|(l, _)| (*l).to_owned())
        .collect();
    let is_import = |l: &str| ours.contains(l.trim()) || theirs.contains(l.trim());
    let sorted = {
        let keys: Vec<&str> = out
            .iter()
            .map(|l| l.trim())
            .filter(|l| is_import(l))
            .collect();
        keys.windows(2).all(|w| w[0] <= w[1])
    };
    for (line, kind) in &lines[2] {
        let key = line.trim();
        if *kind != ImportLine::Import || base.contains(key) || ours.contains(key) {
            continue;
        }
        let mut line = (*line).to_owned();
        if !line.ends_with('\n') {
            line.push('\n');
        }
        let after_last = out
            .iter()
            .rposition(|l| is_import(l))
            .map_or(out.len(), |i| i + 1);
        let at = if sorted {
            out.iter()
                .position(|l| is_import(l) && l.trim() > key)
                .unwrap_or(after_last)
        } else {
            after_last
        };
        out.insert(at, line);
    }
    // The block's last line keeps ours' ending: a file that ended without one still does.
    if let (Some(last), Some((ours_last, _))) = (out.last_mut(), lines[1].last())
        && !ours_last.ends_with('\n')
        && last.ends_with('\n')
        && r.ours.end == texts[1].lines.len()
    {
        last.pop();
    }
    Some(out.concat())
}

// ---- one side reordered a list ------------------------------------------------------------

/// A list entry's identity: its text without the separator after it.
fn entry_key(line: &str) -> &str {
    line.trim().trim_end_matches(',').trim_end()
}

/// Split the unchanged draft that ours' line `line` falls inside, so a draft starts there;
/// `None` when a changed one straddles it.
fn split(drafts: &mut Vec<Draft>, line: usize) -> Option<()> {
    let Some(p) = drafts
        .iter()
        .position(|d| d.region.ours.start < line && line < d.region.ours.end)
    else {
        return Some(());
    };
    if drafts[p].region.kind != RegionKind::Unchanged {
        return None;
    }
    let mut tail = drafts[p].clone();
    let n = line - tail.region.ours.start;
    let r = &mut drafts[p].region;
    (r.base.end, r.ours.end, r.theirs.end) = (r.base.start + n, line, r.theirs.start + n);
    let t = &mut tail.region;
    (t.base.start, t.ours.start, t.theirs.start) = (t.base.start + n, line, t.theirs.start + n);
    drafts.insert(p + 1, tail);
    Some(())
}

/// One side reordered the entries of the list conflict `k` sits in (one entry per line) and
/// the other edited, added or removed entries: those edits, applied in the new order, each
/// line keeping its place's indentation and separator. The list's regions fold into one
/// resolved region; returns the first folded index.
fn reorder(
    language: Language,
    texts: &[Text<'_>; 3],
    drafts: &mut Vec<Draft>,
    k: usize,
    scope: Option<String>,
) -> Option<usize> {
    let ours = &texts[1];
    let r = drafts[k].region.clone();
    let bytes = ours.bytes(&r.ours);
    let kinds = containers(language);
    let mut node = ours
        .tree
        .as_ref()?
        .root_node()
        .descendant_for_byte_range(bytes.start, bytes.end.max(bytes.start))?;
    let list = loop {
        if kinds.contains(&node.kind()) {
            break node;
        }
        node = node.parent()?;
    };
    let mut cursor = list.walk();
    let entries: Vec<Node<'_>> = list.named_children(&mut cursor).collect();
    if entries.len() < 2 {
        return None;
    }
    let line_of = |byte: usize| ours.starts.partition_point(|&s| s <= byte) - 1;
    let mut lines = HashSet::new();
    for e in &entries {
        let at = line_of(e.start_byte());
        if at != line_of(e.end_byte().max(e.start_byte() + 1) - 1)
            || !lines.insert(at)
            || entry_key(ours.lines[at]) != entry_key(&ours.text[e.byte_range()])
        {
            return None;
        }
    }
    let (s, e) = (*lines.iter().min()?, *lines.iter().max()? + 1);
    if r.ours.start < s
        || r.ours.end > e
        || (s..e).any(|l| !lines.contains(&l) && !ours.lines[l].trim().is_empty())
    {
        return None;
    }
    let mut work = drafts.clone();
    split(&mut work, s)?;
    split(&mut work, e)?;
    let i = work.iter().position(|d| d.region.ours.start >= s)?;
    let j = (i..work.len())
        .find(|&j| {
            let o = &work[j].region.ours;
            o.start > e || (o.start == e && !o.is_empty())
        })
        .unwrap_or(work.len());
    let (first, last) = (&work[i].region, &work[j - 1].region);
    let block = [
        first.base.start..last.base.end,
        first.ours.start..last.ours.end,
        first.theirs.start..last.theirs.end,
    ];
    let side_lines = |side: usize| &texts[side].lines[block[side].clone()];
    let entries_of = |side: usize| -> Vec<&str> {
        side_lines(side)
            .iter()
            .copied()
            .filter(|l| !entry_key(l).is_empty())
            .collect()
    };
    let keys =
        |lines: &[&str]| -> Vec<String> { lines.iter().map(|l| entry_key(l).to_owned()).collect() };
    let (b, o, t) = (entries_of(0), entries_of(1), entries_of(2));
    let (kb, ko, kt) = (keys(&b), keys(&o), keys(&t));
    let sorted = |v: &[String]| {
        let mut v = v.to_vec();
        v.sort();
        v
    };
    let (side, moved, edits, ke) = if ko != kb && sorted(&ko) == sorted(&kb) {
        (Side::Ours, 1, t, kt)
    } else if kt != kb && sorted(&kt) == sorted(&kb) {
        (Side::Theirs, 2, o, ko)
    } else {
        return None;
    };
    if ke == kb {
        return None;
    }
    // The edits, entry by entry of the base: kept, replaced or dropped, and what comes after.
    #[derive(Clone, Copy)]
    enum Fate<'s> {
        Keep,
        Replace(&'s str),
        Drop,
    }
    let mut fate = vec![Fate::Keep; kb.len()];
    let (mut before, mut after): (Vec<&str>, Vec<Vec<&str>>) =
        (Vec::new(), vec![Vec::new(); kb.len()]);
    let (kb_refs, ke_refs): (Vec<&str>, Vec<&str>) = (
        kb.iter().map(String::as_str).collect(),
        ke.iter().map(String::as_str).collect(),
    );
    let tk = Tokens::new(&kb_refs, &ke_refs, &[]);
    for h in lines::hunks(&tk.base, &tk.ours, tk.count) {
        let (bi, n, xk, m) = (
            h.before.start as usize,
            h.before.len(),
            h.after.start as usize,
            h.after.len(),
        );
        let paired = n.min(m);
        for d in 0..paired {
            fate[bi + d] = Fate::Replace(edits[xk + d]);
        }
        for d in paired..n {
            fate[bi + d] = Fate::Drop;
        }
        for d in paired..m {
            match (bi + paired).checked_sub(1) {
                Some(anchor) => after[anchor].push(edits[xk + d]),
                None => before.push(edits[xk + d]),
            }
        }
    }
    // The base entries by key, first unused first (a list may repeat an entry).
    let mut unused: std::collections::HashMap<&str, std::collections::VecDeque<usize>> =
        Default::default();
    for (i, key) in kb.iter().enumerate() {
        unused.entry(key.as_str()).or_default().push_back(i);
    }
    let mut out = String::new();
    let mut started = false;
    for line in side_lines(moved) {
        let key = entry_key(line);
        if key.is_empty() {
            out.push_str(line);
            continue;
        }
        if !started {
            started = true;
            out.extend(before.iter().copied());
        }
        let index = unused.get_mut(key)?.pop_front()?;
        match fate[index] {
            Fate::Keep => out.push_str(line),
            Fate::Replace(new) => {
                // The new entry in this line's place: its indentation, separator and ending.
                let lead = &line[..line.len() - line.trim_start().len()];
                let comma = if line.trim_end().ends_with(',') {
                    ","
                } else {
                    ""
                };
                let end = if line.ends_with('\n') { "\n" } else { "" };
                out.push_str(&format!("{lead}{}{comma}{end}", entry_key(new)));
            }
            Fate::Drop => {}
        }
        out.extend(after[index].iter().copied());
    }
    let span = i..j;
    if !parses(language, texts, &work, &span, &out) {
        return None;
    }
    let region = super::Region {
        kind: RegionKind::Resolved,
        base: block[0].clone(),
        ours: block[1].clone(),
        theirs: block[2].clone(),
        result: 0..0,
        resolution: Some(Resolution {
            kind: ResolutionKind::Reordered,
            scope,
            reordered: Some(side),
        }),
        committed: None,
    };
    work.splice(
        span,
        [Draft {
            region,
            text: Some(out),
        }],
    );
    *drafts = work;
    Some(i)
}

// ---- different lines or words -------------------------------------------------------------

/// A chunk's tokens: runs of letters, digits and `_`, runs of spaces and tabs, each line end,
/// each other char alone.
fn split_tokens(text: &str) -> Vec<&str> {
    #[derive(PartialEq, Clone, Copy)]
    enum Class {
        Word,
        Space,
        Other,
    }
    let class = |c: char| match c {
        c if c.is_alphanumeric() || c == '_' => Class::Word,
        ' ' | '\t' => Class::Space,
        _ => Class::Other,
    };
    let mut out = Vec::new();
    let mut start = 0;
    let mut last = None;
    for (at, c) in text.char_indices() {
        let k = class(c);
        if at > start && (Some(k) != last || k == Class::Other) {
            out.push(&text[start..at]);
            start = at;
        }
        last = Some(k);
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

/// The three chunks merged token by token, git's rule at a finer grain: edits that leave a
/// token between them both stand. With whether both sides edited one base line (words) or only
/// different ones (lines); `None` when edits touch.
fn tokens(base: &str, ours: &str, theirs: &str) -> Option<(String, bool)> {
    let (b, o, t) = (split_tokens(base), split_tokens(ours), split_tokens(theirs));
    let tk = Tokens::new(&b, &o, &t);
    let changes = lines::merge(&tk);
    if changes.iter().any(|c| c.mode == Mode::Conflict) {
        return None;
    }
    let mut out = String::with_capacity(ours.len() + theirs.len());
    let mut at = 0;
    // Base line of each base token boundary.
    let mut line_of = Vec::with_capacity(b.len() + 1);
    let mut line = 0;
    for token in &b {
        line_of.push(line);
        line += usize::from(*token == "\n");
    }
    line_of.push(line);
    let (mut mine, mut yours) = (HashSet::new(), HashSet::new());
    for c in &changes {
        out.extend(o[at..c.ours.start].iter().copied());
        match c.mode {
            Mode::Theirs => out.extend(t[c.theirs.clone()].iter().copied()),
            _ => out.extend(o[c.ours.clone()].iter().copied()),
        }
        at = c.ours.end;
        let set = match c.mode {
            Mode::Ours => &mut mine,
            Mode::Theirs => &mut yours,
            _ => continue,
        };
        // An edit's base lines run to the one its last token sits on (a line end belongs to
        // the line it ends).
        let end = if c.base.is_empty() {
            line_of[c.base.start]
        } else {
            line_of[c.base.end - 1]
        };
        set.extend(line_of[c.base.start]..=end);
    }
    out.extend(o[at..].iter().copied());
    let words = mine.intersection(&yours).next().is_some();
    Some((out, words))
}

// ---- both sides added items ---------------------------------------------------------------

/// The node kinds whose children may be added in any order: a file's items, a body's
/// members, a list's entries.
fn containers(language: Language) -> &'static [&'static str] {
    match language {
        Language::Rust => &[
            "source_file",
            "declaration_list",
            "field_declaration_list",
            "enum_variant_list",
            "array_expression",
            "field_initializer_list",
            "use_list",
        ],
        Language::Go => &[
            "source_file",
            "field_declaration_list",
            "literal_value",
            "import_spec_list",
            "const_declaration",
            "var_declaration",
            "interface_type",
        ],
        Language::TypeScript | Language::Tsx | Language::JavaScript => &[
            "program",
            "class_body",
            "object",
            "array",
            "object_type",
            "interface_body",
            "enum_body",
            "named_imports",
            "export_clause",
        ],
        Language::Json => &["document", "object", "array"],
        Language::Yaml => &[
            "block_mapping",
            "block_sequence",
            "flow_mapping",
            "flow_sequence",
        ],
        Language::Php => &[
            "program",
            "declaration_list",
            "array_creation_expression",
            "enum_declaration_list",
        ],
        Language::Markdown => &["document", "section", "list"],
        Language::Html | Language::Bash => &[],
    }
}

/// The container `range` of `text` adds whole children to, when it is exactly a run of one
/// container's children; a program's statements other than imports and exports run in order,
/// so they never count.
fn items<'t>(language: Language, text: &'t Text<'_>, range: &Range<usize>) -> Option<Node<'t>> {
    let bytes = text.bytes(range);
    let chunk = &text.text[bytes.clone()];
    let lead = chunk.len() - chunk.trim_start().len();
    let (s, e) = (bytes.start + lead, bytes.start + chunk.trim_end().len());
    if s >= e {
        return None;
    }
    let root = text.tree.as_ref()?.root_node();
    let mut first = root.descendant_for_byte_range(s, s)?;
    while let Some(p) = first.parent() {
        if p.start_byte() == s && p.end_byte() <= e && p.id() != root.id() {
            first = p;
        } else {
            break;
        }
    }
    let parent = first.parent()?;
    if !containers(language).contains(&parent.kind()) {
        return None;
    }
    let sequential = matches!(parent.kind(), "program");
    let mut node = first;
    loop {
        if node.is_named() && sequential {
            let k = node.kind();
            if k.ends_with("_statement") && k != "export_statement" && k != "import_statement" {
                return None;
            }
        }
        if node.end_byte() >= e {
            break;
        }
        node = node.next_sibling()?;
    }
    (node.end_byte() == e).then_some(parent)
}

/// Both sides inserted items at one place of one container (the base had nothing there but
/// blank lines): ours' then theirs', and — for a list whose last entry takes no separator —
/// ours' with a comma after its last entry.
fn both_added(
    language: Language,
    texts: &[Text<'_>; 3],
    r: &super::Region,
    base: &str,
    ours: &str,
    theirs: &str,
) -> Vec<String> {
    if !base.trim().is_empty() || ours.trim().is_empty() || theirs.trim().is_empty() {
        return Vec::new();
    }
    let (Some(a), Some(b)) = (
        items(language, &texts[1], &r.ours),
        items(language, &texts[2], &r.theirs),
    ) else {
        return Vec::new();
    };
    if a.kind() != b.kind() {
        return Vec::new();
    }
    let mut ours = ours.to_owned();
    if !ours.ends_with('\n') {
        ours.push('\n');
    }
    // Items set apart by a blank line (functions in a file) keep theirs apart from ours too.
    let apart = r.ours.start > 0 && texts[1].lines[r.ours.start - 1].trim().is_empty();
    let gap = if apart && !ours.ends_with("\n\n") && !theirs.starts_with('\n') {
        "\n"
    } else {
        ""
    };
    let mut out = vec![format!("{ours}{gap}{theirs}")];
    let body = ours.trim_end();
    if !body.ends_with(',') {
        let tail = &ours[body.len()..];
        out.push(format!("{body},{tail}{gap}{theirs}"));
    }
    out
}
