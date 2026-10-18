//! Code views into the code op: a theme as the code op draws it ([`CodeColors`]) and an
//! editor viewport's rows coloured by their syntax spans (workbench WP3, AC2). Diffs draw
//! through `diff_view` (vt-7887). The rows and highlights are code-core's; the colours and
//! faces are a `crates/theme` theme's. Colours tint glyphs by column and never split shaping;
//! a role the theme draws bold or italic picks its face (`code.rs`).

use canvas_draw::{CodeRows, Rgba};
use code_core::syntax::{self, Span};
use code_core::{Layout, Row};
use theme::{Palette, SyntaxRole, Theme};

fn rgba(c: theme::Rgba) -> Rgba {
    Rgba::new(c.r, c.g, c.b, c.a)
}

/// A theme as the code op draws it: every role's colour and face, and the code surface's
/// palette.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CodeColors {
    roles: [Rgba; SyntaxRole::COUNT],
    faces: [u8; SyntaxRole::COUNT],
    palette: Palette,
}

impl CodeColors {
    pub fn new(theme: &Theme) -> Self {
        Self {
            roles: SyntaxRole::ALL.map(|r| rgba(theme.syntax(r).color)),
            faces: SyntaxRole::ALL.map(|r| {
                let style = theme.syntax(r);
                u8::from(style.bold) | u8::from(style.italic) << 1
            }),
            palette: theme.palette,
        }
    }

    pub fn role(&self, role: SyntaxRole) -> Rgba {
        self.roles[role as usize]
    }

    /// The role's face: a `ColorSpan::style` (0 regular, 1 bold, 2 italic, 3 both).
    pub fn face(&self, role: SyntaxRole) -> u8 {
        self.faces[role as usize]
    }

    /// Text outside every span.
    pub fn fg(&self) -> Rgba {
        rgba(self.palette.foreground)
    }

    pub fn background(&self) -> Rgba {
        rgba(self.palette.background)
    }

    pub fn palette(&self) -> &Palette {
        &self.palette
    }
}

/// One laid-out editor row into `rows`, with its spans (sorted, absolute bytes) coloured and
/// in their faces.
pub fn push_layout_row(
    rows: &mut CodeRows,
    layout: &Layout,
    row: &Row,
    spans: &[Span],
    colors: &CodeColors,
) {
    rows.push_row(layout.text(row), layout.cols(row));
    syntax::row_spans(layout, row, spans, |a, b, role| {
        rows.push_styled_span(a, b, colors.role(role), colors.face(role));
    });
}
