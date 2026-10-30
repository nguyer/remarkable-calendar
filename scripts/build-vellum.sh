#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v vbuild >/dev/null || { echo 'Install vbuild 0.0.36 first; see docs/packaging.md.' >&2; exit 1; }
[[ -f dist/release/vellum/VELBUILD ]] || { echo 'Run scripts/package-release.py first.' >&2; exit 1; }
# VBuild reads signing keys from ~/.config/vbuild; never copy private keys to dist.
CARCH=aarch64 VBUILD_KEY_NAME="${VBUILD_KEY_NAME:-remarkable-calendar}" \
    vbuild -C "$PWD/dist/release/vellum" all
shopt -s nullglob
packages=(dist/release/vellum/dist/aarch64/remarkable-calendar-*.apk)
[[ ${#packages[@]} == 1 ]] || { echo 'Expected exactly one Vellum package.' >&2; exit 1; }
cp "${packages[0]}" dist/release/
key_name="${VBUILD_KEY_NAME:-remarkable-calendar}"
cp "$HOME/.config/vbuild/$key_name.rsa.pub" dist/release/
python3 scripts/package-release.py --checksums-only
