#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo test --locked
cargo build --locked
python3 tests/google_auth.py
python3 tests/launch.py
