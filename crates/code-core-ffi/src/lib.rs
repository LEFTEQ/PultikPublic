//! code-core's C ABI (workbench W13, WP3b): what Pultík's `Packages/CodeCore` calls, so the
//! Swift app and the Rust editor run one implementation of highlighting, symbols, search and
//! the diff model. `include/code_core.h` is generated from this crate by cbindgen (`cargo
//! xtask code-core-header`, `--check` for drift); its preamble states the contract.
//!
//! - Plain data only: `#[repr(C)]` structs of integers, `CodeCoreStr` (UTF-8 pointer and byte
//!   length) and arrays as pointer and count. Handles are opaque.
//! - Every result is owned by one allocation the caller frees with its `*_free`; pointers
//!   inside it borrow from it ([`owned`]).
//! - Every entry point runs inside [`call`]: a panic becomes [`CODE_CORE_PANICKED`] with its
//!   message, never an unwind into Swift. Pultík's release builds use the `ffi-release`
//!   profile (release, but unwinding) so this holds there too; under `panic = "abort"` a
//!   panic would end the process instead.
//! - Positions leave as UTF-16 code units ([`utf16`]); the core counts bytes.

use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub mod diff;
pub mod search;
pub mod symbols;
pub mod syntax;

/// What a call answered: CODE_CORE_OK or why not.
pub type CodeCoreStatus = i32;
/// The call answered; its out parameters are set.
pub const CODE_CORE_OK: CodeCoreStatus = 0;
/// The core refused (a query that does not compile against its grammar, a parse that gave
/// up); the message says why.
pub const CODE_CORE_FAILED: CodeCoreStatus = 1;
/// The core panicked: caught here, the message is the panic's.
pub const CODE_CORE_PANICKED: CodeCoreStatus = 2;
/// An argument was unusable: a null pointer, text that is not UTF-8, an unknown code.
pub const CODE_CORE_INVALID: CodeCoreStatus = 3;

/// No number: a line a side does not have, a fragment line, no language.
pub const CODE_CORE_NONE: u32 = 0xFFFF_FFFF;

/// UTF-8 text by pointer and byte length (never NUL-terminated). In an argument the caller
/// owns it for the call; in a result it borrows from that result. `ptr` may be null when
/// `len` is 0.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CodeCoreStr {
    pub ptr: *const u8,
    pub len: usize,
}

impl CodeCoreStr {
    /// A result's view of `s`, valid while `s` is neither dropped nor changed.
    fn of(s: &str) -> Self {
        Self {
            ptr: s.as_ptr(),
            len: s.len(),
        }
    }

    /// The caller's text.
    ///
    /// # Safety
    /// `ptr` is null with `len` 0, or valid for `len` bytes for the call.
    unsafe fn bytes<'a>(self) -> Result<&'a [u8], Failure> {
        match (self.ptr.is_null(), self.len) {
            (true, 0) => Ok(&[]),
            (true, _) => Err(Failure::Invalid("a null text with a length")),
            // SAFETY: per this function's contract.
            (false, len) => Ok(unsafe { std::slice::from_raw_parts(self.ptr, len) }),
        }
    }

    /// The caller's text as UTF-8.
    ///
    /// # Safety
    /// As [`CodeCoreStr::bytes`].
    unsafe fn text<'a>(self) -> Result<&'a str, Failure> {
        // SAFETY: per this function's contract.
        std::str::from_utf8(unsafe { self.bytes() }?)
            .map_err(|_| Failure::Invalid("text is not UTF-8"))
    }
}

/// A list of texts (paths, import candidates).
#[repr(C)]
pub struct CodeCoreStrings {
    pub items: *const CodeCoreStr,
    pub count: usize,
}

/// A list of numbers (specificities, row starts).
#[repr(C)]
pub struct CodeCoreNumbers {
    pub values: *const u32,
    pub count: usize,
}

/// Why a call did not answer, before it becomes a status and a message.
#[derive(Debug)]
pub(crate) enum Failure {
    Core(String),
    Invalid(&'static str),
}

/// Run one entry point: a panic or a failure becomes its status, and its message goes to
/// `error` when the caller asked for one.
pub(crate) fn call(
    error: *mut *mut c_char,
    f: impl FnOnce() -> Result<(), Failure>,
) -> CodeCoreStatus {
    let (status, message) = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => (CODE_CORE_OK, None),
        Ok(Err(Failure::Core(message))) => (CODE_CORE_FAILED, Some(message)),
        Ok(Err(Failure::Invalid(why))) => (CODE_CORE_INVALID, Some(why.to_owned())),
        Err(payload) => {
            let message = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "a panic without a message".to_owned());
            (CODE_CORE_PANICKED, Some(message))
        }
    };
    if !error.is_null() {
        let raw = message.map_or(std::ptr::null_mut(), |m| {
            CString::new(m.replace('\0', " "))
                .expect("NULs replaced")
                .into_raw()
        });
        // SAFETY: the caller passes null or a pointer it owns for the call.
        unsafe { *error = raw };
    }
    status
}

/// Write `value` to the caller's out parameter.
///
/// # Safety
/// `out` is null (refused) or valid for a write.
pub(crate) unsafe fn put<T>(out: *mut T, value: T) -> Result<(), Failure> {
    if out.is_null() {
        return Err(Failure::Invalid("a null out parameter"));
    }
    // SAFETY: per this function's contract.
    unsafe { out.write(value) };
    Ok(())
}

/// A caller's array.
///
/// # Safety
/// `ptr` is null with `count` 0, or valid for `count` elements for the call.
pub(crate) unsafe fn slice<'a, T>(ptr: *const T, count: usize) -> Result<&'a [T], Failure> {
    match (ptr.is_null(), count) {
        (true, 0) => Ok(&[]),
        (true, _) => Err(Failure::Invalid("a null array with a count")),
        // SAFETY: per this function's contract.
        (false, n) => Ok(unsafe { std::slice::from_raw_parts(ptr, n) }),
    }
}

