//! Pultík's code tests on the Rust core (workbench AC2): each module ports one Swift suite
//! from `Apps/Pultik/Tests/` with the same inputs and the same expected outputs, then adds the
//! Rust core's own cases (incremental highlighting, side-by-side diffs).

mod diff;
mod search;
mod symbols;
mod syntax;
