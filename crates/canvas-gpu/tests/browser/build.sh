#!/bin/sh
# Run inside the pinned Rust image through Devbox, from the checkout root.
set -eu
rustup target add wasm32-unknown-unknown
export CARGO_HOME=/work/.tools/cargo
export CARGO_BUILD_JOBS=4
cargo build -p canvas-gpu --example browser --target wasm32-unknown-unknown --profile perf --locked
# Keep downloaded tool contents separate from the checkout and never run a shell from it.
d=$(mktemp -d)
curl -fsSL https://github.com/wasm-bindgen/wasm-bindgen/releases/download/0.2.129/wasm-bindgen-0.2.129-x86_64-unknown-linux-musl.tar.gz -o "$d/tool.tar.gz"
echo "82d12bb940e2d4e72e0d5605387fc1b8ca179044e012b620f0ce4e7440e8320e  $d/tool.tar.gz" | sha256sum -c -
tar -xzf "$d/tool.tar.gz" -C "$d"
"$d/wasm-bindgen-0.2.129-x86_64-unknown-linux-musl/wasm-bindgen" --target web --out-dir target/browser target/wasm32-unknown-unknown/perf/examples/browser.wasm
