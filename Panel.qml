import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The omaPGP panel: Read (decrypt/verify), Write (encrypt/sign), and Keys
// (list/import/export/verify). Every gpg call goes through GpgProcess, which
// passes text through a bounded disposable worker. Close releases references;
// this is not a guarantee of physical memory erasure in Qt/JavaScript.
Panel {
  id: root
  moduleName: "io.github.yaeloss.omapgp"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  property string mode: "read"
  property var keys: []
  property bool keysLoaded: false
  property string keysError: ""

  // gpg asked the agent for a passphrase: step aside so the pinentry window
  // can take the keyboard, then come back when gpg exits.
  property bool pinentryActive: false

  // Read
  property string readPlaintext: ""
  property var readSummary: null
  property string readError: ""
  property bool readHasResult: false
  property string readNotice: ""
  property string copyNotice: ""

  // Write
  // The controls own these values and update them before emitting changed.
  property alias recipients: recipientPicker.values
  property alias signer: signingPicker.value
  property bool encryptToSelf: true
  property string selfKeyFingerprint: ""
  property bool allowUnverified: false
  property string writeOutput: ""
  property string writeError: ""
  property string writeOutputKind: ""
  property bool writeOutputSensitive: false
  property int _readRevision: 0
  property int _writeRevision: 0
  property int _operationEpoch: 0
  property int _keyEpoch: 0
  property string _actionKind: ""
  property bool _ready: false

  // Keys
  property string importMessage: ""
  property bool importOk: false
  property string keysNotice: ""
  property var verifyTarget: null
  readonly property string fingerprintCheck: verifyTarget ? Model.compareFingerprint(verifyInput.text, verifyTarget.fingerprint) : "empty"

  readonly property string homedir: Model.expandHome(root.setting("gnupgHome", ""), Quickshell.env("HOME") || "")
  // A relative folder would land inside the shell's working directory.
  readonly property string homedirError: homedir !== "" && homedir.charAt(0) !== "/"
    ? "The GnuPG home folder setting must be an absolute path, for example ~/.gnupg." : ""
  readonly property int copyClearSeconds: Math.max(0, Number(root.setting("copyClearSeconds", 45)) || 0)
  readonly property bool busy: gpg.running || keyList.running
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(Color.popups.text, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  Component.onCompleted: _ready = true
  onRecipientsChanged: invalidateWrite()
  onSignerChanged: invalidateWrite()
  onEncryptToSelfChanged: invalidateWrite()
  onSelfKeyFingerprintChanged: invalidateWrite()
  onAllowUnverifiedChanged: invalidateWrite()
  onKeysChanged: invalidateWrite()
  onVerifyTargetChanged: if (verifyInput) verifyInput.clear()
  onHomedirChanged: {
    if (!_ready) return
    wipe()
    selfKeyFingerprint = ""
    keys = []
    keysLoaded = false
    if (opened) refreshKeys()
  }

  readonly property var encryptKeys: Model.encryptionKeys(root.keys)
  readonly property var signKeys: Model.signingKeys(root.keys)
  readonly property var certKeys: Model.certificationKeys(root.keys)
  readonly property var selfKeys: Model.personalEncryptionKeys(root.keys)
  readonly property var selfKey: {
    if (root.selfKeyFingerprint) return Model.findKey(root.selfKeys, root.selfKeyFingerprint)
    return root.selfKeys.length === 1 ? root.selfKeys[0] : null
  }
  readonly property var unverifiedRecipients: {
    var out = []
    for (var i = 0; i < root.recipients.length; i++) {
      var k = Model.findKey(root.keys, root.recipients[i])
      if (k && !k.verified && !k.canDecrypt) out.push(k)
    }
    return out
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: {
    if (opened) {
      refreshKeys()
      Qt.callLater(focusMode)
    } else {
      wipe()
    }
  }

  function setMode(next) {
    if (mode === next) return
    mode = next
    verifyTarget = null
    panelScroll.contentY = 0
    Qt.callLater(focusMode)
  }

  function focusMode() {
    if (!root.opened) return
    if (mode === "read") readInput.focusEditor()
    else if (mode === "write") writeInput.focusEditor()
    else if (verifyTarget) verifyInput.forceActiveFocus()
    else importInput.focusEditor()
  }

  // Best-effort release of message references and undo state, called on close.
  function wipe() {
    cancelAction()
    _keyEpoch++
    keyList.cancel()
    pinentryActive = false
    readInput.clear()
    readOutput.clear()
    writeInput.clear()
    writeOutputArea.clear()
    importInput.clear()
    clipboard.detachCopy()
    clearReadResult()
    clearWriteResult()
    recipients = []
    allowUnverified = false
    importMessage = ""
    keysNotice = ""
    verifyTarget = null
    mode = "read"
  }

  function clearReadResult() {
    readPlaintext = ""
    readSummary = null
    readError = ""
    readHasResult = false
    readNotice = ""
    copyNotice = ""
    if (readOutput) readOutput.clear()
  }

  function clearWriteResult() {
    writeOutput = ""
    writeOutputKind = ""
    writeError = ""
    writeOutputSensitive = false
    if (writeOutputArea) writeOutputArea.clear()
  }

  function cancelAction() {
    _operationEpoch++
    _actionKind = ""
    gpg.cancel()
    pinentryActive = false
  }

  function invalidateRead() {
    _readRevision++
    clearReadResult()
    if (_actionKind === "read") cancelAction()
  }

  function invalidateWrite() {
    _writeRevision++
    clearWriteResult()
    if (_actionKind === "write") cancelAction()
  }

  // --- gpg runs ---------------------------------------------------------------

  function runGpg(args, input, callback, kind) {
    if (!args || busy) return false
    if (homedirError) {
      callback({ exitCode: -1, stdout: "", status: [], errorCode: "homedir" })
      return true
    }
    if (input !== null && input !== undefined && Model.inputTooLarge(input)) {
      callback({ exitCode: -1, stdout: "", status: [], errorCode: "input-limit" })
      return true
    }
    var epoch = ++_operationEpoch
    _actionKind = kind || "keys"
    return gpg.start(args, input, function(result) {
      if (epoch !== root._operationEpoch || !root.opened) return
      root._actionKind = ""
      root.pinentryActive = false
      callback(result)
    })
  }

  function refreshKeys(completed) {
    if (keyList.running) return
    if (homedirError) {
      root.keys = []
      root.keysLoaded = false
      root.keysError = homedirError
      if (completed) completed(false)
      return
    }
    var epoch = ++_keyEpoch
    root.keys = []
    root.keysLoaded = false
    var pub = ""
    var steps = []
    steps.push({ args: Model.listKeysArgs(root.homedir, false, true),
                 fallbackArgs: Model.listKeysArgs(root.homedir, false),
                 use: function(r) { pub = r.stdout } })
    steps.push({ args: Model.listKeysArgs(root.homedir, true), use: function(r) {
      root.keys = Model.parseKeys(pub, r.stdout)
      root.keysLoaded = true
      root.keysError = ""
      root.recipients = root.recipients.filter(function(f) { return !!Model.findKey(root.keys, f) })
      if (root.signer && !Model.findKey(root.signKeys, root.signer)) root.signer = ""
    } })
    var i = 0
    var next = function() {
      if (i >= steps.length) {
        if (completed) completed(true)
        return
      }
      var step = steps[i++]
      keyList.start(step.args, null, function(r) {
        if (epoch !== root._keyEpoch || !root.opened) return
        if (step.fallbackArgs && (r.errorCode === "output-limit" || r.errorCode === "timeout")) {
          step.args = step.fallbackArgs
          step.fallbackArgs = null
          i--
          next()
          return
        }
        if (r.errorCode || r.exitCode !== 0) {
          root.keysError = Model.workerFailure(r) || "Could not read the GnuPG keyring" + (root.homedir ? " in " + root.homedir : "") + "."
          if (completed) completed(false)
          return
        }
        step.use(r)
        next()
      })
    }
    next()
  }

  function decrypt() {
    if (busy) return
    var revision = _readRevision
    var text = readInput.text
    clearReadResult()
    var kind = Model.messageKind(text)
    if (kind === "empty") { readError = "Paste a PGP message first."; return }
    if (kind === "public-key" || kind === "private-key") {
      readNotice = "This is a key, not a message."
      return
    }
    if (kind === "detached-signature") { readError = "Detached signatures need the signed file; omaPGP handles text messages."; return }
    runGpg(Model.decryptArgs(root.homedir), text, function(r) {
      if (revision !== root._readRevision) return
      var error = Model.workerFailure(r)
      if (error) { root.readError = error; return }
      var s = Model.decryptSummary(r.status, r.exitCode)
      root.readSummary = s
      root.readHasResult = true
      if (s.error) {
        root.readError = s.error
        root.readPlaintext = ""
      } else {
        root.readPlaintext = r.stdout
        readOutput.text = r.stdout
      }
    }, "read")
  }

  function importFromRead() {
    var text = readInput.text
    setMode("keys")
    importInput.text = text
    readInput.clear()
    clearReadResult()
    importKeys()
  }

  function encrypt() {
    if (busy) return
    clearWriteResult()
    if (!keysLoaded) { writeError = "Load the keyring before encrypting."; return }
    if (writeInput.text === "") { writeError = "Write a message first."; return }
    if (recipients.length === 0) { writeError = "Choose at least one recipient."; return }
    var needsTrustOverride = false
    for (var i = 0; i < recipients.length; i++) {
      var key = Model.findKey(root.keys, recipients[i])
      if (!key || !key.usable || !key.canEncrypt) { writeError = "A selected recipient is no longer available. Choose recipients again."; return }
      if (key.locallyVerified || (key.canDecrypt && !key.verified)) needsTrustOverride = true
    }
    if (unverifiedRecipients.length > 0 && !allowUnverified) {
      writeError = "Confirm the unverified recipients below, or verify them under Keys."
      return
    }
    if (encryptToSelf && !selfKey && (selfKeys.length > 0 || selfKeyFingerprint)) {
      writeError = selfKeys.length > 0 ? "Choose a personal key for your copy, or turn off Encrypt to myself too."
        : "Your personal encryption key is unavailable. Turn off Encrypt to myself too to continue."
      return
    }
    var to = recipients.slice()
    if (encryptToSelf && selfKey) {
      if (to.indexOf(selfKey.fingerprint) === -1) to.push(selfKey.fingerprint)
      if (!selfKey.verified) needsTrustOverride = true
    }
    // Every recipient has been checked above. A personal key or a locally
    // certified contact can need a trust override for this request alone.
    var request = { revision: _writeRevision, signer: signer, recipients: to,
                    allowUnverified: allowUnverified || needsTrustOverride }
    var args = Model.encryptArgs(root.homedir, request)
    runGpg(args, writeInput.text, function(r) {
      if (request.revision !== root._writeRevision) return
      var error = Model.workerFailure(r)
      if (error) { root.writeError = error; return }
      if (Model.writeSucceeded(r, request.signer !== "", true)) {
        root.writeOutput = r.stdout
        root.writeOutputKind = request.signer ? "Encrypted and signed" : "Encrypted"
        writeOutputArea.text = r.stdout
      } else {
        root.writeError = Model.encryptFailure(r.status).message
      }
    }, "write")
  }

  function signOnly() {
    if (busy) return
    clearWriteResult()
    if (writeInput.text === "") { writeError = "Write a message first."; return }
    if (!signer) { writeError = "Choose a key under “Sign as” first."; return }
    var request = { revision: _writeRevision, signer: signer }
    runGpg(Model.clearsignArgs(root.homedir, request.signer), writeInput.text, function(r) {
      if (request.revision !== root._writeRevision) return
      var error = Model.workerFailure(r)
      if (error) { root.writeError = error; return }
      if (Model.writeSucceeded(r, true, false)) {
        root.writeOutput = r.stdout
        root.writeOutputKind = "Signed (not encrypted)"
        root.writeOutputSensitive = true
        writeOutputArea.text = r.stdout
      } else {
        root.writeError = Model.encryptFailure(r.status).message
      }
    }, "write")
  }

  function importKeys() {
    if (busy) return
    importMessage = ""
    var text = importInput.text
    var kind = Model.messageKind(text)
    if (kind !== "public-key" && kind !== "private-key") {
      importOk = false
      importMessage = "Paste an ASCII-armored key block (-----BEGIN PGP PUBLIC KEY BLOCK-----)."
      return
    }
    runGpg(Model.importArgs(root.homedir), text, function(r) {
      var error = Model.workerFailure(r)
      if (error) { root.importOk = false; root.importMessage = error; root.refreshKeys(); return }
      var s = Model.importSummary(r.status)
      root.importOk = s.ok && r.exitCode === 0
      root.importMessage = s.message
      if (s.ok) importInput.clear()
      root.refreshKeys()
    })
  }

  function copyPublicKey(key) {
    if (busy) return
    keysNotice = ""
    copyNotice = ""
    runGpg(Model.exportArgs(root.homedir, key.fingerprint), null, function(r) {
      if (r.exitCode === 0 && r.stdout.indexOf("-----BEGIN PGP PUBLIC KEY BLOCK-----") !== -1) {
        if (!clipboard.copy(r.stdout, false, "Copied the public key for " + Model.keyLabel(key) + "."))
          root.copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
      } else {
        root.keysNotice = Model.workerFailure(r) || "Could not export that key."
      }
    })
  }

  function startVerification(key) {
    keysNotice = ""
    verifyTarget = key
    panelScroll.contentY = 0
    Qt.callLater(function() {
      if (root.opened && root.verifyTarget === key) verifyInput.forceActiveFocus()
    })
  }

  function verifyKey(key) {
    if (busy || !key || !key.uid || certKeys.length === 0) return
    if (fingerprintCheck !== "empty" && fingerprintCheck !== "match") return
    keysNotice = ""
    var certKey = Model.findKey(certKeys, signer) || certKeys[0]
    var args = Model.lsignArgs(root.homedir, key.fingerprint, certKey.fingerprint, key.uid)
    if (!args) { keysNotice = "GnuPG cannot use this contact’s identity for verification."; return }
    runGpg(args, null, function(r) {
      if (r.exitCode !== 0 || r.errorCode) {
        root.keysNotice = Model.verificationFailure(r)
        root.refreshKeys()
        return
      }
      root.refreshKeys(function(loaded) {
        var refreshedKey = loaded ? Model.findKey(root.keys, key.fingerprint) : null
        if (Model.isVerifiedUid(refreshedKey, key.uid)) {
          root.verifyTarget = null
          root.keysNotice = key.displayUid + " is now marked as verified on this computer."
        } else {
          root.keysNotice = "Could not confirm that this identity was verified."
        }
      })
    })
  }

  function copyTimeoutNotice(text) {
    return root.copyClearSeconds > 0
      ? text + " The clipboard will be cleared in " + root.copyClearSeconds + " seconds."
      : text
  }

  function copyPlaintext() {
    if (readPlaintext === "") return
    copyNotice = ""
    if (!clipboard.copy(readPlaintext, true, copyTimeoutNotice("Copied the decrypted text.")))
      copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
  }

  function copyWriteOutput() {
    if (writeOutput === "") return
    copyNotice = ""
    var copied = writeOutputSensitive
      ? clipboard.copy(writeOutput, true, copyTimeoutNotice("Copied the signed message."))
      : clipboard.copy(writeOutput, false, "Copied the encrypted message.")
    if (!copied) copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
  }

  function copyActiveOutput(repeating) {
    if (busy) return false
    if (mode === "read" && readPlaintext !== "") {
      if (!repeating) copyPlaintext()
      return true
    }
    if (mode === "write" && writeOutput !== "") {
      if (!repeating) copyWriteOutput()
      return true
    }
    return false
  }

  function copyEditorText(text, cut, completed) {
    if (text === "") return
    copyNotice = ""
    var notice = copyTimeoutNotice(cut ? "Moved the selection to the clipboard." : "Copied the selection.")
    if (!clipboard.copy(text, true, notice, completed))
      copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
  }

  GpgProcess {
    id: gpg
    onPinentryLaunched: root.pinentryActive = true
  }

  GpgProcess {
    id: keyList
  }

  // Clipboard writes go through wl-copy's stdin. Decrypted text, drafts and
  // pasted keys are marked sensitive and cleared after a delay if the clipboard
  // still holds them.
  Item {
    id: clipboard
    objectName: "pgpClipboard"

    // The UI harness supplies a writer so it can test completion without Wayland.
    property var override: null
    property var pendingCopy: null
    property string pendingHash: ""

    function detachCopy() {
      if (!pendingCopy) return
      // A requested copy can finish while the user switches to the paste target.
      pendingCopy.completed = null
      pendingCopy.notice = ""
    }

    function copy(text, sensitive, notice, completed) {
      if (text === "" || pendingCopy || copyProc.running || checkCopyProc.running) return false
      var request = { hash: Qt.md5(text), sensitive: sensitive, written: false, notice: notice, completed: completed || null }
      pendingCopy = request
      if (override) {
        override(text, sensitive, function(success) {
          if (clipboard.pendingCopy === request) clipboard.finish(success)
        })
        return true
      }
      copyProc.payload = text
      // MIME detection can classify armored PGP as binary. Offer it as text
      // so editors and chat inputs can paste it like any other text.
      copyProc.command = sensitive
        ? ["/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8", "--sensitive"]
        : ["/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8"]
      copyProc.stdinEnabled = true
      copyDeadline.restart()
      copyProc.running = true
      return true
    }

    function verifyCopy() {
      if (!pendingCopy) return
      pendingCopy.written = true
      checkCopyProc.expectedHash = pendingCopy.hash
      checkCopyProc.stdinEnabled = true
      checkCopyProc.running = true
    }

    function finish(success, failure) {
      var request = pendingCopy
      if (!request) return
      pendingCopy = null
      copyDeadline.stop()
      copyProc.payload = ""
      checkCopyProc.expectedHash = ""
      if (success || request.written) {
        clearTimer.stop()
        pendingHash = ""
        if (request.sensitive && root.copyClearSeconds > 0) {
          pendingHash = request.hash
          clearTimer.interval = root.copyClearSeconds * 1000
          clearTimer.restart()
        }
      }
      if (!request.notice) return
      if (!success) {
        root.copyNotice = failure || "Could not copy to the system clipboard. Try Copy again."
      } else if (request.completed && !request.completed()) {
        root.copyNotice = root.copyTimeoutNotice("Copied the selection.")
      } else {
        root.copyNotice = request.notice
      }
    }

    Timer {
      id: copyDeadline
      interval: 5000
      onTriggered: {
        clipboard.finish(false)
        if (copyProc.running) copyProc.running = false
        if (checkCopyProc.running) checkCopyProc.running = false
      }
    }

    Process {
      id: copyProc
      objectName: "pgpClipboardWriter"
      property string payload: ""
      onStarted: {
        write(payload)
        payload = ""
        stdinEnabled = false
      }
      onExited: function(exitCode, exitStatus) {
        if (exitCode === 0 && exitStatus === 0) clipboard.verifyCopy()
        else clipboard.finish(false)
      }
    }

    Process {
      id: checkCopyProc
      property string expectedHash: ""
      command: ["/usr/bin/bash", "-o", "pipefail", "-c",
                "IFS= read -r want && have=$(/usr/bin/timeout 3 /usr/bin/wl-paste --type text --no-newline | /usr/bin/md5sum) && [[ ${have%% *} == \"$want\" ]]"]
      onStarted: {
        write(expectedHash + "\n")
        expectedHash = ""
        stdinEnabled = false
      }
      onExited: function(exitCode, exitStatus) {
        clipboard.finish(exitCode === 0 && exitStatus === 0, "Could not confirm the clipboard contains the copied text. Try Copy again.")
      }
    }

    Timer {
      id: clearTimer
      repeat: false
      onTriggered: {
        clearProc.hash = clipboard.pendingHash
        clipboard.pendingHash = ""
        clearProc.stdinEnabled = true
        clearProc.running = true
      }
    }

    // Compares hashes so a clipboard the user has since replaced is left alone.
    Process {
      id: clearProc
      property string hash: ""
      command: ["sh", "-c", "read -r want; have=$(wl-paste --no-newline 2>/dev/null | md5sum | cut -d' ' -f1); [ \"$have\" = \"$want\" ] && wl-copy --clear; exit 0"]
      onStarted: {
        write(hash + "\n")
        hash = ""
        stdinEnabled = false
      }
    }
  }

  // --- view -----------------------------------------------------------------------

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }

  component Message: Text {
    property string tone: "info"
    textFormat: Text.PlainText
    color: tone === "bad" ? Color.urgent : (tone === "good" ? Color.accent : root.fg)
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
    visible: text !== ""
  }

  component ActionButton: Button {
    enabled: !root.busy
    bordered: true
    focusable: true
    fontFamily: root.fontFamily
    foreground: root.fg
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened && !root.pinentryActive
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    onOpenChanged: if (open) Qt.callLater(root.focusMode)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      // PanelKeyCatcher would own these keys, but the editors need Tab, arrows
      // and Shift-selection for editing, so the panel keeps its own catcher and
      // mirrors the signals it would otherwise get.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.verifyTarget) root.verifyTarget = null
          else root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          var forward = event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)
          root.switchPanel(forward ? 1 : -1)
          event.accepted = true
        } else if (event.matches(StandardKey.Copy)) {
          event.accepted = root.copyActiveOutput(event.isAutoRepeat)
        } else if (event.modifiers & Qt.ControlModifier) {
          if (event.key === Qt.Key_1) { root.setMode("read"); event.accepted = true }
          else if (event.key === Qt.Key_2) { root.setMode("write"); event.accepted = true }
          else if (event.key === Qt.Key_3) { root.setMode("keys"); event.accepted = true }
        }
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        interactive: contentHeight > height

        Column {
          id: content
          width: parent.width
          spacing: Style.spacing.lg

          // Header
          Item {
            width: parent.width
            implicitHeight: Math.max(title.implicitHeight, tabs.implicitHeight)

            Column {
              id: title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                objectName: "pgpAppTitle"
                textFormat: Text.PlainText
                text: "󰌾  omaPGP"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Caption {
                text: root.busy ? "Working…" : "Local only · " + (root.homedir || "~/.gnupg")
              }
            }

            ButtonGroup {
              id: tabs
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              fontFamily: root.fontFamily
              foreground: root.fg
              background: "transparent"
              value: root.mode
              options: [
                { value: "read", label: "Read", tooltip: "Decrypt and verify (Ctrl+1)" },
                { value: "write", label: "Write", tooltip: "Encrypt and sign (Ctrl+2)" },
                { value: "keys", label: "Keys", tooltip: "Your keyring (Ctrl+3)" }
              ]
              onChanged: function(value) { root.setMode(value) }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- Read ------------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.mode === "read"

            PgpTextArea {
              id: readInput
              objectName: "pgpReadInput"
              enabled: !root.busy
              width: parent.width
              height: Style.space(140)
              placeholderText: "Paste a PGP message or signed text, then press Ctrl+Enter"
              onCopyRequested: function(text, cut, completed) { root.copyEditorText(text, cut, completed) }
              onCopyWithoutSelectionRequested: root.copyActiveOutput(false)
              onSubmitRequested: root.decrypt()
              onTextChanged: root.invalidateRead()
              onInputRejected: function(message) { root.readError = message }
            }

            Row {
              spacing: Style.spacing.md
              ActionButton {
                text: "Decrypt / Verify"
                iconText: "󰌿"
                onClicked: root.decrypt()
              }
              ActionButton {
                text: "Paste"
                onClicked: readInput.pasteClipboard()
              }
              ActionButton {
                text: "Clear"
                onClicked: { readInput.clear(); readOutput.clear(); root.clearReadResult(); readInput.focusEditor() }
              }
            }

            Message { width: parent.width; tone: "bad"; text: root.readError }

            Repeater {
              model: root.readSummary ? root.readSummary.warnings : []
              delegate: Message {
                required property string modelData
                width: parent.width
                tone: "bad"
                text: "!  " + modelData
              }
            }

            Row {
              spacing: Style.spacing.md
              visible: root.readNotice === "This is a key, not a message."
              Message { anchors.verticalCenter: parent.verticalCenter; text: root.readNotice }
              ActionButton { text: "Import it"; onClicked: root.importFromRead() }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.readHasResult && root.readSummary !== null

              Message {
                width: parent.width
                text: root.readSummary && root.readSummary.encrypted && root.readSummary.decrypted
                  ? "󰌿  Decrypted" : ""
              }

              Repeater {
                model: root.readSummary ? root.readSummary.signatures : []
                delegate: Message {
                  required property var modelData
                  width: parent.width
                  tone: Model.signatureTone(modelData, root.keys)
                  text: (tone === "good" ? "✓  " : (tone === "bad" ? "✗  " : "!  ")) + Model.signatureText(modelData, root.keys)
                }
              }

              Message {
                width: parent.width
                tone: "info"
                text: root.readSummary && root.readSummary.signatures.length === 0 && root.readPlaintext !== ""
                  ? "!  Not signed: you can't tell who wrote this." : ""
              }
            }

            PgpTextView {
              id: readOutput
              objectName: "pgpReadOutput"
              width: parent.width
              height: Style.space(140)
              visible: root.readPlaintext !== ""
            }

            ActionButton {
              visible: root.readPlaintext !== ""
              text: "Copy decrypted text"
              iconText: "󰆏"
              tooltipText: "Copy this result (Ctrl+C)"
              onClicked: root.copyPlaintext()
            }
            Caption { width: parent.width; visible: text !== ""; text: root.copyNotice }
          }

          // ---- Write -----------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.mode === "write"

            Row {
              width: parent.width
              spacing: Style.spacing.lg

              MultiSelect {
                id: recipientPicker
                objectName: "pgpRecipientPicker"
                enabled: !root.busy
                width: (parent.width - parent.spacing) / 2
                label: "To"
                placeholderText: "Search recipients..."
                noSelectionText: "Choose recipients"
                emptyText: "No public keys. Import one under Keys."
                fontFamily: root.fontFamily
                options: root.encryptKeys.map(function(k) {
                  return { value: k.fingerprint, label: Model.keyLabel(k),
                           description: Model.shortFingerprint(k.fingerprint) + " · " + (k.canDecrypt ? "your key" : Model.keyVerificationLabel(k)) }
                })
                onChanged: root.allowUnverified = false
              }

              Dropdown {
                id: signingPicker
                enabled: !root.busy
                width: (parent.width - parent.spacing) / 2
                label: "Sign as"
                fontFamily: root.fontFamily
                value: ""
                options: [{ value: "", label: "Don't sign" }].concat(root.signKeys.map(function(k) {
                  return { value: k.fingerprint, label: Model.keyLabel(k) }
                }))
              }
            }

            Toggle {
              enabled: !root.busy
              width: parent.width
              visible: root.keysLoaded && (root.selfKeys.length > 0 || root.selfKeyFingerprint !== "")
              label: "Encrypt to myself too"
              description: root.selfKey ? "Read it later with " + Model.keyLabel(root.selfKey) + "." : ""
              checked: root.encryptToSelf
              fontFamily: root.fontFamily
              onClicked: root.encryptToSelf = !root.encryptToSelf
            }

            Dropdown {
              objectName: "pgpSelfKeyPicker"
              enabled: !root.busy
              visible: root.keysLoaded && root.encryptToSelf && root.selfKeys.length > 0 &&
                       (root.selfKeys.length > 1 || !root.selfKey)
              width: parent.width
              label: "Personal encryption key"
              fontFamily: root.fontFamily
              value: root.selfKey ? root.selfKey.fingerprint : ""
              options: [{ value: "", label: "Choose a personal key" }].concat(root.selfKeys.map(function(key) {
                return { value: key.fingerprint, label: Model.keyLabel(key) + " · " + Model.shortFingerprint(key.fingerprint) }
              }))
              onChanged: function(value) { root.selfKeyFingerprint = value }
            }

            Caption {
              visible: root.keysLoaded && root.selfKeys.length === 0
              width: parent.width
              text: "No personal encryption key is available. Import your own key pair under Keys to keep a readable copy."
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.unverifiedRecipients.length > 0

              Message {
                width: parent.width
                tone: "bad"
                text: "!  Not verified: " + root.unverifiedRecipients.map(function(k) {
                  return Model.keyLabel(k) + " (" + Model.shortFingerprint(k.fingerprint) + ")"
                }).join(", ") + ". Make sure these keys really belong to them."
              }

              Toggle {
                enabled: !root.busy
                width: parent.width
                label: "I've checked the fingerprints; encrypt anyway"
                description: "Applies to this message only. To verify a key permanently, use Keys → Verify."
                checked: root.allowUnverified
                fontFamily: root.fontFamily
                onClicked: root.allowUnverified = !root.allowUnverified
              }
            }

            PgpTextArea {
              id: writeInput
              objectName: "pgpWriteInput"
              onCopyRequested: function(text, cut, completed) { root.copyEditorText(text, cut, completed) }
              onCopyWithoutSelectionRequested: root.copyActiveOutput(false)
              enabled: !root.busy
              width: parent.width
              height: Style.space(140)
              placeholderText: "Write your message. Ctrl+Enter encrypts it"
              onSubmitRequested: root.encrypt()
              onTextChanged: root.invalidateWrite()
              onInputRejected: function(message) { root.writeError = message }
            }

            Row {
              spacing: Style.spacing.md
              ActionButton {
                text: "Encrypt"
                iconText: "󰌾"
                onClicked: root.encrypt()
              }
              ActionButton {
                text: "Sign only"
                iconText: "󰏫"
                onClicked: root.signOnly()
              }
              ActionButton {
                text: "Paste"
                onClicked: writeInput.pasteClipboard()
              }
              ActionButton {
                text: "Clear"
                onClicked: { writeInput.clear(); writeOutputArea.clear(); root.clearWriteResult(); writeInput.focusEditor() }
              }
            }

            Message { width: parent.width; tone: "bad"; text: root.writeError }

            Caption {
              width: parent.width
              visible: root.writeOutput !== ""
              text: root.writeOutputKind
            }

            ActionButton {
              objectName: "pgpCopyWriteResult"
              visible: root.writeOutput !== ""
              text: root.writeOutputSensitive ? "Copy signed message" : "Copy PGP message"
              iconText: "󰆏"
              tooltipText: "Copy this result (Ctrl+C)"
              onClicked: root.copyWriteOutput()
            }

            Caption { width: parent.width; text: root.copyNotice }

            PgpTextView {
              id: writeOutputArea
              objectName: "pgpWriteOutput"
              width: parent.width
              height: Style.space(120)
              visible: root.writeOutput !== ""
              selectable: !root.writeOutputSensitive
              onCopyAllRequested: root.copyWriteOutput()
            }
          }

          // ---- Keys ------------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.mode === "keys"

            Message { width: parent.width; tone: "bad"; text: root.keysError }
            Message { width: parent.width; text: root.keysNotice }

            Caption {
              width: parent.width
              visible: root.keysLoaded && root.keys.length === 0
              text: "No keys yet. Paste a public key below to import it, or import your own key pair."
            }

            Caption {
              width: parent.width
              visible: root.verifyTarget === null && root.keys.some(function(key) {
                return !key.hasSecret && !key.verified && key.usable && key.uid !== ""
              })
              text: "Select Verify beside a contact to compare their full fingerprint."
            }

            BorderSurface {
              objectName: "pgpVerifyCard"
              width: parent.width
              visible: root.verifyTarget !== null
              implicitHeight: verifyCol.implicitHeight + Style.spacing.lg * 2
              radius: Style.cornerRadius
              color: "transparent"
              borderSpec: Border.controlSpec("focus", root.fg, Color.accent)

              Column {
                id: verifyCol
                anchors.fill: parent
                anchors.margins: Style.spacing.lg
                spacing: Style.spacing.md

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.verifyTarget ? "Verify " + root.verifyTarget.displayUid : ""
                  wrapMode: Text.Wrap
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Message {
                  width: parent.width
                  text: "Ask your contact for their full fingerprint in person, by phone, or through a channel you already trust."
                }

                Text {
                  objectName: "pgpVerificationFingerprint"
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.verifyTarget ? Model.formatFingerprint(root.verifyTarget.fingerprint) : ""
                  wrapMode: Text.Wrap
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Caption {
                  width: parent.width
                  text: "Compare every group above, or paste the fingerprint they gave you."
                }

                TextField {
                  id: verifyInput
                  objectName: "pgpFingerprintInput"
                  width: parent.width
                  enabled: !root.busy
                  maximumLength: 160
                  placeholderText: "Paste their full fingerprint (optional)"
                  foreground: root.fg
                  font.family: root.fontFamily
                }

                Message {
                  width: parent.width
                  tone: root.fingerprintCheck === "match" ? "good" : "bad"
                  text: {
                    if (root.fingerprintCheck === "match") return "The fingerprints match."
                    if (root.fingerprintCheck === "mismatch") return "The fingerprints differ. Check with your contact before verifying."
                    if (root.fingerprintCheck === "incomplete") return "Enter the full fingerprint, with or without spaces."
                    return ""
                  }
                }

                Caption {
                  width: parent.width
                  text: root.keysLoaded && root.certKeys.length === 0
                    ? "To save verification, import your own private primary key or connect the security key that holds it."
                    : "Confirm only if the full fingerprint matches. Verification is saved in your local keyring."
                }

                Row {
                  spacing: Style.spacing.md
                  ActionButton {
                    objectName: "pgpConfirmFingerprint"
                    enabled: !root.busy && root.certKeys.length > 0 && (root.fingerprintCheck === "empty" || root.fingerprintCheck === "match")
                    text: "Confirm match and verify"
                    onClicked: root.verifyKey(root.verifyTarget)
                  }
                  ActionButton {
                    text: "Cancel"
                    onClicked: root.verifyTarget = null
                  }
                }
              }
            }

            ListView {
              id: keyView
              width: parent.width
              height: Math.min(contentHeight, Style.space(230))
              clip: true
              spacing: Style.spacing.sm
              boundsBehavior: Flickable.StopAtBounds
              model: root.keys
              visible: root.keys.length > 0 && root.verifyTarget === null

              delegate: BorderSurface {
                id: keyRow
                required property var modelData
                width: keyView.width
                implicitHeight: keyCol.implicitHeight + Style.spacing.lg * 2
                radius: Style.cornerRadius
                color: Style.controlFill(false, false, root.fg, Color.accent)
                borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

                Column {
                  id: keyCol
                  anchors.left: parent.left
                  anchors.right: keyButtons.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.controlPaddingX
                  anchors.rightMargin: Style.spacing.md
                  spacing: Style.spacing.xxs

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: Model.keyLabel(keyRow.modelData)
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Caption {
                    width: parent.width
                    text: [
                      keyRow.modelData.hasSecret ? "your key" : "public key",
                      !keyRow.modelData.usable ? Model.validityLabel(keyRow.modelData.validity)
                        : keyRow.modelData.hasSecret ? "" : Model.keyVerificationLabel(keyRow.modelData),
                      keyRow.modelData.canEncrypt ? "" : "can't encrypt"
                    ].filter(function(s) { return s !== "" }).join(" · ")
                  }

                  Caption {
                    width: parent.width
                    text: Model.formatFingerprint(keyRow.modelData.fingerprint)
                  }
                }

                Row {
                  id: keyButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.spacing.md
                  spacing: Style.spacing.sm

                  ActionButton {
                    visible: !keyRow.modelData.hasSecret && !keyRow.modelData.verified && keyRow.modelData.usable && keyRow.modelData.uid !== ""
                    text: "Verify…"
                    tooltipText: "Compare the full fingerprint with this contact"
                    onClicked: root.startVerification(keyRow.modelData)
                  }
                  ActionButton {
                    iconText: "󰆏"
                    tooltipText: "Copy public key"
                    onClicked: root.copyPublicKey(keyRow.modelData)
                  }
                }
              }
            }

            Caption {
              width: parent.width
              visible: root.verifyTarget === null && root.keys.some(function(key) { return key.hasSecret })
              text: "To help someone verify your key, share its full fingerprint in person, by phone, or through a channel they already trust."
            }

            PanelSectionHeader {
              text: "IMPORT KEYS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            PgpTextArea {
              id: importInput
              onCopyRequested: function(text, cut, completed) { root.copyEditorText(text, cut, completed) }
              enabled: !root.busy
              width: parent.width
              height: Style.space(100)
              placeholderText: "Paste an ASCII-armored public or private key block, then press Ctrl+Enter"
              onSubmitRequested: root.importKeys()
              onInputRejected: function(message) { root.importOk = false; root.importMessage = message }
            }

            Row {
              spacing: Style.spacing.md
              ActionButton {
                text: "Import"
                iconText: "󰋺"
                onClicked: root.importKeys()
              }
              ActionButton {
                text: "Paste"
                onClicked: importInput.pasteClipboard()
              }
              ActionButton {
                text: "Refresh"
                onClicked: root.refreshKeys()
              }
            }

            Message {
              width: parent.width
              tone: root.importOk ? "good" : "bad"
              text: root.importMessage
            }

            Caption {
              width: parent.width
              text: "GnuPG keeps any existing key passphrase protection and asks for it in its own window. Importing an unprotected key does not add a passphrase."
            }

            Caption { width: parent.width; text: root.copyNotice }
          }
        }
      }
    }
  }
}
