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
  property bool copyArmed: false

  // Write
  property var recipients: []
  property string signer: ""
  property bool encryptToSelf: true
  property bool allowUnverified: false
  property string writeOutput: ""
  property string writeError: ""
  property string writeOutputKind: ""
  property bool writeOutputSensitive: false
  property bool writeCopyArmed: false
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
  onAllowUnverifiedChanged: invalidateWrite()
  onKeysChanged: invalidateWrite()
  onHomedirChanged: {
    if (!_ready) return
    wipe()
    keys = []
    keysLoaded = false
    if (opened) refreshKeys()
  }

  readonly property var encryptKeys: Model.encryptionKeys(root.keys)
  readonly property var signKeys: Model.signingKeys(root.keys)
  readonly property var selfKey: {
    var own = root.signer ? Model.findKey(root.keys, root.signer) : null
    if (own && own.canEncrypt) return own
    for (var i = 0; i < root.signKeys.length; i++) if (root.signKeys[i].canEncrypt) return root.signKeys[i]
    return null
  }
  readonly property var unverifiedRecipients: {
    var out = []
    for (var i = 0; i < root.recipients.length; i++) {
      var k = Model.findKey(root.keys, root.recipients[i])
      if (k && !k.verified) out.push(k)
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
    Qt.callLater(focusMode)
  }

  function focusMode() {
    if (!root.opened) return
    if (mode === "read") readInput.focusEditor()
    else if (mode === "write") writeInput.focusEditor()
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
    clipboard.dropPayload()
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
    copyArmed = false
    if (readOutput) readOutput.clear()
  }

  function clearWriteResult() {
    writeOutput = ""
    writeOutputKind = ""
    writeError = ""
    writeOutputSensitive = false
    writeCopyArmed = false
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

  function refreshKeys() {
    if (keyList.running) return
    if (homedirError) {
      root.keys = []
      root.keysLoaded = false
      root.keysError = homedirError
      return
    }
    var epoch = ++_keyEpoch
    root.keys = []
    root.keysLoaded = false
    var pub = ""
    var steps = []
    steps.push({ args: Model.listKeysArgs(root.homedir, false), use: function(r) { pub = r.stdout } })
    steps.push({ args: Model.listKeysArgs(root.homedir, true), use: function(r) {
      root.keys = Model.parseKeys(pub, r.stdout)
      root.keysLoaded = true
      root.keysError = ""
      root.recipients = root.recipients.filter(function(f) { return !!Model.findKey(root.keys, f) })
      if (root.signer && !Model.findKey(root.signKeys, root.signer)) root.signer = ""
    } })
    var i = 0
    var next = function() {
      if (i >= steps.length) return
      var step = steps[i++]
      keyList.start(step.args, null, function(r) {
        if (epoch !== root._keyEpoch || !root.opened) return
        if (r.errorCode || r.exitCode !== 0) {
          root.keysError = Model.workerFailure(r) || "Could not read the GnuPG keyring" + (root.homedir ? " in " + root.homedir : "") + "."
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
    for (var i = 0; i < recipients.length; i++) {
      var key = Model.findKey(root.keys, recipients[i])
      if (!key || !key.usable || !key.canEncrypt) { writeError = "A selected recipient is no longer available. Choose recipients again."; return }
    }
    if (unverifiedRecipients.length > 0 && !allowUnverified) {
      writeError = "Confirm the unverified recipients below, or verify them under Keys."
      return
    }
    var to = recipients.slice()
    if (encryptToSelf && selfKey && to.indexOf(selfKey.fingerprint) === -1) to.push(selfKey.fingerprint)
    var request = { revision: _writeRevision, signer: signer, recipients: to.slice(), allowUnverified: allowUnverified }
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
    runGpg(Model.exportArgs(root.homedir, key.fingerprint), null, function(r) {
      if (r.exitCode === 0 && r.stdout.indexOf("-----BEGIN PGP PUBLIC KEY BLOCK-----") !== -1) {
        if (clipboard.copy(r.stdout, false, "Copied the public key for " + Model.keyLabel(key) + "."))
          root.keysNotice = "Copied the public key for " + Model.keyLabel(key) + "."
      } else {
        root.keysNotice = Model.workerFailure(r) || "Could not export that key."
      }
    })
  }

  function verifyKey(key) {
    if (busy || !key || !key.uid) return
    keysNotice = ""
    var signWith = signer || (signKeys.length > 0 ? signKeys[0].fingerprint : "")
    runGpg(Model.lsignArgs(root.homedir, key.fingerprint, signWith, key.displayUid || key.uid), null, function(r) {
      root.verifyTarget = null
      root.keysNotice = r.exitCode === 0
        ? Model.keyLabel(key) + " is now marked as verified on this computer."
        : Model.workerFailure(r) || "Could not verify that identity (cancelled, or your key needs its passphrase)."
      root.refreshKeys()
    })
  }

  function copyTimeoutNotice(text) {
    return root.copyClearSeconds > 0
      ? text + " The clipboard will be cleared in " + root.copyClearSeconds + " seconds."
      : text
  }

  function copyPlaintext() {
    if (!copyArmed) { copyArmed = true; copyArmTimer.restart(); return }
    copyArmed = false
    copyNotice = ""
    if (readPlaintext !== "" && !clipboard.copy(readPlaintext, true, copyTimeoutNotice("Copied the decrypted text.")))
      copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
  }

  function copyWriteOutput() {
    if (writeOutput === "") return
    if (writeOutputSensitive && !writeCopyArmed) { writeCopyArmed = true; copyArmTimer.restart(); return }
    writeCopyArmed = false
    var copied = writeOutputSensitive
      ? clipboard.copy(writeOutput, true, copyTimeoutNotice("Copied the signed message."))
      : clipboard.copy(writeOutput, false, "Copied the encrypted message.")
    if (!copied) copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
  }

  // Editors hold drafts and pasted keys, so their Copy/Cut use the same
  // guarded path rather than the control's built-in clipboard action.
  function copyEditorText(text, cut) {
    if (text === "") return
    copyNotice = ""
    if (!clipboard.copy(text, true, copyTimeoutNotice(cut ? "Moved the selection to the clipboard." : "Copied the selection.")))
      copyNotice = "Another clipboard operation is still finishing. Try again in a moment."
  }

  Timer {
    id: copyArmTimer
    interval: 5000
    onTriggered: { root.copyArmed = false; root.writeCopyArmed = false }
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

    property var calls: []
    // Test hook: the QML harness records copies instead of touching the real
    // desktop clipboard. Null in normal use.
    property var override: null

    property string pendingHash: ""
    property string pendingText: ""
    property bool pendingSensitive: false
    property string pendingNotice: ""

    function dropPayload() {
      copyProc.payload = ""
      if (copyProc.running) copyProc.running = false
      pendingText = ""
      pendingNotice = ""
      pendingSensitive = false
    }

    function copy(text, sensitive, notice) {
      if (text === "" || copyProc.running) return false
      if (override) { override(text, sensitive, notice || ""); return true }
      calls.push([text, sensitive, notice || ""])
      copyProc.payload = text
      copyProc.command = sensitive ? ["wl-copy", "--sensitive"] : ["wl-copy"]
      copyProc.stdinEnabled = true
      clipboard.pendingText = text
      clipboard.pendingSensitive = sensitive
      clipboard.pendingNotice = notice || "Copied to the clipboard."
      copyProc.running = true
      return true
    }

    Process {
      id: copyProc
      property string payload: ""
      onStarted: {
        write(payload)
        payload = ""
        stdinEnabled = false
      }
      // wl-copy forks on success, so a still-running process here is a failure.
      onExited: {
        if (exitCode === 0) {
          root.copyNotice = clipboard.pendingNotice
          if (clipboard.pendingSensitive && root.copyClearSeconds > 0) {
            clipboard.pendingHash = Qt.md5(clipboard.pendingText)
            clearTimer.interval = root.copyClearSeconds * 1000
            clearTimer.restart()
          }
        } else {
          root.copyNotice = "Could not copy to the clipboard. Is wl-clipboard installed?"
        }
        clipboard.pendingText = ""
        clipboard.pendingNotice = ""
        clipboard.pendingSensitive = false
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
        } else if (event.modifiers & Qt.ControlModifier) {
          if (event.key === Qt.Key_1) { root.setMode("read"); event.accepted = true }
          else if (event.key === Qt.Key_2) { root.setMode("write"); event.accepted = true }
          else if (event.key === Qt.Key_3) { root.setMode("keys"); event.accepted = true }
        }
      }

      Flickable {
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

            Row {
              spacing: Style.spacing.md
              visible: root.readPlaintext !== ""
              ActionButton {
                text: root.copyArmed ? "Copy plaintext to clipboard?" : "Copy"
                iconText: "󰆏"
                onClicked: root.copyPlaintext()
              }
              Caption {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(300)
                text: root.copyArmed
                  ? "Other apps and clipboard history can read the clipboard. Click again to copy."
                  : root.copyNotice
              }
            }
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
                enabled: !root.busy
                width: (parent.width - parent.spacing) / 2
                label: "To"
                placeholderText: "Search recipients..."
                noSelectionText: "Choose recipients"
                emptyText: "No public keys. Import one under Keys."
                fontFamily: root.fontFamily
                values: root.recipients
                options: root.encryptKeys.map(function(k) {
                  return { value: k.fingerprint, label: Model.keyLabel(k),
                           description: Model.shortFingerprint(k.fingerprint) + " · " + Model.validityLabel(k.uidValidity) }
                })
                onChanged: function(values) {
                  root.recipients = values
                  root.allowUnverified = false
                }
              }

              Dropdown {
                enabled: !root.busy
                width: (parent.width - parent.spacing) / 2
                label: "Sign as"
                fontFamily: root.fontFamily
                value: root.signer
                options: [{ value: "", label: "Don't sign" }].concat(root.signKeys.map(function(k) {
                  return { value: k.fingerprint, label: Model.keyLabel(k) }
                }))
                onChanged: function(value) { root.signer = value }
              }
            }

            Toggle {
              enabled: !root.busy
              width: parent.width
              visible: root.selfKey !== null
              label: "Encrypt to myself too"
              description: root.selfKey ? "So you can read it later with " + Model.keyLabel(root.selfKey) + "." : ""
              checked: root.encryptToSelf
              fontFamily: root.fontFamily
              onClicked: root.encryptToSelf = !root.encryptToSelf
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
              onCopyRequested: function(text, cut) { root.copyEditorText(text, cut) }
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
                text: "Clear"
                onClicked: { writeInput.clear(); writeOutputArea.clear(); root.clearWriteResult(); writeInput.focusEditor() }
              }
            }

            Message { width: parent.width; tone: "bad"; text: root.writeError }
            Caption { width: parent.width; text: root.copyNotice }

            Caption {
              width: parent.width
              visible: root.writeOutput !== ""
              text: root.writeOutputKind
            }

            PgpTextView {
              id: writeOutputArea
              objectName: "pgpWriteOutput"
              width: parent.width
              height: Style.space(120)
              visible: root.writeOutput !== ""
            }

            ActionButton {
              visible: root.writeOutput !== ""
              text: root.writeCopyArmed ? "Copy signed plaintext to clipboard?" : "Copy"
              iconText: "󰆏"
              onClicked: root.copyWriteOutput()
            }
          }

          // ---- Keys ------------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.mode === "keys"

            Message { width: parent.width; tone: "bad"; text: root.keysError }

            Caption {
              width: parent.width
              visible: root.keysLoaded && root.keys.length === 0
              text: "No keys yet. Paste a public key below to import it, or import your own key pair."
            }

            ListView {
              id: keyView
              width: parent.width
              height: Math.min(contentHeight, Style.space(230))
              clip: true
              spacing: Style.spacing.sm
              boundsBehavior: Flickable.StopAtBounds
              model: root.keys
              visible: root.keys.length > 0

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
                      keyRow.modelData.hasSecret ? "secret key" : "public key",
                      Model.validityLabel(keyRow.modelData.usable ? keyRow.modelData.uidValidity : keyRow.modelData.validity),
                      keyRow.modelData.canEncrypt ? "" : "can't encrypt"
                    ].filter(function(s) { return s !== "" }).join(" · ")
                  }

                  Caption {
                    width: parent.width
                    text: Model.formatFingerprint(keyRow.modelData.fingerprint)
                    color: root.verifyTarget && root.verifyTarget.fingerprint === keyRow.modelData.fingerprint ? root.fg : root.dim
                    font.pixelSize: root.verifyTarget && root.verifyTarget.fingerprint === keyRow.modelData.fingerprint ? Style.font.body : Style.font.caption
                    font.bold: root.verifyTarget && root.verifyTarget.fingerprint === keyRow.modelData.fingerprint
                  }
                }

                Row {
                  id: keyButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.spacing.md
                  spacing: Style.spacing.sm

                  ActionButton {
                    visible: !keyRow.modelData.hasSecret && !keyRow.modelData.verified && keyRow.modelData.usable && root.signKeys.length > 0
                    text: "Verify"
                    tooltipText: "Mark this key as verified after comparing its fingerprint with its owner"
                    onClicked: root.verifyTarget = keyRow.modelData
                  }
                  ActionButton {
                    iconText: "󰆏"
                    tooltipText: "Copy public key"
                    onClicked: root.copyPublicKey(keyRow.modelData)
                  }
                }
              }
            }

            BorderSurface {
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

                Message {
                  width: parent.width
                  text: root.verifyTarget
                    ? "Ask " + Model.keyLabel(root.verifyTarget) + " to read their fingerprint to you in person, by phone, or another trusted channel. Only continue if every character matches:"
                    : ""
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  text: root.verifyTarget ? Model.formatFingerprint(root.verifyTarget.fingerprint) : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Row {
                  spacing: Style.spacing.md
                  ActionButton {
                    text: "It matches: verify"
                    onClicked: root.verifyKey(root.verifyTarget)
                  }
                  ActionButton {
                    text: "Cancel"
                    onClicked: root.verifyTarget = null
                  }
                }

                Caption {
                  width: parent.width
                  text: "This certifies only the displayed identity, with a local signature that is not exported by this plugin."
                }
              }
            }

            Message { width: parent.width; text: root.keysNotice }

            PanelSectionHeader {
              text: "IMPORT KEYS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            PgpTextArea {
              id: importInput
              onCopyRequested: function(text, cut) { root.copyEditorText(text, cut) }
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
