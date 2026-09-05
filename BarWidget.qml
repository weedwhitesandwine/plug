import QtQuick
import qs.Commons
import qs.Ui as Ui
import "."

// Bar icon: a plug glyph that opens the panel, with a badge for waiting
// updates. A Nerd Font glyph rather than an emoji, so it takes the theme's
// foreground like every other bar icon. (qs.Ui is namespaced because this
// file is itself named BarWidget.qml.)
Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.plug"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property int updateCount: PlugState.updateCount
  readonly property bool opened: PlugState.overlay ? PlugState.overlay.opened === true : false

  // The shell toggle route works even before the panel object exists.
  function toggle() { root.bar.run("omarchy-shell shell toggle io.github.weedwhitesandwine.plug") }
  function open() { root.toggle() }
  function close() { root.toggle() }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-plug (U+F1E6), as an escape so the glyph survives editors that
    // drop private-use characters.
    text: "\uf1e6"
    tooltipText: root.updateCount > 0
      ? ("Plug — " + root.updateCount + " update" + (root.updateCount === 1 ? "" : "s") + " waiting")
      : "Plug"
    onPressed: function(b) { root.toggle() }
  }

  Rectangle {
    visible: root.updateCount > 0
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(1)
    anchors.rightMargin: Style.space(1)
    width: Math.max(Style.space(13), badge.implicitWidth + Style.space(6))
    height: Style.space(13)
    radius: height / 2
    color: "#d29922"
    Text {
      id: badge
      anchors.centerIn: parent
      text: root.updateCount > 9 ? "9+" : String(root.updateCount)
      textFormat: Text.PlainText
      color: "#1a1005"
      font.pixelSize: Style.font.caption - 2
      font.bold: true
    }
  }
}
