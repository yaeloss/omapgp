# Changelog

## 0.1.4

omaPGP 0.1.4 improves copying and pasting PGP messages, makes contact
verification easier to follow, and fixes recipient selection in Write.

### What changed

- **Copy and paste.** Copy the whole result in one click, then paste it in
  another app. Encrypted messages are offered as plain text, and a copy can
  finish after you close the panel. Select part of an encrypted result to copy
  just that selection. Paste at the cursor or over selected text in any editor.
  omaPGP also accepts armored PGP text restored from history with a PGP media
  type.
- **Contact verification.** Compare or paste a contact’s full fingerprint in
  the Keys tab before confirming. omaPGP checks the exact identity again after
  saving and recognizes valid local certifications even when the personal key
  that signed them has no GnuPG ownertrust assigned. Verification failures show
  a more specific message.
- **Recipients and personal keys.** The displayed recipient selection stays
  in sync with encryption after a keyring refresh or when reopening the panel.
  Personal keys are labeled **your key**, with their full fingerprint ready to
  share. You can encrypt to your own decryption keys without the contact
  verification prompt.

### Update on Omarchy

```sh
omarchy plugin update io.github.yaeloss.omapgp
```

If your clipboard history picker restores encrypted text as a PGP file, copy
it directly from omaPGP before pasting into another app. omaPGP can read those
history entries in its own editors.

## 0.1.3

The first tagged release of omaPGP brings safer clipboard handling and a choice
of which personal key receives your encrypted copy. omaPGP lets you encrypt,
decrypt, sign, and verify PGP text from the Omarchy bar using your local GnuPG
keyring.

### What changed

- **Clipboard.** The panel keeps no copy history. Cut keeps the original text
  until the clipboard write succeeds. Public-key copy reports the outcome of the
  write.
- **Key verification.** omaPGP certifies the exact GnuPG identity and confirms
  its status after reloading the keyring.
- **Drafts.** Edits that exceed 64 KiB preserve the last valid draft, including
  when a multibyte replacement leaves the character count unchanged.
- **Encrypt to myself.** See which personal key gets a copy and choose one when
  several are available. Encryption-only personal keys are eligible.

### Update on Omarchy

```sh
omarchy plugin update io.github.yaeloss.omapgp
```

The automated tests passed on Omarchy 4.5.0-3. Live Wayland clipboard expiry,
popup focus, and interactive pinentry cancellation still need desktop checks.

## 0.1.2 development snapshot

### Security

- Read GnuPG status lines from a dedicated pipe instead of stderr, and refuse
  arguments that would merge status with diagnostics. This closes the
  status-line impersonation class behind CVE-2018-12020 for this plugin.
- Route Copy and Cut in the draft and key-import editors through the sensitive
  clipboard path.
- Escape line/paragraph separators, invisible direction marks, and zero-width
  characters in displayed key names.
- Report an abnormal GnuPG exit after text was displayed as a warning instead of
  a silent success, and keep genuinely decrypted text visible alongside it.
- Report failed `wl-copy` writes instead of claiming the text was copied.
- Refuse a relative `gnupgHome` setting instead of creating a keyring relative to
  the shell's working directory.

### Fixed

- The worker failed with a permission error when stdin was a regular file or
  `/dev/null`; it now falls back to a plain read.
- Reject edits that exceed the editor's character limit while keeping the draft.

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
pinentry. See [SECURITY.md](SECURITY.md#release-checklist).
