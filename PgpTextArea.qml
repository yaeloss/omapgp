import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Multi-line plain-text editor styled like the kit's TextField. Rich text is
// never rendered: a message can't load remote content or hide markup.
//
// Copy and cut never use the control's built-in clipboard actions. They emit
// copyRequested so the panel can route drafts and pasted private keys through
// the same guarded, auto-expiring clipboard path as decrypted output.
BorderSurface {
  id: root

  property alias text: area.text
  property alias placeholderText: area.placeholderText
  property alias readOnly: area.readOnly
  property alias textArea: area
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property bool monospace: true
  property int _revision: 0
  property string _lastText: ""

  readonly property bool editorFocused: area.activeFocus
  readonly property bool _hot: hover.hovered
  readonly property var _borderSpec: Border.controlSpec(area.activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

  signal submitRequested()
  signal inputRejected(string message)
  // text, and whether the source selection should be deleted.
  signal copyRequested(string text, bool cut)

  function clear() { pasteReader.cancel(); _revision++; _lastText = ""; area.text = "" }
  function _rejectEdit(message) {
    var position = area.cursorPosition
    area.text = root._lastText
    area.cursorPosition = Math.min(position, area.length)
    Qt.callLater(function() { root.inputRejected(message) })
  }
  function focusEditor() { area.forceActiveFocus() }
  function selectedText() {
    return area.selectionStart === area.selectionEnd ? ""
      : area.getText(area.selectionStart, area.selectionEnd)
  }
  // Every Copy/Cut path in this editor ends here; it never invokes the
  // control's built-in clipboard action.
  function copySelection(cut) {
    var selection = selectedText()
    if (selection === "") return
    root.copyRequested(selection, cut)
    if (cut) area.remove(area.selectionStart, area.selectionEnd)
    area.deselect()
  }
  function pasteClipboard(primary, replaceAll) {
    if (readOnly || pasteReader.running) return
    area.forceActiveFocus()
    var revision = _revision
    var start = replaceAll === false ? area.selectionStart : 0
    var end = replaceAll === false ? area.selectionEnd : area.text.length
    var args = primary ? ["wl-paste", "--primary", "--no-newline"] : ["wl-paste", "--no-newline"]
    pasteReader.start(args, null, function(r) {
      root._applyPaste(r, revision, start, end)
    })
  }

  function _applyPaste(result, revision, start, end) {
    if (revision !== root._revision) return
    var error = Model.workerFailure(result)
    if (error || result.exitCode !== 0) { root.inputRejected(error || "Could not read the clipboard."); return }
    var next = area.text.slice(0, start) + result.stdout + area.text.slice(end)
    if (Model.inputTooLarge(next)) { root.inputRejected("Input is too large (maximum 64 KiB of UTF-8 text)."); return }
    area.remove(start, end)
    area.insert(start, result.stdout)
  }

  GpgProcess { id: pasteReader }

  color: Style.controlFill(area.activeFocus, _hot, root.foreground, root.accent)
  borderSpec: _borderSpec
  radius: Style.cornerRadius
  clip: true

  HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }

  ScrollView {
    id: scroll
    anchors.fill: parent
    anchors.topMargin: Border.top(root._borderSpec)
    anchors.rightMargin: Border.right(root._borderSpec)
    anchors.bottomMargin: Border.bottom(root._borderSpec)
    anchors.leftMargin: Border.left(root._borderSpec)
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

    TextArea {
      id: area
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.Wrap
      selectByMouse: true
      persistentSelection: false
      inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      placeholderTextColor: Qt.darker(root.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      leftPadding: Style.spacing.controlPaddingX
      rightPadding: Style.spacing.controlPaddingX
      topPadding: Style.spacing.inputPaddingY
      bottomPadding: Style.spacing.inputPaddingY
      background: null

      onTextChanged: {
        var limit = "Input is too large (maximum 64 KiB of UTF-8 text)."
        // Revert just this edit instead of discarding the whole draft.
        if (text.length > Model.MAX_INPUT_CHARS) { root._rejectEdit(limit); return }
        if (text.length <= root._lastText.length) {
          // Shorter than before: a deletion, which never needs the byte check.
          root._lastText = text
          root._revision++
          return
        }
        root._lastText = text
        root._revision++
        if (Model.inputTooLarge(text)) root._rejectEdit(limit)
      }

      ContextMenu.menu: Controls.Menu {
        Controls.MenuItem {
          text: "Copy"
          enabled: area.selectedText !== ""
          onTriggered: root.copySelection(false)
        }
        Controls.MenuItem {
          text: "Cut"
          enabled: !area.readOnly && area.selectedText !== ""
          onTriggered: root.copySelection(true)
        }
        Controls.MenuItem { text: "Paste"; enabled: !area.readOnly; onTriggered: root.pasteClipboard(false, false) }
        Controls.MenuItem { text: "Select all"; onTriggered: area.selectAll() }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton
        onPressed: function(mouse) {
          mouse.accepted = true
          root.pasteClipboard(true, false)
        }
      }

      // Tab moves focus instead of inserting a tab; Ctrl+Enter submits.
      Keys.onPressed: function(event) {
        if (event.matches(StandardKey.Copy)) {
          root.copySelection(false)
          event.accepted = true
        } else if (event.matches(StandardKey.Cut)) {
          if (!area.readOnly) root.copySelection(true)
          event.accepted = true
        } else if (event.matches(StandardKey.Paste)) {
          root.pasteClipboard(false, false)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          var next = area.nextItemInFocusChain(event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))
          if (next) {
            next.forceActiveFocus()
            event.accepted = true
          }
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
          root.submitRequested()
          event.accepted = true
        }
      }
    }
  }
}
