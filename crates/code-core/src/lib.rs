//! The code core: the text model every code surface draws from (workbench W13). It is
//! renderer-free and platform-free: no font, pixel or GPU, and it builds on Linux. Pultík
//! reads it through `crates/code-core-ffi`'s C ABI (`Packages/CodeCore`).
//!
//! - [`Buffer`]: the text as a `ropey` rope with a revision. Every edit returns an [`Edit`]
//!   with the char, byte and (row, byte column) points tree-sitter's `InputEdit` needs.
//! - [`Editor`]: the editing model over a [`Buffer`]: multi-cursor [`Command`]s at every
//!   [`Selection`] at once, one revision and a list of [`Edit`]s per command, and a
//!   [`History`] whose undo and redo restore text and selections. See [`cursor`] for where a
//!   caret stops and how selections merge.
//! - [`search_replace`]: every regex match as char ranges, and replace all or next through
//!   an [`Editor`] as one undoable transaction.
//! - [`LineIndex`]: the aggregate line index (each line's bytes and display width, in
//!   chunks that cache their visual-row sum for the current wrap). See [`lines`].
//! - [`Layout`]: viewport-first layout: only the visible rows, into reused buffers.
//! - [`syntax`]: tree-sitter highlighting with Pultík's paint rule over the vendored queries
//!   in `Apps/Pultik/Resources/Queries` (one-shot for a blob, incremental in regions for a
//!   [`Buffer`]), its spans in `theme::SyntaxRole`s, and the tags the symbol index reads.
//! - [`symbols`]: definitions and references per repo@head (search-based navigation).
//! - [`search`]: the identifier under a column, the line matcher and `git grep` records.
//! - [`diff`]: unified lines, hunks, word diffs, side-by-side rows, a change set's rows and
//!   their wrap layout.
//! - [`merge`]: the three-way merge — git's line merge, then tree-sitter resolvers for the
//!   conflicts it leaves — as regions tiling the base, both sides and the result.
//!
//! The public API is plain data (indices, byte ranges, owned strings) so a C ABI can carry
//! it to Pultík unchanged. Columns: a tab runs to the next multiple of [`TAB`], wide chars and emoji take two,
//! combining marks none ([`width_at`]). Lines end at `\n` only, as tree-sitter's rows do.

pub mod buffer;
pub mod cursor;
pub mod diff;
pub mod editor;
pub mod layout;
pub mod lines;
pub mod merge;
pub mod search;
pub mod search_replace;
pub mod symbols;
pub mod syntax;

pub use buffer::{Buffer, Edit, Point, Pos, TextChunks};
pub use cursor::{Selection, Selections};
pub use editor::{Command, Editor, History, Motion};
pub use layout::{Layout, Row, Viewport};
pub use lines::{LineIndex, LineInfo, MIN_WRAP, Placed, Placer, TAB, width_at, wrap_rows};
pub use syntax::{Language, LineTokens, Span, Syntax, SyntaxError, Tag, TagRole, TokenRun};

#[cfg(test)]
mod tests;
