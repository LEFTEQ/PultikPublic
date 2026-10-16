//! A screen of monospaced cells, as the renderer draws it: the neutral cell model and the
//! [`CellFrame`] a producer (a terminal emulator's mirror) implements. The renderer reads a
//! frame through the trait only, so it never depends on whoever produced it.

use std::fmt::Debug;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rgb(pub u8, pub u8, pub u8);

/// Cell attribute bits for [`Cell::flags`].
pub mod flags {
    pub const BOLD: u16 = 1;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const STRIKE: u16 = 1 << 3;
    pub const INVERSE: u16 = 1 << 4;
    pub const FAINT: u16 = 1 << 5;
    pub const INVISIBLE: u16 = 1 << 6;
    pub const BLINK: u16 = 1 << 7;
    /// Left half of a double-width character; the next cell is its spacer.
    pub const WIDE: u16 = 1 << 8;
    pub const WIDE_SPACER: u16 = 1 << 9;
    /// Inside the selection.
    pub const SELECTED: u16 = 1 << 10;
    /// Inside a search match; [`MATCH_CURRENT`] also marks the current one.
    pub const MATCH: u16 = 1 << 11;
    pub const MATCH_CURRENT: u16 = 1 << 12;
}

/// One cell with colours already resolved through the palette and inverse applied.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Cell {
    /// The grapheme cluster; empty for a blank cell.
    pub text: String,
    pub fg: Rgb,
    pub bg: Rgb,
    pub flags: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Bar,
    Underline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub col: u16,
    pub row: u16,
    pub shape: CursorShape,
    pub visible: bool,
    pub blinking: bool,
}

/// A screen the renderer draws cell by cell, shared with it (never copied per frame).
pub trait CellFrame: Debug + Send + Sync {
    /// The colours a cell takes when it sets none: its background is not drawn.
    fn default_fg(&self) -> Rgb;
    fn default_bg(&self) -> Rgb;
    fn cursor(&self) -> Cursor;
    /// The cursor colour the screen's program set, if any.
    fn cursor_color(&self) -> Option<Rgb>;
    /// Rows top to bottom.
    fn row_count(&self) -> usize;
    /// Row `row`'s cells, left to right.
    fn row(&self, row: usize) -> &[Cell];
}

/// A plain owned screen, for a producer with no frame type of its own (a test, a preview).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screen {
    pub default_fg: Rgb,
    pub default_bg: Rgb,
    pub cursor: Cursor,
    pub cursor_color: Option<Rgb>,
    pub rows: Vec<Vec<Cell>>,
}

impl CellFrame for Screen {
    fn default_fg(&self) -> Rgb {
        self.default_fg
    }
    fn default_bg(&self) -> Rgb {
        self.default_bg
    }
    fn cursor(&self) -> Cursor {
        self.cursor
    }
    fn cursor_color(&self) -> Option<Rgb> {
        self.cursor_color
    }
    fn row_count(&self) -> usize {
        self.rows.len()
    }
    fn row(&self, row: usize) -> &[Cell] {
        &self.rows[row]
    }
}
