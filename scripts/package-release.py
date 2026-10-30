#!/usr/bin/env python3
"""Package an already-built ARM64 app; never include files outside the allowlist."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
APP_FILES = ("manifest.json", "resources.rcc", "icon.png", "backend/entry")


def package(bundle, output, version, repository, epoch):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Release version must be MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Repository must be owner/name")
    if epoch < 0:
        raise ValueError("SOURCE_DATE_EPOCH must be nonnegative")
    payload = {}
    for name in APP_FILES:
        path = bundle / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing regular bundle file: {name}")
        payload[name] = path.read_bytes()
    elf = payload["backend/entry"]
    if (len(elf) < 64 or elf[:6] != b"\x7fELF\x02\x01"
            or struct.unpack_from("<H", elf, 18)[0] != 183):
        raise ValueError("backend/entry must be a little-endian ARM64 ELF binary")
    manifest = json.loads(payload["manifest.json"])
    if manifest.get("id") != "org.remarkablecalendar.move" or not manifest.get("loadsBackend"):
        raise ValueError("Unexpected AppLoad manifest")
    payload["LICENSE.md"] = (ROOT / "LICENSE.md").read_bytes()
    output.mkdir(parents=True, exist_ok=True)
    archive_name = f"remarkable-calendar-{version}-aarch64.tar.gz"
    archive = output / archive_name
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for name, data in sorted(payload.items()):
                    info = tarfile.TarInfo("remarkable-calendar/" + name)
                    info.size = len(data)
                    info.mtime = epoch
                    info.mode = 0o755 if name == "backend/entry" else 0o644
                    tar.addfile(info, io.BytesIO(data))
    digest = hashlib.sha512(archive.read_bytes()).hexdigest()
    template = (ROOT / "packaging/vellum/VELBUILD.in").read_text()
    values = {"VERSION": version, "REPOSITORY": repository, "SHA512": digest,
              "ARCHIVE": archive_name,
              "SOURCE": f"https://github.com/{repository}/releases/download/v{version}/{archive_name}"}
    recipe = template
    for key, value in values.items():
        recipe = recipe.replace("@" + key + "@", value)
    (output / "VELBUILD").write_text(recipe)
    # The package is built before the release exists, using the identical local asset.
    local = output / "vellum"
    local.mkdir(exist_ok=True)
    local_recipe = recipe.replace(values["SOURCE"], archive_name)
    # A local/manual build may precede the public tag (VBuild checks readme URLs).
    local_recipe = "\n".join(line for line in local_recipe.split("\n")
                             if not line.startswith("readmeurl="))
    (local / "VELBUILD").write_text(local_recipe)
    (local / archive_name).write_bytes(archive.read_bytes())
    checksum_files(output)
    return archive


def checksum_files(output):
    paths = sorted(p for p in output.iterdir() if p.is_file() and p.name != "SHA256SUMS")
    (output / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in paths))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT / "dist/remarkable-calendar")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/release")
    parser.add_argument("--repository", default="nguyer/remarkable-calendar")
    parser.add_argument("--version")
    parser.add_argument("--checksums-only", action="store_true")
    args = parser.parse_args()
    if args.checksums_only:
        checksum_files(args.output)
        return
    version = tomllib.loads((ROOT / "Cargo.toml").read_text())["package"]["version"]
    if args.version is not None and args.version != version:
        parser.error(f"Tag version {args.version} differs from Cargo.toml version {version}")
    try:
        archive = package(args.bundle, args.output, version, args.repository,
                          int(os.environ.get("SOURCE_DATE_EPOCH", "0")))
    except (ValueError, OSError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(archive)


if __name__ == "__main__":
    main()
