import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Deliberately not a TextEdit: no selection, implicit primary selection,
// context-menu Copy, or built-in clipboard shortcuts for sensitive output.
BorderSurface {
  id: root
  property string text: ""
  function clear() { text = "" }
  color: Style.controlFill(false, false, Color.popups.text, Color.accent)
  borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
  radius: Style.cornerRadius
  clip: true

  ScrollView {
    id: scroll
    anchors.fill: parent
    contentWidth: availableWidth
    contentHeight: label.implicitHeight + Style.spacing.inputPaddingY * 2
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    Text {
      id: label
      objectName: "plainTextOutput"
      x: Style.spacing.controlPaddingX
      y: Style.spacing.inputPaddingY
      width: Math.max(1, scroll.availableWidth - Style.spacing.controlPaddingX * 2)
      text: root.text
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }
}
