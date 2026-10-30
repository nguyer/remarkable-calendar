Calendar for reMarkable Paper Pro and Paper Pro Move (ARM64), launched through AppLoad.

This release includes a signed Vellum `.apk`, the AppLoad `.tar.gz` bundle, the public package-signing key, a Vellum recipe, build information, and SHA-256 checksums. The `.apk` is a Vellum package, not an Android application.

After installing or updating, select **AppLoad → Reload** and reopen **Calendar**. Normal upgrades and removal preserve credentials, settings, events, and pending edits; `vellum purge` deletes the app's saved data and credentials.

Google sign-in still requires the desktop helper. See the README for setup and `docs/packaging.md` for local-package installation, signing-key setup, and migration from a manually deployed installation.

Maintainer: test installation and upgrade on both supported tablets, add the changes for this version here, and publish this draft when ready. A GitHub release does not automatically add the package to the Vellum/reManager catalog.
