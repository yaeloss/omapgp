import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Multi-line plain-text editor styled like the kit's TextField. Rich text is
// never rendered: a message can't load remote content or hide markup.
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

  readonly property bool editorFocused: area.activeFocus
  readonly property bool _hot: hover.hovered
  readonly property var _borderSpec: Border.controlSpec(area.activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

  signal submitRequested()
  signal inputRejected(string message)

  function clear() { pasteReader.cancel(); _revision++; area.text = "" }
  function focusEditor() { area.forceActiveFocus() }
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
        root._revision++
        if (Model.inputTooLarge(text)) {
          text = ""
          Qt.callLater(function() { root.inputRejected("Input is too large (maximum 64 KiB of UTF-8 text).") })
        }
      }

      ContextMenu.menu: Controls.Menu {
        Controls.MenuItem { text: "Copy"; enabled: area.selectedText !== ""; onTriggered: area.copy() }
        Controls.MenuItem { text: "Cut"; enabled: !area.readOnly && area.selectedText !== ""; onTriggered: area.cut() }
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
        if (event.matches(StandardKey.Paste)) {
          root.pasteClipboard(false, false)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          var next = area.nextItemInFocusChain(event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))
          if (next) next.forceActiveFocus()
          event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
          root.submitRequested()
          event.accepted = true
        }
      }
    }
  }
}
