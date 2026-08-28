import QtQuick
import Quickshell
import qs.Commons
// This file is itself called BarWidget.qml and `import "."` makes the plugin
// directory a module, so the shell's BarWidget has to be namespaced or the
// type would resolve to this file.
import qs.Ui as Ui
import "."

Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.obsiduous"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  // A Nerd Font glyph rather than an emoji, so it takes the theme's bar
  // foreground like every other icon up there. An emoji would render as a
  // colour bitmap and ignore the theme entirely.
  //
  // The default is U+F01C8, a cut gem — obsidian being volcanic glass, and the
  // shape reading as a note-shaped diamond in the bar. It sits above the BMP,
  // so it needs a surrogate pair: a QML \u escape takes exactly four hex
  // digits, and "8" would be U+F01C (a chevron) followed by a literal 8.
  // The setting exists because the right bar icon is a matter of taste, and
  // hardcoding it is what makes people keep a local edit forever.
  readonly property string glyph: ObsiduousState.glyph !== ""
    ? ObsiduousState.glyph : "󰇈"

  readonly property string tooltip: {
    if (ObsiduousState.vault === "") return "Obsiduous — no vault selected"
    if (!ObsiduousState.indexed) return "Obsiduous — indexing " + ObsiduousState.vaultName
    var text = ObsiduousState.vaultName + " · " + ObsiduousState.noteCount + " notes"
    if (ObsiduousState.truncated) text += " (index truncated)"
    return text
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("ObsiduousPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    // The vault name and note count can both contain anything a filesystem
    // allows, and the kit's tooltip renders through a Text it owns, which
    // sniffs for rich text. Angle brackets come out before it gets there.
    tooltipText: root.tooltip.replace(/[<>]/g, "")
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(pressedButton) {
      if (pressedButton === Qt.LeftButton) root.toggle()
      else if (pressedButton === Qt.RightButton) ObsiduousState.openVaultRoot()
    }
  }
}
