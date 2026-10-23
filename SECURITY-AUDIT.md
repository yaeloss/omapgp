# omaPGP security audit

Date: October 22, 2026. Target: the current, uncommitted 0.1.0 working tree,
not a published release. Baseline Git HEAD: `d2f33c1040e56bc017a402f10064b8d48a109284`.

## Remediation update — October 22, 2026

The 0.1.1 working tree implements fixes for all six findings below. The
original audit text and source hashes are preserved as the historical 0.1.0
record, not as a description of the current implementation.

- **F1:** a disposable Python worker enforces 64 KiB input and clipboard-paste
  limits, 256 KiB output limits before delivery to QML, bounded stderr/status
  data, a 256 MiB address-space limit, a 30-second CPU budget, a 120-second
  deadline, and child cleanup. GnuPG also receives `--max-output`. Its shared
  agent is launched before applying worker CPU/memory limits; gpg then uses
  `--no-autostart`, so the budgets do not leak into a long-lived agent.
- **F2:** displayed identities use their own UID validity, not `pub` validity
  or key-wide TRUST statuses. A green signature also requires VALIDSIG, a
  usable matching full fingerprint, and certification of that exact UID.
  Signature results include the full fingerprint. Verify signs only the
  displayed UID. Percent-encoded status UIDs and C-escaped key-listing UIDs
  are decoded separately to prevent escape-sequence identity confusion.
- **F3:** operations ignore `gpg.conf`, disable extra-recipient/group settings,
  force stdout, and fail closed on invalid recipient fingerprints. Agent and
  hardware-token settings remain GnuPG's responsibility. Existing keyrings
  remain shared; this is an explicit configuration policy, not a sandbox.
- **F4:** each request gets a disposable process/collector. Completion and
  cancellation detach callbacks and destroy that object. Closing/invalidation
  clears duplicate result text, editor content, and undo history. The README
  now states the limits of physical-memory cleanup and OS swap/core behavior.
- **F5:** output uses a non-selectable plain `Text` view instead of TextArea,
  eliminating its default Copy and primary-selection paths. The explicit
  guarded Copy action is also used for signed-only plaintext. Editable input
  paste actions use a bounded worker and reject stale clipboard results.
- **F6:** recipient/signer/self-copy/consent/key/draft changes invalidate
  generated results. Requests capture their signing/recipient configuration;
  revision and epoch guards reject late callbacks. Success labels require
  GnuPG completion statuses, not just ASCII armor and an exit code.

Regression coverage includes real GnuPG compressed-output and conflicting
configuration probes, a real multi-UID certification/update case, eight worker
unit tests, actual QML process destruction/cancellation checks, a protected-key
agent/pinentry test, delayed callback tests, and headless UI tests of output,
paste limits, undo cleanup, and option-change invalidation.

The protected-key test uses a synthetic Assuan pinentry, not the user's
interactive window. The UI test substitutes the Wayland-only popup window
while exercising the actual plugin logic and controls. Real popup focus,
desktop clipboard integration, and hardware-token behavior remain manual
integration checks. This update is not an independent follow-up audit or a
claim that all possible vulnerabilities have been eliminated.

## Original assessment (0.1.0)

Source locations below refer to the original pre-release snapshot identified
by the hashes at the end of this report. Relative links open the current files;
the historical line numbers are labels, not current-file permalinks.

Do not treat this version as ready for sensitive use. This review identified
three high-severity findings and three medium-severity findings. Each has a
code-backed reproduction; the validation level is stated below. No critical
code-execution issue was demonstrated, and this is not a formal certification
or a complete audit of GnuPG, Qt, Quickshell, or the operating system.

The most important boundaries are authenticity of the displayed identity,
the actual recipient set, and resource isolation from the shared desktop shell.
The Omarchy runtime review confirmed that the plugin runs inside the same
Quickshell process as the bar and other shell components. That increases the
impact of excessive output and unnecessarily retained plaintext.

All probes used generated test keys and synthetic messages in a private
temporary directory, with memory limits of 256–512 MB and timeouts. Qt probes
used the offscreen backend, not the user's desktop clipboard or keyboard.
The real keyring and installed plugin were not modified. This report is the
only project file added by the audit; no implementation fixes were applied.

## F1 — High: compressed messages have unbounded output

Locations: [Model.js:21](Model.js),
[Panel.qml:150](Panel.qml),
[GpgProcess.qml:67](GpgProcess.qml).

The one-megacharacter input check limits the armored message, not the size of
its decompressed plaintext. GnuPG arguments do not set an output limit, and
`StdioCollector` accumulates all stdout before the result is passed to QML.
There is also no operation deadline or per-operation resource boundary in
the plugin itself. Large pasted input is already in the editor before the
input check runs.

Reproduced with real GnuPG: a valid 28,462-byte armored encrypted message
decompressed to 16,777,216 bytes. The plugin's input check accepted it, and
its decryption-summary code accepted the result. The probe deliberately
stopped at 16 MiB; it did not attempt to exhaust the desktop's memory.

