//! Code themes from the one definition file both apps read (workbench W13).
//!
//! `Packages/Theme/Sources/CodeThemes/Resources/themes.json` is the only definition: the Swift
//! package bundles it as the CodeThemes resource and this crate compiles the same file in
//! ([`DEFINITION`]), so the two never drift. A theme is a [`Palette`] for code surfaces plus a
//! [`SyntaxStyle`] per [`SyntaxRole`]; a missing or unknown role fails [`parse`], as it fails
//! the Swift decoder. A code surface holds a [`ThemeStore`] and repaints when its
//! [`ThemeStore::generation`] moves.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::OnceLock;

use serde::{Deserialize, Deserializer};

/// The definition file, compiled in.
pub const DEFINITION: &str =
    include_str!("../../../Packages/Theme/Sources/CodeThemes/Resources/themes.json");

/// The house theme, what a store opens on with no saved choice.
pub const DEFAULT_ID: &str = "adeberry-amber";

/// A straight-alpha sRGB colour, each channel in `0.0..=1.0`: the draw layer's own layout, so
/// converting is a field copy.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    /// `#RRGGBB` or `#RRGGBBAA`.
    pub fn parse_hex(text: &str) -> Option<Self> {
        let digits = text.strip_prefix('#')?;
        if !(digits.len() == 6 || digits.len() == 8)
            || !digits.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return None;
        }
        let value = u32::from_str_radix(digits, 16).ok()?;
        let rgba = if digits.len() == 6 {
            value << 8 | 0xff
        } else {
            value
        };
        let channel = |shift: u32| ((rgba >> shift) & 0xff) as f32 / 255.0;
        Some(Self {
            r: channel(24),
            g: channel(16),
            b: channel(8),
            a: channel(0),
        })
    }

    pub fn to_array(self) -> [f32; 4] {
        [self.r, self.g, self.b, self.a]
    }
}

impl<'de> Deserialize<'de> for Rgba {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Rgba::parse_hex(&text)
            .ok_or_else(|| serde::de::Error::custom(format!("{text} is not #RRGGBB or #RRGGBBAA")))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    Dark,
    Light,
}

/// The colours of a code surface other than its syntax.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Palette {
    pub background: Rgba,
    pub foreground: Rgba,
    /// The gutter's own fill (context lines).
    pub gutter: Rgba,
    /// Gutter figures and other quiet text (a hunk header).
    pub line_number: Rgba,
    pub current_line: Rgba,
    pub selection: Rgba,
    pub cursor: Rgba,
    /// A changed line's wash, and the changed words inside it.
    pub added_line: Rgba,
    pub removed_line: Rgba,
    pub added_word: Rgba,
    pub removed_word: Rgba,
    /// A changed line's gutter fill, drawn over its wash.
    pub added_gutter: Rgba,
    pub removed_gutter: Rgba,
    /// The ± glyph, a file's A / D letter and its +n −n counts.
    pub added_mark: Rgba,
    pub removed_mark: Rgba,
    /// A hunk separator's band, and a file header's band.
    pub hunk: Rgba,
    pub header: Rgba,
    pub find_match: Rgba,
    /// Hairlines: under a file header, between panes.
    pub border: Rgba,
    /// A language server's diagnostics: the squiggle and the gutter mark (a hint draws in
    /// `info`, dimmed).
    pub error: Rgba,
    pub warning: Rgba,
    pub info: Rgba,
}

/// What a highlighted run means; the highlighter maps its captures here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyntaxRole {
    Keyword,
    String,
    Escape,
    Function,
    Type,
    Variable,
    Builtin,
    Parameter,
    Property,
    Number,
    Constant,
    Comment,
    Operator,
    Punctuation,
    Tag,
    Attribute,
    Module,
    Heading,
    Literal,
    Emphasis,
    Strong,
    Link,
}

impl SyntaxRole {
    pub const COUNT: usize = 22;
    /// Every role, in declaration order (`role as usize` indexes it).
    pub const ALL: [SyntaxRole; Self::COUNT] = [
        Self::Keyword,
        Self::String,
        Self::Escape,
        Self::Function,
        Self::Type,
        Self::Variable,
        Self::Builtin,
        Self::Parameter,
        Self::Property,
        Self::Number,
        Self::Constant,
        Self::Comment,
        Self::Operator,
        Self::Punctuation,
        Self::Tag,
        Self::Attribute,
        Self::Module,
        Self::Heading,
        Self::Literal,
        Self::Emphasis,
        Self::Strong,
        Self::Link,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SyntaxStyle {
    pub color: Rgba,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
}

/// Where a theme's values come from, and under which terms.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provenance {
    pub source: String,
    pub licence: String,
    #[serde(default)]
    pub notes: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub appearance: Appearance,
    pub provenance: Provenance,
    pub palette: Palette,
    syntax: [SyntaxStyle; SyntaxRole::COUNT],
}

impl Theme {
    pub fn syntax(&self, role: SyntaxRole) -> SyntaxStyle {
        self.syntax[role as usize]
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThemeError {
    /// Not the definition's shape: bad JSON, a bad colour, an unknown or missing palette role,
    /// an unknown syntax role.
    Parse(String),
    MissingSyntax {
        theme: String,
        role: SyntaxRole,
    },
    DuplicateId(String),
    UnknownTheme(String),
}

impl fmt::Display for ThemeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Parse(message) => write!(f, "theme definition: {message}"),
            Self::MissingSyntax { theme, role } => write!(f, "theme {theme}: no {role:?} style"),
            Self::DuplicateId(id) => write!(f, "theme {id} is defined twice"),
            Self::UnknownTheme(id) => write!(f, "no theme {id}"),
        }
    }
}

