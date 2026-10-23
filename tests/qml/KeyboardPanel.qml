import QtQuick

// Offscreen stand-in for the Wayland-only window, not for plugin logic.
Item {
  property var anchorItem: null
  property var owner: null
  property var bar: null
  property bool open: false
  property var focusTarget: null
  property int contentWidth: 560
  property int contentHeight: 600
  width: contentWidth
  height: contentHeight
  function fittedContentWidth(value) { return value }
  function fittedContentHeight(value) { return value }
}
