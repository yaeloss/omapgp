# Changelog

## Unreleased — 0.1.1 release candidate

This is the first publication candidate. The earlier 0.1.0 development snapshot
was not a published release.

### Added

- An Omarchy bar widget and **omaPGP** panel with Read, Write, and Keys tabs.
- Text encryption/decryption, signing/signature checks, pasted key import,
  public-key export, and local certification of a displayed identity.
- Optional encrypt-to-self, a separate-keyring setting, keyboard navigation,
  explicit sensitive-copy confirmation, and configurable clipboard expiry.
- MIT license, a security policy, an audit/remediation record, and automated
  portable and Omarchy-specific test suites.
- A README/social preview card with editable SVG source and synthetic UI content.

### Hardened before publication

- Bound input, decompressed output, diagnostics, worker memory/CPU/time, and
  clipboard-paste input before results reach the shared shell.
- Check each displayed identity's certification rather than inheriting another
  UID's trust; show full signer fingerprints and certify only the selected UID.
- Ignore conflicting `gpg.conf` recipients, groups, and file-output settings.
- Destroy per-request collectors and clear editor content/undo history on close.
- Remove built-in selection/copy from sensitive output; use the guarded copy
  path for decrypted and signed-only text.
- Invalidate output on input/recipient/signer changes, reject stale callbacks,
  and require GnuPG completion statuses before reporting success.
- Require a clean Quickshell exit as well as a passing QML test marker, so a
  later crash or timeout cannot be reported as a successful test run.

### Still to check manually

Real Wayland popup/pinentry focus, desktop clipboard integration, and any claimed
hardware-token configuration. Automated tests use disposable keys and a synthetic
pinentry. See [SECURITY.md](SECURITY.md#before-the-first-release).