impl std::error::Error for ThemeError {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DefinitionFile {
    #[serde(rename = "about")]
    _about: String,
    themes: Vec<ThemeFile>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ThemeFile {
    id: String,
    name: String,
    appearance: Appearance,
    provenance: Provenance,
    palette: Palette,
    syntax: BTreeMap<SyntaxRole, SyntaxStyle>,
}

/// Every theme of a definition, in its order.
pub fn parse(json: &str) -> Result<Vec<Theme>, ThemeError> {
    let file: DefinitionFile =
        serde_json::from_str(json).map_err(|e| ThemeError::Parse(e.to_string()))?;
    let mut themes: Vec<Theme> = Vec::with_capacity(file.themes.len());
    for theme in file.themes {
        if themes.iter().any(|t| t.id == theme.id) {
            return Err(ThemeError::DuplicateId(theme.id));
        }
        let mut syntax = [SyntaxStyle::default(); SyntaxRole::COUNT];
        for role in SyntaxRole::ALL {
            syntax[role as usize] =
                *theme
                    .syntax
                    .get(&role)
                    .ok_or_else(|| ThemeError::MissingSyntax {
                        theme: theme.id.clone(),
                        role,
                    })?;
        }
        themes.push(Theme {
            id: theme.id,
            name: theme.name,
            appearance: theme.appearance,
            provenance: theme.provenance,
            palette: theme.palette,
            syntax,
        });
    }
    Ok(themes)
}

/// The shipped themes, parsed once. The crate's tests prove [`DEFINITION`] parses, so a panic
/// here is a broken build, never a user's state.
pub fn themes() -> &'static [Theme] {
    static THEMES: OnceLock<Vec<Theme>> = OnceLock::new();
    THEMES.get_or_init(|| parse(DEFINITION).unwrap_or_else(|e| panic!("{e}")))
}

pub fn by_id(id: &str) -> Option<&'static Theme> {
    themes().iter().find(|t| t.id == id)
}

/// The house theme ([`DEFAULT_ID`]).
pub fn default_theme() -> &'static Theme {
    by_id(DEFAULT_ID).unwrap_or_else(|| panic!("{DEFAULT_ID} is not in the definition"))
}

/// The selected theme and a generation that moves on every switch: a surface caches the
/// generation it painted with and repaints when it differs. Persisting the choice is the
/// owner's job.
#[derive(Debug, Clone)]
pub struct ThemeStore {
    theme: &'static Theme,
    generation: u64,
}

impl ThemeStore {
    /// Opens on `saved`, or on [`DEFAULT_ID`] when it is absent or unknown (a hand edit, a
    /// theme a newer build added).
    pub fn new(saved: Option<&str>) -> Self {
        Self {
            theme: saved.and_then(by_id).unwrap_or_else(default_theme),
            generation: 0,
        }
    }

    pub fn theme(&self) -> &'static Theme {
        self.theme
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Switches to `id`: `Ok(true)` and a new generation, `Ok(false)` when it is already shown.
    pub fn select(&mut self, id: &str) -> Result<bool, ThemeError> {
        let next = by_id(id).ok_or_else(|| ThemeError::UnknownTheme(id.to_owned()))?;
        if std::ptr::eq(next, self.theme) {
            return Ok(false);
        }
        self.theme = next;
        self.generation += 1;
        Ok(true)
    }
}

