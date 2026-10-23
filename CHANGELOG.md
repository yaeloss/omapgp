# Changelog

## Unreleased — 0.1.2

Follow-up hardening from a second review of the 0.1.1 candidate.

### Security

- Read GnuPG status lines from a dedicated pipe instead of stderr, and refuse
  arguments that would merge status with diagnostics. This closes the
  status-line impersonation class behind CVE-2018-12020 for this plugin.
- Route Copy/Cut in the draft and key-import editors through the guarded,
  sensitive clipboard path; they previously used Qt's built-in action.
- Escape line/paragraph separators, invisible direction marks, and zero-width
  characters in displayed key names, and sign the same sanitised identity that
  is shown.
- Report an abnormal GnuPG exit after text was displayed as a warning instead of
  a silent success, and keep genuinely decrypted text visible alongside it.
- Report failed `wl-copy` writes instead of claiming the text was copied.
- Refuse a relative `gnupgHome` setting instead of creating a keyring relative to
  the shell's working directory.
- Name `python3`, `wl-copy`, `wl-paste`, and `sh` by absolute path alongside gpg.

### Fixed

- The worker failed with a permission error when stdin was a regular file or
  `/dev/null`; it now falls back to a plain read.
- Editing past the 64 KiB limit wiped the whole draft. The rejected edit is now
  reverted and the existing draft is kept.

### Tests

- New coverage for status-stream separation, status argv rejection, redirected
  stdin, identity-display sanitisation, abnormal-exit warnings, guarded editor
  copy/cut, and draft preservation on oversized edits.

## 0.1.1 release candidate

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
