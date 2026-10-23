# Contributing

omaPGP uses QML/JavaScript for the Omarchy interface and a Python standard-library
worker for bounded local GnuPG operations. There are no npm or pip dependencies.

## Tests

On Linux with Node.js (CI uses Node 24), Python 3, and GnuPG:

```sh
bash tests/run-portable.sh
```

Use a Git checkout or a clean source archive. This runs package/documentation
checks, model and delayed-callback tests, real
GnuPG adversarial cases, a protected test key with synthetic pinentry, and worker
limit/cleanup tests. It also verifies that the QML runners reject a failed
Quickshell exit, even if the process prints a success marker. GitHub Actions
runs this suite; it does not test the live
Omarchy desktop. The simple publication scanner is not a comprehensive secret
scanner or a substitute for reviewing the diff.

On an Omarchy installation with Quickshell, Qt 6.9+, and `wl-clipboard`:

```sh
bash tests/run-all.sh
```

This also runs the offscreen QML process and UI harnesses and the installed
Omarchy manifest validator. The UI harness substitutes only the Wayland popup
window; actual panel logic and controls are instantiated. No desktop keystrokes
or real clipboard reads are used. See the manual checks in [SECURITY.md](SECURITY.md#before-the-first-release).

## Keep test data disposable

Tests generate synthetic keys in private temporary directories and stop their
own agents on cleanup. Never run fixtures against `~/.gnupg`, commit a real
keyring/export, or replace synthetic data with private messages. The fixed
passphrase in the test pinentry is intentionally public and test-only.

Keep virtual environments and other generated files outside the installed
plugin. Omarchy rejects plugin symlinks. Do not copy the repository's `.git`,
environments, or caches into the live plugin directory.

## Changes

Keep the display name **omaPGP** and the stable plugin ID
`io.github.yaeloss.omapgp`. Use two spaces in QML/JavaScript/JSON/YAML and four
in Python. Add regression tests for security and data-lifecycle changes.

Do not remove limits, re-enable automatic key/network retrieval, bypass exact
identity checks, or add an unguarded sensitive-copy path just to make an example
work. Document deliberate changes to the threat model and configuration policy.

Report vulnerabilities through the process in [SECURITY.md](SECURITY.md), not a
public bug report containing exploit details or personal data.

## Preview card

The README uses [.github/social-preview.png](.github/social-preview.png).
Its editable source is [.github/social-preview.svg](.github/social-preview.svg),
drawn to match the omuseful card family using the original omaPGP lock mark.
The UI panel is an illustration with synthetic content, not a real keyring
screenshot. Keep that distinction visible when editing the card.

To regenerate the 1280×640 PNG, install `rsvg-convert` (from `librsvg` on Arch)
and use JetBrains Mono Nerd Font for the same typography:

```sh
rsvg-convert --output .github/social-preview.png .github/social-preview.svg
```

The font is not bundled; a monospace fallback is specified in the SVG. The
rendered PNG preserves the chosen typography for README and social-preview use.
Setting the repository's GitHub Social preview image is a separate manual step;
committing this file does not upload it to that setting.