/// A caller's handle.
///
/// # Safety
/// `handle` is null (refused) or a live handle this crate made, used by one thread.
pub(crate) unsafe fn handle<'a, T>(handle: *mut T) -> Result<&'a mut T, Failure> {
    // SAFETY: per this function's contract.
    unsafe { handle.as_mut() }.ok_or(Failure::Invalid("a null handle"))
}

/// Results: the C view first, the data its pointers borrow from after it, in one allocation.
/// The caller holds a pointer to the view; `*_free` turns it back into the box.
pub(crate) mod owned {
    #[repr(C)]
    struct Owned<V, D> {
        view: V,
        data: D,
    }

    /// Box `data`, build the view over its final home, and hand out the view.
    pub(crate) fn into_raw<V, D>(data: D, view: impl FnOnce(&D) -> V) -> *mut V {
        let mut owned = Box::new(Owned {
            view: std::mem::MaybeUninit::<V>::uninit(),
            data,
        });
        owned.view.write(view(&owned.data));
        // `Owned<MaybeUninit<V>, D>` and `Owned<V, D>` share a layout, the view at offset 0.
        Box::into_raw(owned).cast::<V>()
    }

    /// Drop a result [`into_raw`] made with the same `D`; null is a no-op.
    ///
    /// # Safety
    /// `view` is null or came from [`into_raw::<V, D>`] and is not used again.
    pub(crate) unsafe fn free<V, D>(view: *mut V) {
        if !view.is_null() {
            // SAFETY: per this function's contract: the view is the box's first field.
            drop(unsafe { Box::from_raw(view.cast::<Owned<V, D>>()) });
        }
    }
}

/// UTF-16 positions from the core's bytes.
pub(crate) mod utf16 {
    /// A forward byte → UTF-16 offset map over one text; a step back starts over.
    #[derive(Default)]
    pub(crate) struct Cursor {
        byte: usize,
        unit: usize,
    }

    impl Cursor {
        pub(crate) fn at(&mut self, text: &str, byte: usize) -> usize {
            let byte = byte.min(text.len());
            if byte < self.byte {
                *self = Self::default();
            }
            self.unit += text
                .get(self.byte..byte)
                .map_or(0, |s| s.encode_utf16().count());
            self.byte = byte;
            self.unit
        }
    }
}

fn texts(strings: &[String]) -> Vec<CodeCoreStr> {
    strings.iter().map(|s| CodeCoreStr::of(s)).collect()
}

/// Free a message a failed call wrote to `error`; null is a no-op.
///
/// # Safety
/// `message` is null or came from this library's `error` out parameter, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_string_free(message: *mut c_char) {
    if !message.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { CString::from_raw(message) });
    }
}

/// Free a list of texts; null is a no-op.
///
/// # Safety
/// `strings` is null or a result of this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_strings_free(strings: *mut CodeCoreStrings) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreStrings, (Vec<String>, Vec<CodeCoreStr>)>(strings) }
}

/// Free a list of numbers; null is a no-op.
///
/// # Safety
/// `numbers` is null or a result of this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_numbers_free(numbers: *mut CodeCoreNumbers) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreNumbers, Vec<u32>>(numbers) }
}

pub(crate) fn strings_result(strings: Vec<String>) -> *mut CodeCoreStrings {
    let views = texts(&strings);
    owned::into_raw((strings, views), |(_, views)| CodeCoreStrings {
        items: views.as_ptr(),
        count: views.len(),
    })
}

pub(crate) fn numbers_result(values: Vec<u32>) -> *mut CodeCoreNumbers {
    owned::into_raw(values, |values| CodeCoreNumbers {
        values: values.as_ptr(),
        count: values.len(),
    })
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    pub(crate) fn s(text: &str) -> CodeCoreStr {
        CodeCoreStr::of(text)
    }

    /// A result's text, copied.
    pub(crate) fn read(s: CodeCoreStr) -> String {
        // SAFETY: results hand out valid UTF-8 views.
        String::from_utf8(unsafe { s.bytes() }.expect("valid").to_vec()).expect("UTF-8")
    }

    pub(crate) fn message(error: *mut c_char) -> Option<String> {
        if error.is_null() {
            return None;
        }
        // SAFETY: a message from `call`.
        let text = unsafe { std::ffi::CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: freed once.
        unsafe { code_core_string_free(error) };
        Some(text)
    }

    #[test]
    fn a_panic_becomes_a_status_and_its_message() {
        let mut error = std::ptr::null_mut();
        let status = call(&mut error, || panic!("boom at the boundary"));
        assert_eq!(status, CODE_CORE_PANICKED);
        assert_eq!(message(error).as_deref(), Some("boom at the boundary"));
        let status = call(&mut error, || Err(Failure::Invalid("why")));
        assert_eq!(
            (status, message(error).as_deref()),
            (CODE_CORE_INVALID, Some("why"))
        );
        assert_eq!(call(&mut error, || Ok(())), CODE_CORE_OK);
        assert!(error.is_null());
        assert_eq!(
            call(std::ptr::null_mut(), || panic!("no one asked")),
            CODE_CORE_PANICKED
        );
    }

    #[test]
    fn utf16_positions_count_units_not_bytes() {
        let text = "aé漢😀b";
        let mut cursor = utf16::Cursor::default();
        let units: Vec<usize> = text
            .char_indices()
            .map(|(at, _)| cursor.at(text, at))
            .collect();
        assert_eq!(units, [0, 1, 2, 3, 5]);
        assert_eq!(cursor.at(text, 1), 1, "a step back starts over");
    }
}
