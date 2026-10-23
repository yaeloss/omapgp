# Security

omaPGP is early-stage software, not an independently certified cryptographic
product. GnuPG performs the cryptography; this plugin is a local text interface.
During early development, security fixes target the current default branch.
The version in `manifest.json` is not evidence that a release has been published.

## What it protects

- Untrusted message/key text is passed over pipes, not interpolated into shell
  commands. Fingerprints are validated before they become key arguments.
- Disposable workers bound input, decompressed output, diagnostics, CPU time,
  address space, and elapsed time. Oversized results are rejected before they
  reach the shared shell's text views.
- Operations ignore `gpg.conf`, disable configured extra recipients and group
  aliases, and force message output to stdout. GnuPG agent and hardware-token
  settings remain under GnuPG's control.
- A valid signature is not the same as a verified identity. Identity badges
  use certification of the exact displayed UID and matching key fingerprint.
  Compare the full fingerprint through a trusted channel before verification.
- Closing cancels pending operations, destroys collectors, and clears message
  references and editor undo history. Superseded callbacks cannot restore text.
- Sensitive output has no default selection/copy path. Its explicit Copy button
  asks twice, sets a sensitive clipboard hint, and schedules conditional expiry.
  Copy and Cut inside the draft and import editors use the same guarded path, so
  a draft or a pasted private key does not travel through Qt's built-in clipboard
  action.
- GnuPG status lines are read from a dedicated pipe rather than from stderr, so
  diagnostics cannot be parsed as a signature or decryption result.
- Key names are sanitised for display: control characters, line/paragraph
  separators, and text-direction overrides are escaped or flattened.
- A failed clipboard write is reported as a failure, and an abnormal GnuPG exit
  after text was displayed is shown as a warning rather than a clean success.

For exact limits and configuration behavior, see [README.md](README.md#resource-and-configuration-policy).

## What it does not protect

- Omarchy plugins run unsandboxed inside a shared shell process. Another plugin,
  compromised account, or privileged process may access the same user's data.
- Clearing Qt/JavaScript references does not guarantee physical memory erasure.
  Swap, core dumps, screenshot tools, and other desktop components are outside
  this plugin's control. The worker suppresses its own core dumps only.
- Clipboard hints are advisory. Other applications can read copied text, and
  clipboard managers may ignore the hint. Expiry cannot retract a saved copy.
- Qt mirrors the current text selection to the Wayland primary selection while
  you drag-select inside a text field, and QML cannot disable that separately.
  The guarded Copy/Cut actions clear the selection afterwards, but a selection
  left highlighted can still be visible to primary-selection tools.
- Pasting a private key does not remove copies already made by other programs
  or add a passphrase to an unprotected key. Importing keys intentionally changes
  the selected GnuPG keyring; cancelling is not a rollback of completed imports.
- Plaintext and signature validity do not establish who is currently using a
  key. A stolen, misidentified, or improperly certified key remains a risk.
- Worker resource limits do not sandbox the shared GnuPG agent or hardware-token
  services. Existing agent configuration and passphrase caching still apply.

The development audit and its remediation record are in
[SECURITY-AUDIT.md](SECURITY-AUDIT.md). They are a local engineering review,
not an independent follow-up audit or a promise that no vulnerabilities remain.

## Reporting a vulnerability

Do not put private keys, passphrases, decrypted messages, real contact details,
or shell memory dumps in an issue or pull request.

If this repository offers **Security → Report a vulnerability**, use that
private reporting route. If it is unavailable, open an issue asking for a private
reporting channel, without publishing exploit details or sensitive material.
The maintainer has not committed to a response-time guarantee.

Useful reports identify the version/commit, Omarchy/Quickshell/GnuPG versions,
expected and actual behavior, and a minimal reproduction using synthetic keys
and messages. Public issue templates are not a private channel.

## Before the first release

- Run `bash tests/run-portable.sh` and `bash tests/run-all.sh` on Omarchy.
- Verify the panel title/tooltip, tab navigation, and Escape/outside-click close.
- With a disposable protected key, test the real pinentry window's focus,
  success, cancellation, and panel recovery. Do not use a production key.
- Check explicit Copy confirmation, the sensitive hint, expiry, and preservation
  of clipboard content that the user replaces before the timer fires.
- Check that Ctrl+C/Ctrl+X and the right-click menu in the draft and import
  editors use the guarded copy and show the clipboard notice.
- Check the hardware-token path if support is being claimed for that device.
- Confirm close/reload cancels work and clears input, output, and undo history.
- Keep unresolved manual checks visible in release notes; do not describe a
  test pass as a security certification.
- Confirm the publishing file set contains no keyrings, exported private keys,
  credentials, core dumps, local environment files, or personal screenshots.