An untrusted correspondent can supply highly compressible encrypted content
that the user pastes and decrypts. Accumulation and subsequent text rendering
can exhaust or stall the shared shell. This is a plausible freeze mechanism,
not proof that it caused the previously reported incident.

Remediation: enforce a plaintext byte limit in GnuPG (`--max-output`) and in
the stdout reader before accumulation; enforce input limits before accepting
large pastes; add deadlines and cancellation; isolate the worker with a memory
limit. A limit applied only after collecting output is too late. Add compressed
and oversized-input regression tests.

## F2 — High: an uncertified identity can be presented as verified

Locations: [Model.js:146](Model.js),
[Model.js:157](Model.js),
[Model.js:165](Model.js),
[Model.js:343](Model.js),
[Model.js:358](Model.js).

`parseKeys()` displays the first UID but derives `verified` from the `pub`
record. GnuPG's key-wide validity reflects its best-rated UID, not necessarily
the displayed one. Signature presentation similarly combines the UID from
`GOODSIG` with `TRUST_FULLY` to produce a green verified identity without
checking that particular UID's certification.

Reproduced with two disposable keyrings:

1. Import a key with `Certified Bob <bob@example.invalid>` and locally certify it.
2. In the key owner's keyring, add a new primary UID,
   `Uncertified Alice <alice@example.invalid>`, without certifying that UID in
   the verifier's keyring.
3. Import the updated public key. GnuPG reports `pub:f`, the first UID with
   validity `-`, and the older Bob UID with validity `f`.
4. The plugin displays Alice with `verified: true`. A real clearsigned message
   also produces `Good signature from Uncertified Alice ... (verified)` with
   the green tone. GnuPG's human-readable output distinguishes Alice as
   unknown and Bob as full.

An existing key holder can therefore attach another person's identity and
have the UI present that identity as verified after a key update. This does
not forge a signature or change the fingerprint; it misrepresents the
authenticated identity.

Remediation: separate cryptographic signature validity, fingerprint trust,
and certification of each UID. Keep the verified identity explicitly bound
to its fingerprint, preserve a user-confirmed identity label, and display
the full signer fingerprint. Do not apply the best UID's validity to every
UID. Add real multi-UID update tests.

## F3 — High, configuration-dependent: inherited GnuPG settings defeat the recipient and output boundaries

Locations: [Model.js:10](Model.js),
[Model.js:23](Model.js),
[Model.js:47](Model.js),
[Model.js:66](Model.js).

The plugin reads the selected keyring's normal `gpg.conf` without disabling or
overriding settings that conflict with its UI and privacy guarantees.
Full-fingerprint `--recipient` arguments do not neutralize additional
configured recipients or configured output destinations.

Two real-GnuPG reproductions used only disposable configuration:

- With `encrypt-to <extra-key-fingerprint>` in `gpg.conf`, encryption requested
  solely for a different recipient could also be decrypted with the extra key.
  The extra recipient was absent from the plugin's selected recipient list.
- With `output <test-file>` in `gpg.conf`, decrypting an encrypted fixture
  returned success and empty stdout while writing the complete plaintext to
  that file.

The precondition is an existing GnuPG configuration with such settings. An
untrusted message alone cannot install them, and the test does not demonstrate
remote configuration modification. Nevertheless, legitimate existing settings
can silently disclose plaintext or violate the no-disk-write promise.

Remediation: define a deliberate configuration policy. Prefer an audited,
minimal configuration for plugin operations, or explicitly neutralize
incompatible options, including extra/hidden recipients and group aliases.
Force `--output -` for operations that return message text. GnuPG provides
`--no-encrypt-to`, `--no-groups`, and `--no-options`; compatibility with users'
key, agent, hardware-token, and algorithm configuration must be tested rather
than silently assumed. Test actual recipient packets as well as successful
round trips.

## F4 — Medium: closing the panel leaves plaintext in the process collector

Locations: [GpgProcess.qml:38](GpgProcess.qml),
[GpgProcess.qml:44](GpgProcess.qml),
[Panel.qml:114](Panel.qml).

Closing calls `wipe()`, which clears the visible editors and calls
`gpg.cancel()`. Cancellation clears the callback and stdin string, but not
`StdioCollector.text`. Completion also leaves that property populated.

Reproduced in an offscreen Quickshell instance using the actual unmodified
`GpgProcess.qml`: a synthetic 24-character plaintext remained accessible as
`gpg.stdout.text` both before and after `gpg.cancel()`. No new process was
started to overwrite it.

This unnecessarily extends plaintext lifetime in the long-running shared
shell and contradicts the close-and-wipe claim. It is not a demonstration
that an unrelated external process can read the property without access to
the shell or its memory.

Remediation: explicitly release collected output on completion and
cancellation, preferably by disposing a per-operation process/collector.
Clear all duplicate UI/result state on invalidation. Describe this honestly
as best-effort reference cleanup: assigning empty JavaScript/Qt strings is
not a guarantee of physical memory erasure or protection from swap/core dumps.
Add close/cancel retention tests.

## F5 — Medium: normal text selection bypasses the sensitive-copy safeguards

