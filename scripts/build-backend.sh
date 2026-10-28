#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${RUST_TARGET:-aarch64-unknown-linux-gnu}"
cargo build --locked --release --target "$TARGET"
mkdir -p dist/remarkable-calendar/backend
cp "target/$TARGET/release/remarkable-calendar-core" dist/remarkable-calendar/backend/entry
