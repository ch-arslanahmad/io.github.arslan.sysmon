import QtQuick
import qs.Ui
import qs.Commons
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.arslan.sysmon"

  SysMonCore {
    id: sys
    intervalMs: 2000
  }

  readonly property color white: "#ffffff"

  readonly property var snap: panelLoader.item && panelLoader.item.snapshot ? panelLoader.item.snapshot : null
  readonly property real cpuPercent: snap && snap.cpu ? snap.cpu.total : sys.cpuPercent
  readonly property real memPercent: snap ? (snap.mem && snap.mem.total > 0 ? (snap.mem.used / snap.mem.total * 100) : sys.memPercent) : sys.memPercent
  readonly property real tempC: snap && snap.cpu && snap.cpu.temp !== null && snap.cpu.temp !== undefined ? snap.cpu.temp : sys.tempCurrent / 1000
  readonly property real diskPercent: snap && snap.disk && snap.disk.total > 0 ? (snap.disk.used / snap.disk.total * 100) : sys.diskPercent
  readonly property string cpuFreqText: snap && snap.cpu && snap.cpu.freq_mhz ? (snap.cpu.freq_mhz >= 1000 ? (snap.cpu.freq_mhz / 1000).toFixed(1) + "GHz" : snap.cpu.freq_mhz + "MHz") : freqText()

  function stateColor(val, base) {
    if (val >= 80) return "#ff3333"
    if (val >= 60) return "#ffb800"
    return base
  }

  function textColor(val) {
    return val >= 80 ? "#ff3333" : white
  }

  function pillColor(active) {
    return active ? Qt.lighter(Color.bar.background, 1.5) : Qt.lighter(Color.bar.background, 1.2)
  }

  function tempIcon() {
    var c = Math.round(tempC)
    if (c >= 80) return "\u{F1807}"
    if (c >= 65) return "\u{F0510}"
    if (c >= 50) return "\u{F10C2}"
    return "\u{F050F}"
  }

  function freqText() {
    return sys.cpuFreqMhz >= 1000 ? sys.cpuFreqGhz + "GHz" : sys.cpuFreqMhz + "MHz"
  }

  // ---- panel wiring (vitals pattern) ---------------------------------------
  function injectPanel() {
    var p = panelLoader.item
    if (!p) return
    if ("bar" in p) p.bar = root.bar
    if ("settings" in p) p.settings = root.settings
    if ("anchorItem" in p) p.anchorItem = cpuPill
    if ("hostWidget" in p) p.hostWidget = root
  }

  function openTab(key) {
    var p = panelLoader.item
    if (!p) return
    if (p.showTab && p.showTab(key)) { /* switched */ }
    if (!p.opened) p.openFromHotkey()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- bar widget: 4 colored metric pills -----------------------------------
  implicitWidth: row.implicitWidth
  implicitHeight: Style.bar.sizeHorizontal

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 6

    // Each pill: Rectangle background + Text.RichText label + MouseArea.
    // Matches WidgetButton font, sizing, and hover feel exactly.

    Rectangle {
      id: cpuPill
      implicitWidth: cpuLabel.implicitWidth + Style.spaceReal(8.5) * 2
      implicitHeight: Style.bar.sizeHorizontal
      radius: height / 2
      color: cpuMouse.containsMouse ? Qt.lighter(Color.bar.background, 1.5) : "transparent"
      Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Text {
        id: cpuLabel
        anchors.centerIn: parent
        textFormat: Text.RichText
        text: "<font color='" + stateColor(root.cpuPercent, "#4da6ff") + "'>\u{F035B}</font> <font color='" + textColor(root.cpuPercent) + "'>" + root.cpuFreqText + " (" + Math.round(root.cpuPercent) + "%)</font>"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }

      MouseArea {
        id: cpuMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { if (mouse.button === Qt.LeftButton) root.openTab("cpu") }
        onEntered: { if (root.bar) root.bar.showTooltip(cpuLabel, sys.cpuModelName ? sys.cpuModelName : "CPU") }
        onExited: { if (root.bar) root.bar.hideTooltip(cpuLabel) }
      }
    }

    Rectangle {
      id: memPill
      implicitWidth: memLabel.implicitWidth + Style.spaceReal(8.5) * 2
      implicitHeight: Style.bar.sizeHorizontal
      radius: height / 2
      color: memMouse.containsMouse ? Qt.lighter(Color.bar.background, 1.5) : "transparent"
      Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Text {
        id: memLabel
        anchors.centerIn: parent
        textFormat: Text.RichText
        text: "<font color='" + stateColor(root.memPercent, "#66ff66") + "'>\u{F046D}</font> <font color='" + textColor(root.memPercent) + "'>" + Math.round(root.memPercent) + "%</font>"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }

      MouseArea {
        id: memMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { if (mouse.button === Qt.LeftButton) root.openTab("mem") }
        onEntered: { if (root.bar) root.bar.showTooltip(memLabel, snap && snap.mem ? Model.bytes(snap.mem.used) + " / " + Model.bytes(snap.mem.total) : Model.bytes(sys.memUsed) + " / " + Model.bytes(sys.memTotal)) }
        onExited: { if (root.bar) root.bar.hideTooltip(memLabel) }
      }
    }

    Rectangle {
      id: tempPill
      implicitWidth: tempLabel.implicitWidth + Style.spaceReal(8.5) * 2
      implicitHeight: Style.bar.sizeHorizontal
      radius: height / 2
      color: tempMouse.containsMouse ? Qt.lighter(Color.bar.background, 1.5) : "transparent"
      Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Text {
        id: tempLabel
        anchors.centerIn: parent
        textFormat: Text.RichText
        text: "<font color='" + stateColor(root.tempC, root.tempC >= 50 ? "#ff9933" : "#4da6ff") + "'>" + tempIcon() + "</font> <font color='" + textColor(root.tempC >= 80 ? 100 : 0) + "'>" + Math.round(root.tempC) + "\u00B0C</font>"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }

      MouseArea {
        id: tempMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { if (mouse.button === Qt.LeftButton) root.openTab("temp") }
        onEntered: { if (root.bar) root.bar.showTooltip(tempLabel, Math.round(root.tempC) + "°C / " + Math.round(root.tempC * 1.8 + 32) + "°F") }
        onExited: { if (root.bar) root.bar.hideTooltip(tempLabel) }
      }
    }

    Rectangle {
      id: diskPill
      implicitWidth: diskLabel.implicitWidth + Style.spaceReal(8.5) * 2
      implicitHeight: Style.bar.sizeHorizontal
      radius: height / 2
      color: diskMouse.containsMouse ? Qt.lighter(Color.bar.background, 1.5) : "transparent"
      Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Text {
        id: diskLabel
        anchors.centerIn: parent
        textFormat: Text.RichText
        text: "<font color='" + stateColor(root.diskPercent, white) + "'>\u{F02CA}</font> <font color='" + textColor(root.diskPercent) + "'>" + Math.round(root.diskPercent) + "%</font>"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }

      MouseArea {
        id: diskMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { if (mouse.button === Qt.LeftButton) root.openTab("disk") }
        onEntered: { if (root.bar) root.bar.showTooltip(diskLabel, snap && snap.disk ? Model.bytes(snap.disk.used) + " / " + Model.bytes(snap.disk.total) : Model.bytes(sys.diskUsed) + " / " + Model.bytes(sys.diskTotal)) }
        onExited: { if (root.bar) root.bar.hideTooltip(diskLabel) }
      }
    }
  }
}