Locations: [PgpTextArea.qml:45](PgpTextArea.qml),
[PgpTextArea.qml:64](PgpTextArea.qml),
[Panel.qml:309](Panel.qml),
[Panel.qml:569](Panel.qml).

The decrypted output is a selectable Qt `TextArea`. Read-only prevents editing,
not copying. Its built-in Copy action remains available, while only the custom
Copy button invokes the two-click confirmation, `wl-copy --sensitive`, and
expiry timer. The key handler does not intercept the standard Copy shortcut.

An offscreen Qt-controls probe with the same read-only/selectable settings
confirmed that selecting and copying the output transfers its text to the
clipboard without the custom handler. The actual desktop shortcut was not
injected. Installed Omarchy clipboard-capture code explicitly skips the
sensitive hint; the unguarded copy path does not use that hint and has no
plugin expiry timer.

A user taking the normal select-and-copy path can inadvertently leave
decrypted text in ordinary clipboard history despite the advertised controls.
This is a user-triggered privacy bypass, not a remote clipboard read.

Remediation: route all supported copy actions through the guarded path, or
disable built-in selection copying for sensitive output. Cover keyboard,
context-menu, and supported platform selection paths. Treat signed-only output
as plaintext when deciding clipboard policy. Test without modifying the user's
real clipboard.

## F6 — Medium: ciphertext and signing labels can become detached from the current UI

Locations: [Panel.qml:227](Panel.qml),
[Panel.qml:242](Panel.qml),
[Panel.qml:617](Panel.qml),
[Panel.qml:631](Panel.qml),
[Panel.qml:642](Panel.qml),
[Panel.qml:715](Panel.qml).

Changing recipients, signer, or encrypt-to-self does not invalidate an
already-generated result. The Copy button still copies the old ciphertext
while the controls describe a new recipient/signing configuration.
During a running operation, the completion callback also reads mutable
`root.signer` to label the output instead of using the original request.

A source-level reproduction executed the actual `encrypt()` function with
a delayed completion callback. The submitted command contained no `--sign`.
After changing the UI signer state and completing that request, the function
labeled the unsigned result `Encrypted and signed`. This was a callback test,
not a live desktop interaction. The stale-recipient path is also evident from
the change handlers: they do not clear `writeOutput`.

Users can copy ciphertext for a prior recipient or rely on a signing claim
that does not describe the generated message.

Remediation: snapshot the plaintext, complete recipient set, signer, and
options for each request; bind result labels to that snapshot; invalidate
results whenever those inputs change; reject stale callbacks with request
IDs. Disable conflicting actions while running and validate the required
GnuPG completion statuses before labeling an operation as signed.

## Checks that passed and limits

- `tests/run-all.sh` passed again under a 512 MB memory cap: model tests,
  real-GnuPG integration tests, the QML process harness, and manifest validation.
  These existing tests do not cover the findings above.
- Argument construction uses arrays and validates full fingerprints; message
  and pasted-key content travel through stdin, not shell interpolation.
  The clipboard shell fragment is fixed code and receives only a hash on stdin.
- Message and identity widgets use plain-text rendering. No active content,
  message-driven URL fetch, or automatic key-retrieval path was found in the
  plugin source. This was source review, not a packet-capture assurance about
  the entire desktop or all agent configurations.
- A signed-packet-plus-unsigned-packet probe produced a bad signature, not a
  falsely verified message. That particular attempted bypass was not reproduced.
- No real passphrase-window interaction, hardware token, desktop clipboard
  history, or high-load live panel test was performed. No GnuPG/Qt/Quickshell
  binary vulnerability assessment or formal cryptographic analysis was done.
- This audit does not establish that the plugin caused the earlier system
  freeze, nor that real keys or messages were compromised.

Recommended order: fix F1–F3 before sensitive use; then F4–F6, update the privacy
claims, and add regression coverage for all six findings before release.

## Reference material checked

- GnuPG manual, GPG Key related Options and GPG Configuration Options:
  extra recipients, group aliases, and options-file handling.
- GnuPG manual, GPG Input and Output: output destinations and output limits.
- GnuPG `doc/DETAILS`: key/UID validity and signature status semantics.
- Qt 6 `TextEdit` documentation: read-only selection and the Copy API.
- Installed Omarchy `KeyboardPanel.qml`, `PanelController.qml`, and clipboard
  `capture.sh`, plus the plugin source and existing test suite.

## Audited implementation hashes (SHA-256)

```text
96674371d395c5dbbb12da2eb7b1fb21ed257c514a78458c184c35be5931508e  BarWidget.qml
6eb82741ad92f0165de956a4c885065de793c87dc7697c6815935c02ad60cf02  GpgProcess.qml
3cfdc5fd87bf536cb5f661439b571671773525c5dbe8f217d000717fa9805a0a  Model.js
6d354ec6c78c98036c52fc078e9b16d6049ccdd63d2137d1c93f4e111307e515  Panel.qml
d6511a971c849cbd550813795fa57fe1b04edc0a95cb2be1fd130638aa70dfba  PgpTextArea.qml
f10ea828492343898fa2b1b27baed8389c4de03e6c347fa1bdd4a9907bc3d604  manifest.json
```
