# Releases and Vellum packaging

The package supports **Paper Pro and Paper Pro Move (aarch64)**. It installs the existing AppLoad app as **Calendar**, with the same ID and paths as a source deployment. reMarkable 1, 2, and Paper Pure are excluded until supported and tested.

reManager browses the Vellum catalog, so a Vellum catalog entry also makes Calendar available through reManager. A GitHub release alone does not add an entry to that catalog. This project now builds packages for testing; catalog submission and real-device installation/upgrade validation are still required.

## GitHub Actions

The **Build and package** workflow runs on pushes to `main`, pull requests, version tags, and manual runs from the Actions tab. It runs the existing tests plus packaging tests, then builds the Rust ARM64 backend and the QML resources from source. It does not use `prebuilt-ui/`.

Every successful run provides a `remarkable-calendar-aarch64` artifact containing:

| File | Purpose |
| --- | --- |
| `remarkable-calendar-VERSION-aarch64.tar.gz` | AppLoad app bundle and app license; no credentials or database |
| `remarkable-calendar-VERSION-r0.apk` | Signed Vellum package (not an Android app) |
| `remarkable-calendar.rsa.pub` (or `remarkable-calendar-dev.rsa.pub`) | Public key used to verify this package |
| `VELBUILD` | Recipe for a Vellum catalog submission, referencing the release archive |
| `SHA256SUMS` | Checksums of the release files |
| `BUILD-INFO.json` | Source commit, Rust version, build run, and glibc limit |

The backend is linked on Ubuntu 22.04 with the ARM64 GNU cross compiler. CI rejects a binary requiring glibc newer than 2.35. This is a compiler baseline, not proof of compatibility with all firmware: test on each supported tablet before publishing. AppLoad/Vellum resolves its own firmware dependencies.

### One-time signing setup

For tagged releases, configure a persistent private signing key as the repository Actions secret **`VELLUM_SIGNING_KEY`**. Generate it outside the checkout, on a trusted computer:

```sh
umask 077
mkdir -p ~/.config/vbuild
openssl genrsa -out ~/.config/vbuild/remarkable-calendar.rsa 4096
openssl rsa -in ~/.config/vbuild/remarkable-calendar.rsa -pubout \
  -out ~/.config/vbuild/remarkable-calendar.rsa.pub
```

In GitHub, open **Settings → Secrets and variables → Actions → New repository secret**. Name it `VELLUM_SIGNING_KEY` and paste the entire private `.rsa` file, including the BEGIN/END lines. Keep a private backup. Do not commit it or upload it as a release asset. The workflow exports only the public key and removes the runner's private copy after packaging.

Tags fail if the secret is missing. Branch, pull-request, and manual builds always use a disposable development key named `remarkable-calendar-dev`; the production signing secret is supplied only to tag builds. That public key is only for testing that build. Prefer a disposable key for local testing as well. Do not trust an unreviewed pull-request package on your tablet.

### Build a release

1. Update the version in `Cargo.toml` and run `cargo check` to refresh the root package version in `Cargo.lock`. Use `MAJOR.MINOR.PATCH` for this first packaging workflow.
2. Commit the changes and push them.
3. Create and push a matching tag, for example:

   ```sh
   git tag v0.8.0
   git push origin v0.8.0
   ```

   Use the actual version, and do not reuse an existing tag. CI requires an exact match with `Cargo.toml`.
4. Watch **Actions → Build and package**. A successful tag build creates a **draft GitHub release**, with the artifacts attached.
5. Download and verify the artifacts, test on the tablets, and replace the maintainer note in the draft with that version's changes. Publish the draft when ready.

A manual Actions run builds downloadable artifacts without creating a release. Tagged-release jobs use the built-in GitHub token with release-write access; no personal access token is needed. Nothing in the workflow submits to Vellum or sends messages to maintainers.

## Build locally

