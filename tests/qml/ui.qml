// Instantiates the actual plugin without opening its panel or reading keys.
// The runner uses the offscreen platform and a disposable GnuPG home.
import QtQuick
import Quickshell
import "Model.js" as Model

ShellRoot {
  id: root
  property int failures: 0
  function check(ok, label) {
    console.log((ok ? "ok   " : "FAIL ") + label)
    if (!ok) failures++
  }
  // The clipboard's test hook records copies so the harness never touches the
  // desktop clipboard.
  function stubClipboard(panel) {
    var clipboard = find(panel, "pgpClipboard")
    var calls = []
    clipboard.override = function(text, sensitive, completed) {
      calls.push({ text: text, sensitive: sensitive, complete: completed })
    }
    return { clipboard: clipboard, calls: calls }
  }
  function find(object, name, visited) {
    if (!object) return null
    visited = visited || []
    if (visited.indexOf(object) !== -1) return null
    visited.push(object)
    if (object.objectName === name) return object
    var children = []
    if (object.data) for (var i = 0; i < object.data.length; i++) children.push(object.data[i])
    if (object.children) for (var j = 0; j < object.children.length; j++) children.push(object.children[j])
    if (object.contentItem) children.push(object.contentItem)
    for (var k = 0; k < children.length; k++) {
      var found = find(children[k], name, visited)
      if (found) return found
    }
    return null
  }
  Loader {
    id: panelLoader
    source: "Panel.qml"
    onLoaded: {
      item.settings = { gnupgHome: Quickshell.env("OMAPGP_TEST_HOME") }
      Qt.callLater(root.runChecks)
    }
  }
  Timer {
    id: waitForClipboardFailure
    interval: 50
    repeat: true
    onTriggered: {
      var p = panelLoader.item
      if (find(p, "pgpClipboard").pendingCopy) return
      stop()
      check(find(p, "pgpWriteInput").text === "clipboard fixture" && p.copyNotice.indexOf("Could not copy") !== -1,
            "the real clipboard writer reports an unavailable Wayland socket without removing text")
      p.wipe()
      console.log(failures === 0 ? "ui harness passed" : "ui harness FAILED")
      Qt.exit(failures === 0 ? 0 : 1)
    }
  }
  function runChecks() {
    var p = panelLoader.item
    check(!p.opened, "panel remains closed; no real keyring operation")
    check(find(p, "pgpAppTitle").text.indexOf("omaPGP") !== -1, "panel title shows omaPGP")
    var input = find(p, "pgpWriteInput")
    var output = find(p, "pgpReadOutput")
    check(input !== null && output !== null, "actual editors and output views instantiate")
    if (!input || !output) { Qt.exit(1); return }
    var label = find(output, "plainTextOutput")
    check(label && label.readOnly && !label.enabled && !label.selectByMouse, "sensitive output cannot be selected into the primary clipboard")
    check(label.textFormat === TextEdit.PlainText, "output remains plain text")
    output.text = "fixture"
    output.clear()
    check(output.text === "", "output view releases its text")

    input.text = "original"
    var revision = input._revision
    input._applyPaste({exitCode:0, stdout:"é".repeat(Model.MAX_INPUT_BYTES), errorCode:""}, revision, 0, 8)
    check(input.text === "original", "oversized paste rejected before insertion")
    input.text = "new draft"
    input._applyPaste({exitCode:0, stdout:"stale", errorCode:""}, revision, 0, 8)
    check(input.text === "new draft", "stale clipboard result cannot replace edited text")
    input._applyPaste({exitCode:0, stdout:"accepted", errorCode:""}, input._revision, 0, 9)
    check(input.text === "accepted" && input.textArea.cursorPosition === 8, "bounded paste inserts text and places the cursor after it")
    input.clear()
    check(input.text === "" && !input.textArea.canUndo, "clear drops editor text and undo history")

    p.writeOutput = "old ciphertext"
    p.recipients = ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
    check(p.writeOutput === "", "recipient change clears generated output")
    p.writeOutput = "old ciphertext"
    p.signer = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    check(p.writeOutput === "", "signer change clears generated output")
    p.writeOutput = "old ciphertext"
    p.encryptToSelf = !p.encryptToSelf
    check(p.writeOutput === "", "self-recipient change clears generated output")
    p.setMode("write")
    p.keysLoaded = true
    var recipient = { fingerprint: "E".repeat(40), name: "Contact", usable: true, canEncrypt: true, verified: false }
    p.keys = [recipient]
    var recipientPicker = find(p, "pgpRecipientPicker")
    recipientPicker.toggleValue(recipient.fingerprint)
    check(recipientPicker.isSelected(recipient.fingerprint) && p.recipients.indexOf(recipient.fingerprint) !== -1,
          "choosing a recipient updates encryption's selection")
    p.wipe()
    p.setMode("write")
    input.text = "fixture"
    check(!recipientPicker.isSelected(recipient.fingerprint) && p.recipients.length === 0,
          "closing the panel clears both the selected recipient and its visible checkbox")
    recipientPicker.toggleValue(recipient.fingerprint)
    p.encrypt()
    check(recipientPicker.isSelected(recipient.fingerprint) && p.writeError.indexOf("Confirm the unverified recipients") === 0,
          "reselecting a contact reaches the fingerprint warning instead of the empty recipient error")
    p.wipe()
    p.setMode("write")
    p.encryptToSelf = true
    p.keysLoaded = true
    var ownOne = { fingerprint: "A".repeat(40), name: "First", usable: true, canEncrypt: true, canDecrypt: true }
    var ownTwo = { fingerprint: "B".repeat(40), name: "Second", usable: true, canEncrypt: true, canDecrypt: true }
    var picker = find(p, "pgpSelfKeyPicker")
    p.keys = [ownOne, recipient]
    check(p.selfKey === ownOne, "a single personal encryption key is selected automatically")
    recipientPicker.toggleValue(ownOne.fingerprint)
    check(recipientPicker.options[0].description.includes("your key") && p.unverifiedRecipients.length === 0,
          "a personal decryption key is labeled as yours and skips the contact warning")
    recipientPicker.toggleValue(recipient.fingerprint)
    check(p.unverifiedRecipients.length === 1 && p.unverifiedRecipients[0] === recipient,
          "a contact still needs verification when selected alongside your own key")
    p.recipients = []
    p.keys = [ownOne, ownTwo]
    check(p.selfKey === null && picker.options.length === 3, "multiple personal encryption keys require a choice")
    p.writeOutput = "old ciphertext"
    picker.changed(ownTwo.fingerprint)
    check(p.selfKey === ownTwo && p.writeOutput === "", "changing the personal key clears generated output")
    p.keys = [ownOne]
    check(p.selfKey === null, "an unavailable choice does not switch silently to another key")
    p.writeOutput = "old ciphertext"
    input.text = "changed"
    check(p.writeOutput === "", "draft edit clears generated output")
    // Editor copy never reaches the control's built-in clipboard action.
    var clipboard = stubClipboard(p)
    input.text = "selection fixture"
    input.textArea.select(0, 9)
    input.copySelection(false)
    check(clipboard.calls.length === 1 && clipboard.calls[0].text === "selection",
          "editor copy hands the selection to the guarded clipboard path")
    check(clipboard.calls.length === 1 && clipboard.calls[0].sensitive,
          "editor copy is marked sensitive")
    clipboard.calls[0].complete(true)
    check(input.text === "selection fixture", "copying does not alter the draft")
    input.textArea.select(0, 9)
    input.copySelection(true)
    check(clipboard.calls.length === 2 && input.text === "selection fixture", "cut waits for clipboard completion")
    input.copySelection(true)
    check(clipboard.calls.length === 2 && input.text === "selection fixture" && p.copyNotice.indexOf("still finishing") !== -1,
          "a busy clipboard leaves the selection intact")
    clipboard.calls[1].complete(false)
    check(input.text === "selection fixture" && p.copyNotice.indexOf("Could not copy") !== -1, "a failed cut keeps the draft")
    input.copySelection(true)
    input.textArea.select(10, 17)
    clipboard.calls[2].complete(true)
    check(input.text === "selection fixture" && p.copyNotice.indexOf("Copied the selection") !== -1,
          "completion leaves a newer selection intact")
    input.textArea.select(0, 9)
    input.copySelection(true)
    clipboard.calls[3].complete(true)
    check(input.text === " fixture" && p.copyNotice.indexOf("Moved the selection") !== -1, "successful cut removes the original selection")
    clipboard.clipboard.copy("public key fixture", false, "Copied the public key.")
    check(p.copyNotice.indexOf("public key") === -1, "public-key copy does not report success prematurely")
    clipboard.calls[4].complete(false)
    check(p.copyNotice.indexOf("Could not copy") !== -1, "a failed public-key copy reports the failure")

    // Typing past the limit keeps the draft instead of wiping it.
    input.text = "preserved draft"
    var before = input.text
    input.text = before + "x".repeat(Model.MAX_INPUT_CHARS + 1)
    check(input.text === before, "oversized edit reverts and keeps the existing draft")
    input.text = "é".repeat(Model.MAX_INPUT_BYTES / 2)
    check(input.text.length === Model.MAX_INPUT_BYTES / 2, "a multibyte draft exactly at the limit is accepted")
    input.text += "é"
    check(input.text.length === Model.MAX_INPUT_BYTES / 2, "a multibyte edit past the byte limit is reverted")
    input.text = "€" + input.text.slice(1)
    check(input.text.charAt(0) === "é", "a same-length replacement past the byte limit is reverted")

    p.readPlaintext = "fixture"
    output.text = "fixture"
    p.clearReadResult()
    check(p.readPlaintext === "" && output.text === "", "read-result invalidation clears all visible copies")
    input.text = "pending selection"
    input.textArea.select(0, 7)
    input.copySelection(true)
    p.wipe()
    check(clipboard.clipboard.pendingCopy !== null, "closing lets an explicit sensitive clipboard write finish")
    clipboard.calls[5].complete(true)
    check(input.text === "" && p.copyNotice === "" && clipboard.clipboard.pendingCopy === null,
          "closing drops the edit callback and clipboard notice")

    clipboard.calls.length = 0
    p.setMode("write")
    var encrypted = "-----BEGIN PGP MESSAGE-----\n\nfixture\n-----END PGP MESSAGE-----\n"
    input.text = "draft"
    p.writeOutput = encrypted
    check(find(p, "pgpCopyWriteResult").text === "Copy PGP message", "the encrypted result has a distinct copy button")
    var writeView = find(p, "pgpWriteOutput")
    var writeResult = find(writeView, "plainTextOutput")
    writeView.text = encrypted
    writeResult.selectAll()
    check(writeResult.enabled && writeResult.selectByMouse && writeResult.selectedText.length === encrypted.length,
          "the encrypted result can be selected for native Copy")
    p.writeOutputSensitive = true
    check(!writeResult.enabled && !writeResult.selectByMouse, "signed-only text cannot be selected into the primary clipboard")
    p.writeOutputSensitive = false
    input.copyShortcut(false)
    check(clipboard.calls.length === 1 && clipboard.calls[0].text === encrypted && !clipboard.calls[0].sensitive,
          "Ctrl+C without a selection copies the entire armored message")
    clipboard.calls[0].complete(true)
    find(p, "pgpCopyWriteResult").clicked()
    p.wipe()
    check(clipboard.calls.length === 2 && clipboard.clipboard.pendingCopy !== null,
          "an encrypted copy stays queued when the user immediately closes the panel")
    clipboard.calls.pop().complete(true)
    p.setMode("write")
    input.text = "draft"
    p.writeOutput = encrypted
    input.textArea.select(0, 5)
    input.copyShortcut(false)
    check(clipboard.calls.length === 2 && clipboard.calls[1].text === "draft" && clipboard.calls[1].sensitive,
          "Ctrl+C still gives the editor selection priority")
    clipboard.calls[1].complete(true)
    p.setMode("read")
    var readInput = find(p, "pgpReadInput")
    p.readPlaintext = "decrypted fixture"
    readInput.copyShortcut(false)
    readInput.copyShortcut(true)
    check(clipboard.calls.length === 3 && clipboard.calls[2].text === p.readPlaintext && clipboard.calls[2].sensitive,
          "a single copy of decrypted text remains sensitive and ignores key repeats")
    clipboard.calls[2].complete(true)

    p.setMode("keys")
    var contact = { fingerprint: "C".repeat(40), displayUid: "Contact <contact@example.invalid>", uid: "Contact <contact@example.invalid>" }
    var fingerprintInput = find(p, "pgpFingerprintInput")
    var confirm = find(p, "pgpConfirmFingerprint")
    p.keys = [contact]
    p.startVerification(contact)
    check(find(p, "pgpVerificationFingerprint").text.replace(/\s/g, "") === contact.fingerprint && !confirm.enabled,
          "the comparison shows the entire fingerprint and needs a personal certification key to save")
    p.keys = [contact, { fingerprint: "D".repeat(40), usable: true, canCertify: true }]
    fingerprintInput.text = "D".repeat(40)
    check(p.fingerprintCheck === "mismatch" && !confirm.enabled, "a pasted mismatch blocks verification")
    fingerprintInput.text = Model.formatFingerprint(contact.fingerprint).toLowerCase()
    check(p.fingerprintCheck === "match" && confirm.enabled, "a matching fingerprint can be confirmed")
    p.verifyTarget = null
    check(fingerprintInput.text === "", "closing the comparison clears the pasted fingerprint")

    clipboard.clipboard.override = null
    input.text = "clipboard fixture"
    input.textArea.select(0, 9)
    input.copySelection(true)
    var writer = find(p, "pgpClipboardWriter")
    check(writer.command.indexOf("text/plain;charset=utf-8") !== -1 && writer.command.indexOf("--sensitive") !== -1,
          "the actual clipboard command offers UTF-8 text with the sensitive hint")
    waitForClipboardFailure.start()
  }
}
