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
    check(label && typeof label.copy === "undefined" && typeof label.selectAll === "undefined", "sensitive output has no selection/copy API")
    check(label.textFormat === Text.PlainText, "output remains plain text")
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
    check(input.text === "accepted", "bounded paste accepts normal text")
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
    p.encryptToSelf = true
    p.keysLoaded = true
    var ownOne = { fingerprint: "A".repeat(40), name: "First", usable: true, canEncrypt: true, canDecrypt: true }
    var ownTwo = { fingerprint: "B".repeat(40), name: "Second", usable: true, canEncrypt: true, canDecrypt: true }
    var picker = find(p, "pgpSelfKeyPicker")
    p.keys = [ownOne]
    check(p.selfKey === ownOne, "a single personal encryption key is selected automatically")
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
    clipboard.calls[5].complete(true)
    check(input.text === "" && p.copyNotice === "" && clipboard.clipboard.pendingCopy === null,
          "closing drops the edit callback and clipboard notice")

    clipboard.clipboard.override = null
    input.text = "clipboard fixture"
    input.textArea.select(0, 9)
    input.copySelection(true)
    waitForClipboardFailure.start()
  }
}
