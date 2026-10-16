//! The one static library Pultík and its Foundation harness link (`libpultik_ffi.a`): every Rust
//! C ABI the app calls, each its own rlib with its own generated header — `code_core.h`
//! (`code-core-ffi`) and `timeline.h` (`timeline-ffi`). Two archives would each carry a copy of
//! std and of every shared crate; one archive carries one. `cargo xtask umbrella-check` proves
//! every declared function is exported, per profile and arch slice.

pub use code_core_ffi;
pub use timeline_ffi;
