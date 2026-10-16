//! Definitions and references per repo@head: `code_core::symbols`, Pultík's `SymbolIndex`.
//! A `CodeCoreSymbolBuilder` takes one batch of files at a time (the caller reads its mirror
//! in batches, off its actor) and is installed into the `CodeCoreSymbols` set, which keeps the
//! last `CODE_CORE_SYMBOL_CAPACITY` repo@heads.

use crate::syntax::role;
use crate::{
    CodeCoreStatus, CodeCoreStr, CodeCoreStrings, Failure, call, handle, owned, put, slice,
    strings_result,
};
use code_core::symbols::{self, CAPACITY, FILE_LIMIT, Index, Symbol, SymbolIndexes};
use std::ffi::c_char;

/// Indexes the set keeps at once, the least recently used going first.
pub const CODE_CORE_SYMBOL_CAPACITY: u32 = 2;
/// A larger file is generated or minified: it is never indexed.
pub const CODE_CORE_SYMBOL_FILE_LIMIT: u32 = 524288;
// Literals, so the header carries numbers; held to the core's own here.
const _: () = assert!(CODE_CORE_SYMBOL_CAPACITY as usize == CAPACITY);
const _: () = assert!(CODE_CORE_SYMBOL_FILE_LIMIT as usize == FILE_LIMIT);

/// The indexes of the last few repo@heads.
pub struct CodeCoreSymbols(SymbolIndexes);

/// One repo@head's index while its files come in.
pub struct CodeCoreSymbolBuilder(Index);

/// A file to index.
#[repr(C)]
pub struct CodeCoreFile {
    pub path: CodeCoreStr,
    pub text: CodeCoreStr,
}

/// A file that failed to parse, and why: it is left out of the index.
#[repr(C)]
pub struct CodeCoreFailure {
    pub path: CodeCoreStr,
    pub reason: CodeCoreStr,
}

#[repr(C)]
pub struct CodeCoreFailures {
    pub items: *const CodeCoreFailure,
    pub count: usize,
}

/// A definition or a use of a name, where it is.
#[repr(C)]
pub struct CodeCoreSymbol {
    /// `CODE_CORE_TAG_DEFINITION` or `CODE_CORE_TAG_REFERENCE`.
    pub role: u8,
    pub kind: CodeCoreStr,
    pub name: CodeCoreStr,
    pub path: CodeCoreStr,
    /// 0-based line.
    pub line: u32,
    /// The name's UTF-16 column.
    pub column: u32,
}

#[repr(C)]
pub struct CodeCoreSymbolList {
    pub symbols: *const CodeCoreSymbol,
    pub count: usize,
}

type FailuresData = (Vec<(String, String)>, Vec<CodeCoreFailure>);
type SymbolsData = (Vec<Symbol>, Vec<CodeCoreSymbol>);

/// An empty set.
///
/// # Safety
/// `out` is valid for a write. Free the set with `code_core_symbols_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_new(
    out: *mut *mut CodeCoreSymbols,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        let set = Box::into_raw(Box::new(CodeCoreSymbols(SymbolIndexes::default())));
        // SAFETY: per this function's contract.
        unsafe { put(out, set) }
    })
}

/// Free a set; null is a no-op.
///
/// # Safety
/// `symbols` is null or came from `code_core_symbols_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_free(symbols: *mut CodeCoreSymbols) {
    if !symbols.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(symbols) });
    }
}

/// An empty index to add files to.
///
/// # Safety
/// `out` is valid for a write. The builder is installed (`code_core_symbols_install`) or
/// freed (`code_core_symbol_builder_free`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbol_builder_new(
    out: *mut *mut CodeCoreSymbolBuilder,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        let builder = Box::into_raw(Box::new(CodeCoreSymbolBuilder(Index::default())));
        // SAFETY: per this function's contract.
        unsafe { put(out, builder) }
    })
}

/// Free a builder that was never installed; null is a no-op.
///
/// # Safety
/// `builder` is null or came from `code_core_symbol_builder_new`, not installed, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbol_builder_free(builder: *mut CodeCoreSymbolBuilder) {
    if !builder.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(builder) });
    }
}