First build the backend and UI as described in [Development](development.md#build-for-the-tablet). Packaging requires Python **3.11+**, OpenSSL, Docker or Podman accessible to your user, and [VBuild 0.0.36](https://github.com/Eeems/vbuild/releases/tag/0.0.36). The workflow pins and verifies the VBuild executable's SHA-256 checksum.

From the repository root:

```sh
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
python3 scripts/package-release.py
VBUILD_KEY_NAME=remarkable-calendar-dev ./scripts/build-vellum.sh
```

VBuild generates a local development key in `~/.config/vbuild/` if that key name does not exist. The final files are in `dist/release/`; the public key is named `remarkable-calendar-dev.rsa.pub` for the command above. Private keys stay outside `dist/`.

`package-release.py` uses an explicit file allowlist, validates ARM64 ELF architecture, and creates a deterministic archive with normalized ownership, modes, and timestamps. It emits two recipes: a public recipe referencing the versioned GitHub release, and a local recipe under `dist/release/vellum/` that reads the identical archive without needing a published release or tag README. Only the public recipe belongs in a catalog submission.

Use a fresh `dist/release/` directory for each version to avoid mixing older release assets. Packaging does not rebuild the app automatically; the Actions workflow performs both builds first.

## Test installation before catalog submission

These commands use a computer with SSH access and a tablet that already has Vellum installed. The current package does not block updating an open app; after an update, use **AppLoad → Reload** and reopen Calendar to load the new UI.

### Existing manual installation

The package uses the same files as `scripts/deploy.sh`. If Vellum reports existing/unowned file conflicts, keep a backup of the manually deployed app folder rather than forcing an overwrite. With Calendar closed, rename that exact directory to an unused backup name, for example:

```sh
ssh root@10.11.99.1 'test ! -e /home/root/xovi/exthome/calendar-manual-backup && mv /home/root/xovi/exthome/appload/remarkable-calendar /home/root/xovi/exthome/calendar-manual-backup'
```

This leaves credentials and the database at their existing paths. The backup sits outside AppLoad's app directory so it does not appear as a duplicate Calendar app. Once package-managed, use Vellum/reManager for upgrades; manual deploys change package-owned files without updating package metadata.

### Copy and install a local package

Replace the version and public-key filename with those from your build. For a tagged GitHub Actions release, the public key is `remarkable-calendar.rsa.pub`; other Actions builds use `remarkable-calendar-dev.rsa.pub`.

On your computer, in `dist/release/`:

```sh
sha256sum --check SHA256SUMS
scp remarkable-calendar-0.8.0-r0.apk remarkable-calendar.rsa.pub root@10.11.99.1:/home/root/
ssh root@10.11.99.1
```

On the tablet, install the public key without overwriting a different trusted key:

```sh
calendar_key=/home/root/.vellum/etc/apk/keys/remarkable-calendar.rsa.pub
if [ -f "$calendar_key" ]; then
  cmp /home/root/remarkable-calendar.rsa.pub "$calendar_key"
else
  cp /home/root/remarkable-calendar.rsa.pub "$calendar_key"
fi
```

If `cmp` reports a difference, stop and check which build/key you are installing. Do not replace a previously trusted production key with a disposable development key. For a local development build, use its distinct `remarkable-calendar-dev.rsa.pub` filename throughout.

Then install:

```sh
vellum add /home/root/remarkable-calendar-0.8.0-r0.apk
```

Select **AppLoad → Reload → Calendar**. Initial Google authorization still follows the [README](../README.md#6-create-your-google-oauth-client); packaging does not change sign-in.

### Validation before publishing

- Fresh installation: dependencies install, Calendar appears once in AppLoad, and all three views open on Paper Pro and Move.
- Existing-install migration: saved events, calendar choices, timezone, navigation, credentials, and pending offline edits remain available.
- Upgrade: install a second package version and confirm the UI changes while saved data remains; sync queued edits afterward.
- Normal removal: `vellum del remarkable-calendar` removes the app files but retains its credentials and database; reinstall restores access.
- Explicit purge: `vellum purge remarkable-calendar` also deletes credentials and saved data, including pending edits. Test only with disposable data.
- Verify the packaged backend launches on the supported firmware without missing-library errors.

Host tests validate archive contents, modes, checksums, architecture, staging, and removal behavior; they do not replace these tablet checks.

## Vellum/reManager catalog

After publishing and tablet testing, use the generated public `VELBUILD` as the starting recipe for `packages/remarkable-calendar/VELBUILD` in the [Vellum repository](https://github.com/vellum-dev/vellum). It declares the AppLoad dependency and device exclusions, installs only app/license files, and preserves user data except on explicit purge.

The recipe has `pkgrel=0`; increment `pkgrel` for packaging-only revisions and reset it when changing `pkgver`. A new package revision requires a rebuilt `.apk` and matching submitted recipe.

Follow Vellum's [contribution requirements](https://github.com/vellum-dev/vellum#contributing), including human-authored submissions and discussion. Its maintainers build/sign catalog packages with their infrastructure; the project's private signing key is not shared with them. Once accepted, verify Calendar can be installed and updated through reManager's package browser as well as Vellum.
