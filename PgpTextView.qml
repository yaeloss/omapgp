import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

BorderSurface {
  id: root
  property string text: ""
  property bool selectable: false
  signal copyAllRequested()

  function clear() { text = "" }
  color: Style.controlFill(false, false, Color.popups.text, Color.accent)
  borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
  radius: Style.cornerRadius
  clip: true

  ScrollView {
    anchors.fill: parent
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

    TextArea {
      id: area
      objectName: "plainTextOutput"
      text: root.text
      textFormat: TextEdit.PlainText
      readOnly: true
      // Mouse selection can publish the primary selection on Wayland.
      enabled: root.selectable
      selectByMouse: root.selectable
      persistentSelection: root.selectable
      wrapMode: TextEdit.Wrap
      color: Color.popups.text
      selectionColor: Style.selectionFillFor(Color.popups.text, Color.accent)
      selectedTextColor: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      leftPadding: Style.spacing.controlPaddingX
      rightPadding: Style.spacing.controlPaddingX
      topPadding: Style.spacing.inputPaddingY
      bottomPadding: Style.spacing.inputPaddingY
      background: null

      ContextMenu.menu: Controls.Menu {
        Controls.MenuItem {
          text: "Copy"
          enabled: area.selectedText !== ""
          onTriggered: area.copy()
        }
        Controls.MenuItem { text: "Copy all"; onTriggered: root.copyAllRequested() }
        Controls.MenuItem { text: "Select all"; onTriggered: area.selectAll() }
      }

      Keys.onPressed: function(event) {
        if (event.matches(StandardKey.Copy) && area.selectedText === "") {
          if (!event.isAutoRepeat) root.copyAllRequested()
          event.accepted = true
        }
      }
    }
  }
}