/// Parse a batch of files' tags (up to four threads; files of an untagged language or past
/// `CODE_CORE_SYMBOL_FILE_LIMIT` bytes are skipped) and add them to the builder. `failed`
/// lists the files that did not parse.
///
/// # Safety
/// `builder` is live and used by one thread; `files` holds `count` files valid for the call;
/// `failed` is valid for a write. Free `failed` with `code_core_failures_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbol_builder_add(
    builder: *mut CodeCoreSymbolBuilder,
    files: *const CodeCoreFile,
    count: usize,
    failed: *mut *mut CodeCoreFailures,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (builder, files) = unsafe { (handle(builder)?, slice(files, count)?) };
        let files = files
            .iter()
            // SAFETY: per this function's contract.
            .map(|f| Ok((unsafe { f.path.text() }?, unsafe { f.text.text() }?)))
            .collect::<Result<Vec<(&str, &str)>, Failure>>()?;
        let failures: Vec<(String, String)> = builder
            .0
            .add_files(&files)
            .into_iter()
            .map(|(path, e)| (path, e.to_string()))
            .collect();
        let views = failures
            .iter()
            .map(|(path, reason)| CodeCoreFailure {
                path: CodeCoreStr::of(path),
                reason: CodeCoreStr::of(reason),
            })
            .collect();
        let result = owned::into_raw((failures, views), |(_, views): &FailuresData| {
            CodeCoreFailures {
                items: views.as_ptr(),
                count: views.len(),
            }
        });
        // SAFETY: per this function's contract.
        unsafe { put(failed, result) }
    })
}

/// Free a failure list; null is a no-op.
///
/// # Safety
/// `failures` is null or came from `code_core_symbol_builder_add`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_failures_free(failures: *mut CodeCoreFailures) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreFailures, FailuresData>(failures) }
}

/// Keep the builder's index as repo@head, replacing what the set held for it and dropping
/// the least recently used past capacity. The builder is consumed, on failure too.
///
/// # Safety
/// `symbols` is live and used by one thread; `builder` came from
/// `code_core_symbol_builder_new` and is not used again; texts are valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_install(
    symbols: *mut CodeCoreSymbols,
    repo: CodeCoreStr,
    head: CodeCoreStr,
    builder: *mut CodeCoreSymbolBuilder,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    // SAFETY: per this function's contract: the builder is ours from here, whatever happens.
    let builder = (!builder.is_null()).then(|| unsafe { Box::from_raw(builder) });
    call(error, || {
        let mut index = builder.ok_or(Failure::Invalid("a null builder"))?.0;
        // SAFETY: per this function's contract.
        let (symbols, repo, head) = unsafe { (handle(symbols)?, repo.text()?, head.text()?) };
        index.compact();
        symbols.0.install(repo, head, index);
        Ok(())
    })
}

/// Whether the set holds repo@head.
///
/// # Safety
/// `symbols` is live and used by one thread; texts are valid for the call; `built` is valid
/// for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_is_built(
    symbols: *mut CodeCoreSymbols,
    repo: CodeCoreStr,
    head: CodeCoreStr,
    built: *mut bool,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (symbols, repo, head) = unsafe { (handle(symbols)?, repo.text()?, head.text()?) };
        // SAFETY: per this function's contract.
        unsafe { put(built, symbols.0.is_built(repo, head)) }
    })
}

/// Drop every index (the app released what showed them).
///
/// # Safety
/// `symbols` is live and used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_purge(
    symbols: *mut CodeCoreSymbols,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        unsafe { handle(symbols) }?.0.purge();
        Ok(())
    })
}

