// Headless harness: exercises GpgProcess.qml (stdin piping, status parsing,
// stdout collection) inside Quickshell against a throwaway keyring.
// Run via tests/run-qml.sh, which stages this file next to GpgProcess.qml
// and Model.js; never run it against a real keyring.
import QtQuick
import Quickshell
import "Model.js" as Model

ShellRoot {
  id: root
  readonly property string home: Quickshell.env("OMAPGP_TEST_HOME")
  readonly property string text: "Héllo from the QML harness ✓\nline two\n"
  property var keys: []
  property int failures: 0
  property var cancelledRun: null
  property bool cancelledCallback: false
  property bool pinentrySeen: false

  function check(cond, label) {
    console.log((cond ? "ok   " : "FAIL ") + label)
    if (!cond) failures++
  }

  function done() {
    console.log(failures === 0 ? "qml harness passed" : "qml harness FAILED")
    Qt.exit(failures === 0 ? 0 : 1)
  }

  GpgProcess { id: gpg; onPinentryLaunched: root.pinentrySeen = true }

  Component.onCompleted: {
    gpg.start(Model.listKeysArgs(home, false), null, function(pub) {
      gpg.start(Model.listKeysArgs(home, true), null, function(sec) {
        keys = Model.parseKeys(pub.stdout, sec.stdout)
        check(keys.length === 1 && keys[0].hasSecret, "lists one secret key")
        var fpr = keys[0].fingerprint
        gpg.start(Model.encryptArgs(home, { recipients: [fpr], signer: fpr }), text, function(enc) {
          check(enc.exitCode === 0 && enc.stdout.indexOf("-----BEGIN PGP MESSAGE-----") === 0, "encrypts via stdin")
          check(enc.stdout.indexOf("Héllo") === -1, "ciphertext has no plaintext")
          gpg.start(Model.decryptArgs(home), enc.stdout, function(dec) {
            var s = Model.decryptSummary(dec.status, dec.exitCode)
            check(dec.stdout === text, "round-trips unicode text")
            check(s.decrypted && s.signatures.length === 1 && s.signatures[0].state === "good", "good signature status streamed from stderr")
            check(root.pinentrySeen, "protected key uses agent/pinentry event without exposing its passphrase")
            check(gpg._active === null && gpg._callback === null, "completion detaches process and callback")
            var started = gpg.start(Model.decryptArgs(home), "x", function() { root.cancelledCallback = true })
            root.cancelledRun = gpg._active
            gpg.cancel()
            check(started, "cancel does not throw")
            check(!gpg.running && gpg._active === null && gpg._callback === null, "cancel detaches process and callback")
            // Clipboard auto-clear compares Qt.md5 with `md5sum` of UTF-8 bytes.
            check(Qt.md5("Héllo ✓\nx") === "7ed94c8c200011b74d5de3c423411f87", "Qt.md5 hashes UTF-8")
            retirementCheck.start()
          })
        })
      })
    })
  }

  Timer {
    id: retirementCheck
    interval: 100
    onTriggered: {
      check(root.cancelledRun === null, "cancelled process/collector is destroyed")
      check(!root.cancelledCallback, "cancelled callback cannot run late")
      done()
    }
  }
}
