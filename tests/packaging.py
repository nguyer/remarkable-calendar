"""Exercise release contents, reproducibility, architecture rejection, and Vellum staging."""
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_package", ROOT / "scripts/package-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        (self.bundle / "backend").mkdir(parents=True)
        elf = bytearray(64)
        elf[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", elf, 18, 183)
        (self.bundle / "backend/entry").write_bytes(elf)
        (self.bundle / "manifest.json").write_text(
            '{"id":"org.remarkablecalendar.move","loadsBackend":true}')
        (self.bundle / "resources.rcc").write_bytes(b"resources")
        (self.bundle / "icon.png").write_bytes(b"icon")
        (self.bundle / "google.json").write_text("PRIVATE CREDENTIALS")
        (self.bundle / "events.sqlite3").write_text("PRIVATE EVENTS")

    def make(self, name="release"):
        output = self.root / name
        archive = release.package(self.bundle, output, "0.8.0", "nguyer/remarkable-calendar", 1234567890)
        return output, archive

    def test_allowlist_modes_checksums_and_reproducibility(self):
        output, archive = self.make()
        _, again = self.make("again")
        self.assertEqual(archive.read_bytes(), again.read_bytes())
        with tarfile.open(archive) as tar:
            names = {m.name for m in tar.getmembers()}
            self.assertEqual(names, {"remarkable-calendar/" + n
                                    for n in (*release.APP_FILES, "LICENSE.md")})
            for member in tar.getmembers():
                self.assertEqual(member.uid, 0)
                self.assertEqual(member.mtime, 1234567890)
                self.assertEqual(member.mode, 0o755 if member.name.endswith("backend/entry") else 0o644)
        self.assertIn(hashlib.sha512(archive.read_bytes()).hexdigest(), (output / "VELBUILD").read_text())
        for line in (output / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((output / name).read_bytes()).hexdigest())

    def test_wrong_architecture_and_symlink_rejected(self):
        entry = self.bundle / "backend/entry"
        data = bytearray(entry.read_bytes())
        struct.pack_into("<H", data, 18, 62)  # x86-64 must never become a tablet release.
        entry.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "ARM64"):
            self.make()
        entry.unlink()
        entry.symlink_to(self.bundle / "icon.png")
        with self.assertRaisesRegex(ValueError, "regular bundle file"):
            self.make()

    def test_vellum_staging_and_data_retention(self):
        output, archive = self.make()
        src = self.root / "src"
        src.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(src, filter="data")
        stage = self.root / "pkg"
        recipe = output / "vellum/VELBUILD"
        env = dict(os.environ, srcdir=str(src), pkgdir=str(stage), startdir=str(recipe.parent))
        subprocess.run(["bash", "-eu", "-c", '. "$1"; package', "test", str(recipe)], env=env, check=True)
        expected = {"home/root/xovi/exthome/appload/remarkable-calendar/" + n for n in release.APP_FILES}
        expected |= {"home/root/.vellum/licenses/remarkable-calendar/" + n for n in ("LICENSE", "SOURCES")}
        self.assertEqual({str(p.relative_to(stage)) for p in stage.rglob("*") if p.is_file()}, expected)
        entry = stage / "home/root/xovi/exthome/appload/remarkable-calendar/backend/entry"
        self.assertEqual(entry.stat().st_mode & 0o777, 0o755)
        # Intercept removal rather than touching actual user directories.
        hook = '. "$1"; rm() { printf "%s\\n" "$*"; }; postdeinstall'
        env["VELLUM_PURGE"] = "0"
        kept = subprocess.check_output(["bash", "-eu", "-c", hook, "test", str(recipe)], env=env, text=True)
        self.assertEqual(kept, "")
        env["VELLUM_PURGE"] = "1"
        removed = subprocess.check_output(["bash", "-eu", "-c", hook, "test", str(recipe)], env=env, text=True)
        self.assertEqual(removed.strip(), "-rf /home/root/.config/remarkable-calendar /home/root/.local/share/remarkable-calendar")

    def test_invalid_release_inputs(self):
        for version, repository in [("v0.8.0", "nguyer/remarkable-calendar"),
                                    ("0.8.0", "owner/repo;echo bad")]:
            with self.assertRaises(ValueError):
                release.package(self.bundle, self.root / "bad", version, repository, 0)


if __name__ == "__main__":
    unittest.main()