/// Where `name` is defined in repo@head, best first: in `path` itself, in a file `imports`
/// names (or an imported directory), in `path`'s directory, then the rest; empty when the
/// set does not hold repo@head.
///
/// # Safety
/// `symbols` is live and used by one thread; texts and `imports` (`import_count` texts) are
/// valid for the call; `out` is valid for a write. Free the result with
/// `code_core_symbol_list_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_definitions(
    symbols: *mut CodeCoreSymbols,
    repo: CodeCoreStr,
    head: CodeCoreStr,
    name: CodeCoreStr,
    path: CodeCoreStr,
    imports: *const CodeCoreStr,
    import_count: usize,
    out: *mut *mut CodeCoreSymbolList,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (symbols, repo, head, name, path) = unsafe {
            (
                handle(symbols)?,
                repo.text()?,
                head.text()?,
                name.text()?,
                path.text()?,
            )
        };
        // SAFETY: per this function's contract.
        let imports = unsafe { texts(imports, import_count) }?;
        let found = symbols.0.definitions(repo, head, name, path, &imports);
        // SAFETY: per this function's contract.
        unsafe { put(out, list(found)) }
    })
}

/// Every use of `name` in repo@head, by path and line; a spot that also defines it is left
/// out.
///
/// # Safety
/// As `code_core_symbols_definitions`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbols_references(
    symbols: *mut CodeCoreSymbols,
    repo: CodeCoreStr,
    head: CodeCoreStr,
    name: CodeCoreStr,
    out: *mut *mut CodeCoreSymbolList,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (symbols, repo, head, name) =
            unsafe { (handle(symbols)?, repo.text()?, head.text()?, name.text()?) };
        let found = symbols.0.references(repo, head, name);
        // SAFETY: per this function's contract.
        unsafe { put(out, list(found)) }
    })
}

fn list(symbols: Vec<Symbol>) -> *mut CodeCoreSymbolList {
    let views = symbols
        .iter()
        .map(|s| CodeCoreSymbol {
            role: role(s.role),
            kind: CodeCoreStr::of(&s.kind),
            name: CodeCoreStr::of(&s.name),
            path: CodeCoreStr::of(&s.path),
            line: s.line,
            column: s.column,
        })
        .collect();
    owned::into_raw((symbols, views), |(_, views): &SymbolsData| {
        CodeCoreSymbolList {
            symbols: views.as_ptr(),
            count: views.len(),
        }
    })
}

/// Free a symbol list; null is a no-op.
///
/// # Safety
/// `list` is null or a symbol list of this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_symbol_list_free(list: *mut CodeCoreSymbolList) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreSymbolList, SymbolsData>(list) }
}

/// # Safety
/// `items` is null with `count` 0, or `count` texts valid for the call.
unsafe fn texts(items: *const CodeCoreStr, count: usize) -> Result<Vec<String>, Failure> {
    // SAFETY: per this function's contract.
    unsafe { slice(items, count) }?
        .iter()
        // SAFETY: per this function's contract.
        .map(|s| unsafe { s.text() }.map(str::to_owned))
        .collect()
}

/// The repo paths a file imports, for ranking definitions (TS and JS relative modules, Go
/// import paths' last two components, Rust `mod` files and `crate::` paths, PHP `use`
/// classes); best effort.
///
/// # Safety
/// Texts are valid for the call; `out` is valid for a write. Free the result with
/// `code_core_strings_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_imports(
    text: CodeCoreStr,
    language: u32,
    path: CodeCoreStr,
    out: *mut *mut CodeCoreStrings,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (text, path) = unsafe { (text.text()?, path.text()?) };
        let found = symbols::imports(text, crate::syntax::language(language)?, path);
        // SAFETY: per this function's contract.
        unsafe { put(out, strings_result(found)) }
    })
}

