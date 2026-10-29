#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo test --locked
cargo build --locked
python3 tests/google_auth.py
python3 tests/launch.py
node tests/layout.cjs
node tests/navigation.cjs
node tests/month.cjs
node tests/month-data.cjs
