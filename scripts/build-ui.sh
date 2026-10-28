#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
RCC="${RCC:-/usr/lib/qt6/libexec/rcc}"
[[ -x "$RCC" ]] || { echo 'Set RCC to the Qt 6 rcc executable' >&2; exit 1; }
mkdir -p dist/remarkable-calendar
"$RCC" --binary --format-version 3 --no-compress packaging/application.qrc -o dist/remarkable-calendar/resources.rcc
cp packaging/appload/manifest.json dist/remarkable-calendar/
python3 - <<'PY'
import struct,zlib
from pathlib import Path
w=h=64
raw=b''.join(b'\0'+b''.join(bytes((255,255,255)) if not (12<x<52 and 12<y<52) else bytes((17,17,17)) for x in range(w)) for y in range(h))
def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
Path('dist/remarkable-calendar/icon.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
PY