/// Whether `path` is a file `imports` names, or lies in a directory it names (as path
/// suffixes).
///
/// # Safety
/// Texts and `imports` (`import_count` texts) are valid for the call; `imported` is valid
/// for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_imported(
    path: CodeCoreStr,
    imports: *const CodeCoreStr,
    import_count: usize,
    imported: *mut bool,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (path, imports) = unsafe { (path.text()?, texts(imports, import_count)?) };
        // SAFETY: per this function's contract.
        unsafe { put(imported, symbols::imported(path, &imports)) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{read, s};
    use crate::{CODE_CORE_OK, code_core_strings_free};
    use std::ptr::null_mut;

    fn add(builder: *mut CodeCoreSymbolBuilder, files: &[(&str, &str)]) -> Vec<(String, String)> {
        let files: Vec<CodeCoreFile> = files
            .iter()
            .map(|(p, t)| CodeCoreFile {
                path: s(p),
                text: s(t),
            })
            .collect();
        let mut failed = null_mut();
        // SAFETY: a live builder and valid files.
        let status = unsafe {
            code_core_symbol_builder_add(
                builder,
                files.as_ptr(),
                files.len(),
                &mut failed,
                null_mut(),
            )
        };
        assert_eq!(status, CODE_CORE_OK);
        // SAFETY: a live result.
        let items = unsafe { std::slice::from_raw_parts((*failed).items, (*failed).count) };
        let out = items
            .iter()
            .map(|f| (read(f.path), read(f.reason)))
            .collect();
        // SAFETY: freed once.
        unsafe { code_core_failures_free(failed) };
        out
    }

    fn read_list(list: *mut CodeCoreSymbolList) -> Vec<String> {
        // SAFETY: a live result.
        let symbols = unsafe { std::slice::from_raw_parts((*list).symbols, (*list).count) };
        let out = symbols
            .iter()
            .map(|s| {
                format!(
                    "{}:{}:{}:{}:{}",
                    s.role,
                    read(s.kind),
                    read(s.path),
                    s.line,
                    s.column
                )
            })
            .collect();
        // SAFETY: freed once.
        unsafe { code_core_symbol_list_free(list) };
        out
    }

    /// Two batches build one index; definitions rank the imported file first, references
    /// leave definitions out, and the set forgets past its capacity.
    #[test]
    fn batches_build_one_index_the_set_keeps() {
        let mut set = null_mut();
        // SAFETY: valid out parameters throughout; every handle is freed.
        unsafe {
            assert_eq!(code_core_symbols_new(&mut set, null_mut()), CODE_CORE_OK);
            for head in ["1", "2", "3"] {
                let mut builder = null_mut();
                code_core_symbol_builder_new(&mut builder, null_mut());
                assert!(add(builder, &[("lib/a.ts", "export function render() {}\n")]).is_empty());
                add(
                    builder,
                    &[
                        (
                            "app/b.ts",
                            "import { render } from '../lib/a';\nrender();\n",
                        ),
                        ("c.md", "# x"),
                    ],
                );
                let status = code_core_symbols_install(set, s("o/r"), s(head), builder, null_mut());
                assert_eq!(status, CODE_CORE_OK);
            }
            let mut built = true;
            code_core_symbols_is_built(set, s("o/r"), s("1"), &mut built, null_mut());
            assert!(!built, "past capacity");
            let mut imports = null_mut();
            let text = "import { render } from '../lib/a';\n";
            code_core_imports(
                s(text),
                crate::syntax::CODE_CORE_LANGUAGE_TYPESCRIPT,
                s("app/b.ts"),
                &mut imports,
                null_mut(),
            );
            let candidates = std::slice::from_raw_parts((*imports).items, (*imports).count);
            assert!(candidates.iter().any(|c| read(*c) == "lib/a.ts"));
            let mut list = null_mut();
            let status = code_core_symbols_definitions(
                set,
                s("o/r"),
                s("3"),
                s("render"),
                s("app/b.ts"),
                candidates.as_ptr(),
                candidates.len(),
                &mut list,
                null_mut(),
            );
            assert_eq!(status, CODE_CORE_OK);
            assert_eq!(read_list(list), ["0:function:lib/a.ts:0:16"]);
            let mut imported = false;
            code_core_imported(
                s("lib/a.ts"),
                candidates.as_ptr(),
                candidates.len(),
                &mut imported,
                null_mut(),
            );
            assert!(imported);
            code_core_strings_free(imports);
            code_core_symbols_references(set, s("o/r"), s("3"), s("render"), &mut list, null_mut());
            assert_eq!(read_list(list), ["1:call:app/b.ts:1:0"]);
            code_core_symbols_purge(set, null_mut());
            code_core_symbols_is_built(set, s("o/r"), s("3"), &mut built, null_mut());
            assert!(!built);
            code_core_symbols_free(set);
        }
    }
}