impl Default for ThemeStore {
    fn default() -> Self {
        Self::new(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one definition file loads every shipped theme, each complete. Codex Dark's own
    /// values and the full list are `tests/private_definition.rs`'s: the public mirror's
    /// definition leaves Codex Dark out and never publishes that file.
    #[test]
    fn the_definition_loads_every_theme_with_every_role() {
        let ids: Vec<&str> = themes().iter().map(|t| t.id.as_str()).collect();
        for id in [
            DEFAULT_ID,
            "one-dark",
            "github-dark",
            "one-light",
            "tokyo-night",
        ] {
            assert!(ids.contains(&id), "{id} in {ids:?}");
        }
        for theme in themes() {
            let p = &theme.palette;
            for (name, colour) in [
                ("background", p.background),
                ("foreground", p.foreground),
                ("gutter", p.gutter),
                ("lineNumber", p.line_number),
                ("currentLine", p.current_line),
                ("selection", p.selection),
                ("cursor", p.cursor),
                ("addedLine", p.added_line),
                ("removedLine", p.removed_line),
                ("addedWord", p.added_word),
                ("removedWord", p.removed_word),
                ("addedGutter", p.added_gutter),
                ("removedGutter", p.removed_gutter),
                ("addedMark", p.added_mark),
                ("removedMark", p.removed_mark),
                ("hunk", p.hunk),
                ("header", p.header),
                ("findMatch", p.find_match),
                ("border", p.border),
            ] {
                assert!(colour.a > 0.0, "{} {name}", theme.id);
            }
            for role in SyntaxRole::ALL {
                assert_eq!(
                    theme.syntax(role).color.a,
                    1.0,
                    "{} {role:?}: syntax is opaque",
                    theme.id
                );
            }
            assert!(!theme.provenance.source.is_empty() && !theme.provenance.licence.is_empty());
        }
        assert_eq!(by_id("one-light").unwrap().appearance, Appearance::Light);
        assert!(by_id("cursor-dark").is_none());
        assert_eq!(default_theme().id, DEFAULT_ID);
    }

    /// The first theme's file with one edit: `edit` rewrites its JSON object.
    fn edited(edit: impl FnOnce(&mut serde_json::Value)) -> Result<Vec<Theme>, ThemeError> {
        let mut file: serde_json::Value = serde_json::from_str(DEFINITION).unwrap();
        let first = file["themes"][0].clone();
        file["themes"] = serde_json::Value::Array(vec![first]);
        edit(&mut file["themes"][0]);
        parse(&file.to_string())
    }

    /// A role the definition does not know, a missing one, a bad colour or a twice-defined id
    /// fails the whole file, as it fails the Swift decoder.
    #[test]
    fn an_incomplete_or_unknown_role_fails() {
        assert_eq!(edited(|_| {}).unwrap().len(), 1);
        let unknown = edited(|t| t["palette"]["gutterGlow"] = "#FFFFFF".into()).unwrap_err();
        assert!(
            matches!(&unknown, ThemeError::Parse(m) if m.contains("gutterGlow")),
            "{unknown}"
        );
        let missing = edited(|t| {
            t["palette"].as_object_mut().unwrap().remove("cursor");
        })
        .unwrap_err();
        assert!(
            matches!(&missing, ThemeError::Parse(m) if m.contains("cursor")),
            "{missing}"
        );
        let syntax = edited(|t| t["syntax"]["glyph"] = t["syntax"]["keyword"].clone()).unwrap_err();
        assert!(
            matches!(&syntax, ThemeError::Parse(m) if m.contains("glyph")),
            "{syntax}"
        );
        assert_eq!(
            edited(|t| {
                t["syntax"].as_object_mut().unwrap().remove("link");
            }),
            Err(ThemeError::MissingSyntax {
                theme: DEFAULT_ID.into(),
                role: SyntaxRole::Link
            })
        );
        let colour = edited(|t| t["palette"]["cursor"] = "blue".into()).unwrap_err();
        assert!(
            matches!(&colour, ThemeError::Parse(m) if m.contains("blue")),
            "{colour}"
        );

        let mut file: serde_json::Value = serde_json::from_str(DEFINITION).unwrap();
        let first = file["themes"][0].clone();
        file["themes"].as_array_mut().unwrap().push(first);
        assert_eq!(
            parse(&file.to_string()),
            Err(ThemeError::DuplicateId(DEFAULT_ID.into()))
        );
    }

    /// Switching moves the generation once per change; the shown theme or an unknown id
    /// changes nothing.
    #[test]
    fn switching_moves_the_generation() {
        let mut store = ThemeStore::default();
        assert_eq!(
            (store.theme().id.as_str(), store.generation()),
            (DEFAULT_ID, 0)
        );
        assert_eq!(store.select("one-light"), Ok(true));
        assert_eq!(
            (store.theme().id.as_str(), store.generation()),
            ("one-light", 1)
        );
        assert_eq!(store.select("one-light"), Ok(false));
        assert_eq!(
            store.select("cursor-dark"),
            Err(ThemeError::UnknownTheme("cursor-dark".into()))
        );
        assert_eq!(store.select("github-dark"), Ok(true));
        assert_eq!(
            (store.theme().id.as_str(), store.generation()),
            ("github-dark", 2)
        );
    }

    /// An unknown saved id falls back to the house theme without being an error.
    #[test]
    fn an_unknown_saved_id_opens_on_the_default() {
        assert_eq!(ThemeStore::new(Some("cursor-dark")).theme().id, DEFAULT_ID);
        assert_eq!(ThemeStore::new(Some("one-dark")).theme().id, "one-dark");
    }

    #[test]
    fn hex_parses_both_widths() {
        assert_eq!(
            Rgba::parse_hex("#3366CC80"),
            Some(Rgba {
                r: 51.0 / 255.0,
                g: 102.0 / 255.0,
                b: 204.0 / 255.0,
                a: 128.0 / 255.0
            })
        );
        assert_eq!(
            Rgba::parse_hex("#ffffff"),
            Some(Rgba {
                r: 1.0,
                g: 1.0,
                b: 1.0,
                a: 1.0
            })
        );
        for bad in ["3366CC", "#3366", "#+3366C", "#3366CC8"] {
            assert_eq!(Rgba::parse_hex(bad), None, "{bad}");
        }
    }
}
