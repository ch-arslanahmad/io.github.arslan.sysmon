import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"
import "tabs"

// SysMon: a calm system monitor panel. One tab at a time — CPU, Memory,
// Disks, Network, GPU, Processes — fed by collector.py, which only runs while
// the panel is open. Each tab is a Loader that is only alive while selected,
// so a hidden tab costs nothing per sample.
Panel {
  id: root
  moduleName: "io.github.arslan.sysmon"
  ipcTarget: "io.github.arslan.sysmon"

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the showTab method below.
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel (same contract as the weather / tides plugins).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- palette / type -----------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 1.4)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string icon: "󰍛" // nf-md-memory (chip)

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  // Threshold colors shared with the bar widget: calm until 60%, amber to 80%, red beyond.
  function stateColor(pct) { return pct >= 80 ? "#ff3333" : pct >= 60 ? "#ffb800" : foreground }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // ---- settings ------------------------------------------------------------
  readonly property int refreshSeconds: clamp(Number(setting("refreshSeconds", 1)) || 1, 1, 10)
  readonly property int historyLength: 90

  // ---- open / close ---------------------------------------------------------
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.confirmOpen) root.cancelSignal()
    if (root.filtering) root.stopFiltering()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    // The plugin bar facade exposes this state read-only; assigning to it
    // throws and aborts open()/close() before the controller is called.
    if (!root.bar) return
    if (typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if ("centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  // ---- data -----------------------------------------------------------------
  property var snapshot: null
  readonly property bool hasData: snapshot !== null
  property bool heroExpanded: false
  readonly property var cpu: snapshot ? snapshot.cpu : null
  readonly property var mem: snapshot ? snapshot.mem : null
  readonly property var disks: snapshot ? (snapshot.disks || []) : []
  readonly property var gpus: snapshot ? (snapshot.gpus || []) : []
  readonly property var ifaces: snapshot && snapshot.net ? (snapshot.net.ifaces || []) : []
  readonly property var processes: snapshot ? (snapshot.processes || []) : []

  property var cpuHistory: []
  property var gpuHistory: []
  property var rxHistory: []
  property var txHistory: []
  property var tempHistory: []
  readonly property var tempStats: {
    var h = root.tempHistory
    if (!h || h.length === 0) return null
    var mn = h[0], mx = h[0], sum = 0
    for (var i = 0; i < h.length; i++) {
      if (h[i] < mn) mn = h[i]
      if (h[i] > mx) mx = h[i]
      sum += h[i]
    }
    return { min: mn, max: mx, avg: sum / h.length }
  }

  function tempBand(t) { return t >= 80 ? 3 : t >= 65 ? 2 : t >= 50 ? 1 : 0 }
  readonly property var tempBands: [
    { label: "Nominal", color: "#66ff66" },
    { label: "Warm", color: "#ffcc00" },
    { label: "Hot", color: "#ff9933" },
    { label: "Critical", color: "#ff3333" }
  ]
  readonly property int currentTempBand: root.cpu && root.cpu.temp !== null && root.cpu.temp !== undefined ? tempBand(root.cpu.temp) : -1

  property int smartIndex: -1
  property string smartState: ""
  property string smartOut: ""
  property bool smartInstalled: false
  property string smartDev: ""
  readonly property int smartDeadlineMs: 8000  // 8 s wall-clock deadline
  // Expansion state keyed by partition path — survives delegate rebuilds
  // caused by fresh snapshot arrays every tick.
  property var expandedParts: ({})
  function togglePart(key) {
    var m = {}
    for (var k in expandedParts) m[k] = expandedParts[k]
    if (m[key]) delete m[key]
    else m[key] = true
    expandedParts = m
  }
  readonly property bool hasSmart: (root.snapshot && root.snapshot.has_smart === true) || root.smartInstalled

  readonly property string collectorPath: Qt.resolvedUrl("collector.py").toString().replace(/^file:\/\//, "")

  Process {
    id: collector
    command: ["python3", root.collectorPath, "--interval", String(root.refreshSeconds)]
    running: root.opened
    stdout: SplitParser {
      onRead: function(line) { root.ingest(line) }
    }
  }

  Process {
    id: smartProc
    property var _lines: []
    property int _bytes: 0
    property int _maxLines: 40
    property int _maxBytes: 524288  // 512 KiB
    stdout: SplitParser {
      onRead: function(line) {
        if (smartProc._lines.length >= smartProc._maxLines) return
        var s = String(line || "")
        if (smartProc._bytes + s.length > smartProc._maxBytes) return
        smartProc._lines.push(s)
        smartProc._bytes += s.length
      }
    }
    onExited: {
      smartDeadline.stop()
      if (root.smartState === "installing") {
        if (this.exitCode === 0) { root.smartInstalled = true; root.smartState = "" }
        else root.smartState = "error"
        smartProc._lines = []
        smartProc._bytes = 0
        return
      }
      root.smartOut = smartProc._lines.join("\n")
      root.smartState = root.smartOut !== "" ? "done" : "error"
      smartProc._lines = []
      smartProc._bytes = 0
    }
  }

  Timer {
    id: smartDeadline
    interval: root.smartDeadlineMs
    repeat: false
    onTriggered: {
      if (smartProc.running) {
        smartProc.running = false
        if (root.smartState === "running") root.smartState = "error"
      }
    }
  }

  function querySmart(index) {
    var d = root.disks[index]
    if (!d || !d.smart_dev || !root.hasSmart) return
    smartProc._lines = []
    smartProc._bytes = 0
    smartOut = ""
    smartIndex = index
    smartDev = ""
    smartState = "running"
    smartProc.command = ["pkexec", "smartctl", "-H", "-A", "-l", "error", "/dev/" + d.smart_dev]
    smartProc.running = true
    smartDeadline.restart()
  }

  function querySmartDev(name) {
    if (!name || !root.hasSmart) return
    smartProc._lines = []
    smartProc._bytes = 0
    smartOut = ""
    smartIndex = -1
    smartDev = name
    smartState = "running"
    smartProc.command = ["pkexec", "smartctl", "-H", "-A", "-l", "error", "/dev/" + name]
    smartProc.running = true
    smartDeadline.restart()
  }

  function installSmart() {
    smartIndex = -1
    smartState = "installing"
    smartProc._lines = []
    smartProc._bytes = 0
    smartProc.command = ["pkexec", "pacman", "-S", "--needed", "--noconfirm", "smartmontools"]
    smartProc.running = true
  }

  function parseSmart(text) {
    var rows = []
    var verdict = null
    var m = text.match(/overall-health[^:\n]*:\s*([A-Za-z ]+)/)
    if (m) verdict = m[1].trim()
    var wanted = ["Percentage Used", "Data Units Read", "Data Units Written", "Power On Hours", "Power Cycles", "Unsafe Shutdowns", "Media and Data Integrity Errors", "Critical Warning"]
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var c = lines[i].indexOf(":")
      if (c > 0 && c < 42) {
        var k = lines[i].slice(0, c).trim()
        for (var w = 0; w < wanted.length; w++) {
          if (k === wanted[w]) { rows.push({ k: k, v: lines[i].slice(c + 1).trim() }); break }
        }
      }
    }
    if (rows.length === 0) {
      var ids = { "5": "Reallocated sectors", "9": "Power-on hours", "194": "Temperature", "199": "CRC errors", "233": "Media wear" }
      for (i = 0; i < lines.length; i++) {
        var f = lines[i].trim().split(/\s+/)
        if (f.length > 9 && ids[f[0]] !== undefined) rows.push({ k: ids[f[0]], v: f[f.length - 1] })
      }
    }
    return { verdict: verdict, rows: rows, raw: text.trim().split("\n").slice(-14).join("\n") }
  }

  function ingest(line) {
    var raw = String(line || "").trim()
    if (!raw) return
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { return }
    if (!parsed || !parsed.cpu) return
    snapshot = parsed
    cpuHistory = Model.pushHistory(cpuHistory, parsed.cpu.total, historyLength)
    if (parsed.cpu && parsed.cpu.temp !== null && parsed.cpu.temp !== undefined) {
      tempHistory = Model.pushHistory(tempHistory, parsed.cpu.temp, historyLength)
    }
    var g = parsed.gpus && parsed.gpus.length ? parsed.gpus[0] : null
    gpuHistory = Model.pushHistory(gpuHistory, g && g.busy !== null ? g.busy : 0, historyLength)
    var iface = currentIface(parsed.net ? (parsed.net.ifaces || []) : [])
    rxHistory = Model.pushHistory(rxHistory, iface ? iface.rx_bps : 0, historyLength)
    txHistory = Model.pushHistory(txHistory, iface ? iface.tx_bps : 0, historyLength)
    if (tabKey === "proc") rebuildProcs()
  }

  // ---- tabs ------------------------------------------------------------------
  readonly property var tabs: {
    var t = [
      { key: "overview", label: "Overview" },
      { key: "cpu", label: "CPU" },
      { key: "temp", label: "Temps" },
      { key: "mem", label: "Memory" },
      { key: "disk", label: "Disks" }
    ]
    if (root.gpus.length > 0 || !root.hasData) t.push({ key: "gpu", label: "GPU" })
    return t
  }
  property string tabKey: "overview"
  property string subPage: ""
  property string overviewProcSort: "cpu"
  readonly property int tabIndex: {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].key === tabKey) return i
    return 0
  }
  property bool cursorActive: false
  // Where the process cursor came from. A keyboard cursor follows its process
  // when the table re-sorts; a mouse hover stays under the pointer.
  property bool cursorFromKeys: false

  function selectTab(index) {
    if (tabs.length === 0) return
    var n = tabs.length
    var i = ((index % n) + n) % n
    if (tabs[i].key === tabKey && subPage === "") return
    if (filtering) stopFiltering()
    tabKey = tabs[i].key
    subPage = ""
    procIndex = 0
    cursorFromKeys = false
  }

  function showSubPage(page) {
    subPage = page
    if (page === "proc") rebuildProcs()
  }

  function goBack() {
    subPage = ""
  }

  // Jump to a tab by key: cpu · mem · disk · net · gpu · proc.
  function showTab(key) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].key === String(key)) { selectTab(i); return true }
    }
    return false
  }

  IpcHandler {
    target: "io.github.arslan.sysmon"

    function open() { root.openFromHotkey() }
    function close() { root.close() }
    function show() { root.openFromHotkey() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    // omarchy-shell io.github.arslan.sysmon showTab proc  — opens on that tab.
    function showTab(key: string) {
      var ok = root.showTab(key)
      if (ok && !root.opened) root.openFromHotkey()
      return ok ? "ok" : "unknown"
    }
  }

  // Headline number in the hero follows the tab, so the big figure is
  // always the one the current tab is about.
  readonly property string headline: {
    var snap = snapshot
    if (!snap) return "—"
    if (tabKey === "overview" && subPage === "") return "OK"
    if (tabKey === "overview" && subPage === "net") {
      var n = snap.net
      if (n && n.ifaces) {
        var totalRx = 0, totalTx = 0
        for (var i = 0; i < n.ifaces.length; i++) {
          totalRx += n.ifaces[i].rx_bps || 0
          totalTx += n.ifaces[i].tx_bps || 0
        }
        return "\u2193 " + Model.rate(totalRx)
      }
      return "—"
    }
    if (tabKey === "overview" && subPage === "proc") return snap.processes ? Model.count(snap.processes.length) : "—"
    if (tabKey === "cpu") return snap.cpu ? Model.percent(snap.cpu.total) : "—"
    if (tabKey === "temp") return snap.cpu && snap.cpu.temp !== null && snap.cpu.temp !== undefined ? Model.temp(snap.cpu.temp) : "—"
    if (tabKey === "mem") return snap.mem && snap.mem.total > 0 ? Model.percent(snap.mem.used * 100 / snap.mem.total) : "—"
    if (tabKey === "disk") {
      var d = snap.disks && snap.disks.length ? snap.disks[0] : null
      return d && d.total > 0 ? Model.percent(d.used * 100 / d.total) : "—"
    }
    if (tabKey === "gpu") {
      var g = snap.gpus && snap.gpus.length ? snap.gpus[0] : null
      return g && g.busy !== null && g.busy !== undefined ? Model.percent(g.busy) : "—"
    }
    return "—"
  }

  readonly property string headlineCaption: {
    if (tabKey === "overview" && subPage === "") return "SYSTEM HEALTH"
    if (tabKey === "overview" && subPage === "net") return "RECEIVING"
    if (tabKey === "overview" && subPage === "proc") return "PROCESSES"
    if (tabKey === "cpu") return "CPU"
    if (tabKey === "temp") return "TEMPERATURE"
    if (tabKey === "mem") return "MEMORY"
    if (tabKey === "disk") return disks.length ? Model.mountLabel(disks[0].mount || "/").toUpperCase() : "DISK"
    if (tabKey === "gpu") return "GPU"
    return ""
  }

  // ---- network interface selection ------------------------------------------
  property string ifaceName: ""

  function currentIface(fromList) {
    var list = fromList || ifaces
    if (list.length === 0) return null
    for (var i = 0; i < list.length; i++) if (list[i].name === ifaceName) return list[i]
    return list[0]
  }

  readonly property var iface: currentIface()

  function selectIface(name) {
    if (name === (iface ? iface.name : "")) return
    ifaceName = name
    rxHistory = []
    txHistory = []
  }

  // ---- processes ---------------------------------------------------------------
  property string sortKey: "cpu"
  property bool sortReverse: false
  property int procIndex: 0
  property int selectedPid: -1
  property string filterText: ""
  property bool filtering: false
  property var sortedProcs: []
  readonly property var sortColumns: ["name", "pid", "user", "mem", "cpu"]
  readonly property var procTab: procLoader.item

  function setSort(key) {
    if (sortKey === key) sortReverse = !sortReverse
    else { sortKey = key; sortReverse = false }
    rebuildProcs()
  }

  function cycleSort(delta) {
    var i = sortColumns.indexOf(sortKey)
    var n = sortColumns.length
    sortKey = sortColumns[(((i + delta) % n) + n) % n]
    sortReverse = false
    rebuildProcs()
  }

  function rebuildProcs() {
    var list = Model.sortProcesses(Model.filterProcesses(processes, filterText), sortKey, sortReverse)
    // The table re-sorts on every sample, so remember which *process* the
    // cursor is on and find it again in the new order — otherwise the row
    // under the highlight would silently change identity between ticks.
    var followPid = cursorActive && cursorFromKeys && procIndex >= 0 && procIndex < sortedProcs.length ? sortedProcs[procIndex].pid : -1
    sortedProcs = list
    var n = list.length
    var selectedStillHere = false
    for (var i = 0; i < n; i++) {
      var p = list[i]
      var row = { pid: p.pid, ppid: p.ppid, name: p.name, user: p.user, cpu: p.cpu, mem: p.mem,
                  threads: p.threads, state: p.state || "", cmd: p.cmd }
      if (i < procModel.count) procModel.set(i, row)
      else procModel.append(row)
      if (p.pid === selectedPid) selectedStillHere = true
    }
    while (procModel.count > n) procModel.remove(procModel.count - 1)
    if (followPid >= 0) {
      for (var j = 0; j < n; j++) {
        if (list[j].pid === followPid) {
          if (j !== procIndex) {
            procIndex = j
            procScrollTo(j)
          }
          break
        }
      }
    }
    if (procIndex >= n) procIndex = Math.max(0, n - 1)
    if (selectedPid >= 0 && !selectedStillHere && filterText === "") selectedPid = -1
  }

  ListModel { id: procModel }

  function procScrollTo(index) {
    if (procTab && procTab.scrollTo) procTab.scrollTo(index)
  }

  function moveProcCursor(delta) {
    if (sortedProcs.length === 0) return
    cursorFromKeys = true
    procIndex = clamp(procIndex + delta, 0, sortedProcs.length - 1)
    procScrollTo(procIndex)
  }

  function jumpProcCursor(toEnd) {
    if (sortedProcs.length === 0) return
    cursorActive = true
    cursorFromKeys = true
    procIndex = toEnd ? sortedProcs.length - 1 : 0
    if (procTab && procTab.scrollToEdge) procTab.scrollToEdge(toEnd)
  }

  // Click / Enter: expand the row into its detail card with actions.
  function toggleSelected(pid) {
    selectedPid = selectedPid === pid ? -1 : pid
  }

  function activateCursor() {
    if (tabKey !== "proc") return
    if (!cursorActive) { cursorActive = true; return }
    if (procIndex >= 0 && procIndex < sortedProcs.length) toggleSelected(sortedProcs[procIndex].pid)
  }

  function startFiltering() {
    filtering = true
    if (procTab && procTab.focusFilter) procTab.focusFilter()
  }

  function stopFiltering() {
    filtering = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function clearFilter() {
    filterText = ""
    if (procTab && procTab.clearFilterField) procTab.clearFilterField()
    rebuildProcs()
    stopFiltering()
  }

  // ---- signals to processes -----------------------------------------------------
  // Terminate / Kill ask first; Pause / Resume are reversible so they just go.
  property bool confirmOpen: false
  property var confirmTarget: null
  property string confirmSignal: "TERM"

  readonly property var signalVerbs: ({ TERM: "Terminate", KILL: "Kill", STOP: "Pause", CONT: "Resume" })

  function requestSignal(proc, sig) {
    if (!proc) return
    if (sig === "STOP" || sig === "CONT") { sendSignal(proc.pid, sig); return }
    confirmTarget = proc
    confirmSignal = sig
    confirmOpen = true
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function requestTerminateCursor() {
    if (tabKey !== "proc" || !cursorActive || procIndex < 0 || procIndex >= sortedProcs.length) return
    requestSignal(sortedProcs[procIndex], "TERM")
  }

  function cancelSignal() {
    confirmOpen = false
    confirmTarget = null
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function confirmSignalNow() {
    if (confirmTarget) sendSignal(confirmTarget.pid, confirmSignal)
    cancelSignal()
  }

  function sendSignal(pid, sig) {
    signalProc.command = ["kill", "-" + sig, String(pid)]
    signalProc.running = true
  }

  Process { id: signalProc }

  // ---- surface -----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    // owner must expose close() so dismiss-clicks route through root.close()
    // -> controller.hide() instead of assigning open=false directly (which
    // breaks the open: root.opened binding and bricks reopening).
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(600))
    // A dashboard: hold a comfortable minimum so switching tabs doesn't make
    // the card breathe, and cap so it never runs off the screen.
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight, Style.space(430)), Style.space(760))

    // Keys while a Terminate / Kill confirmation is up.
    Item {
      id: confirmKeys
      anchors.fill: parent
      visible: root.confirmOpen
      z: 20
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (signalConfirm.handleKey(event)) event.accepted = true
      }

      ConfirmDialog {
        id: signalConfirm
        anchors.fill: parent
        opened: root.confirmOpen
        message: root.confirmTarget
          ? root.signalVerbs[root.confirmSignal] + " " + root.confirmTarget.name + " (pid " + root.confirmTarget.pid + ")?"
            + (root.confirmSignal === "KILL" ? "\nSIGKILL cannot be caught — unsaved work is lost." : "")
          : ""
        confirmText: root.signalVerbs[root.confirmSignal] || "Confirm"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelSignal()
        onConfirmed: root.confirmSignalNow()
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.filtering || root.confirmOpen

      onMoveRequested: function(dx, dy) {
        root.cursorActive = true
        if (dx !== 0) root.selectTab(root.tabIndex + dx)
        else if (dy !== 0) {
          if (root.tabKey === "proc") root.moveProcCursor(dy)
          else panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                                Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (root.selectedPid >= 0) root.selectedPid = -1
        else if (root.filterText !== "") root.clearFilter()
        else root.close()
      }
      onDeleteRequested: root.requestTerminateCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var n = parseInt(t, 10)
        if (!isNaN(n) && n >= 1 && n <= root.tabs.length) { root.selectTab(n - 1); return }
        if (root.tabKey !== "proc") return
        if (t === "s") root.cycleSort(1)
        else if (t === "S") root.cycleSort(-1)
        else if (t === "r" || t === "R") { root.sortReverse = !root.sortReverse; root.rebuildProcs() }
        else if (t === "/" || t === "f" || t === "F") root.startFiltering()
        else if (t === "g") root.jumpProcCursor(false)
        else if (t === "G") root.jumpProcCursor(true)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: collapsed + expanded ----------
          Item {
            width: parent.width
            implicitHeight: Style.space(32)

            // ---- HEADER ROW: always visible ----
            Item {
              id: heroHeaderRow
              width: parent.width
              height: Style.space(32)

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(14)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: root.icon
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.snapshot ? root.snapshot.host : "SysMon"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "\u00B7"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: {
                    if (!root.snapshot) return ""
                    return root.snapshot.uptime ? ("UP " + Model.uptime(root.snapshot.uptime)) : ""
                  }
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Column {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(14)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  text: root.headline
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  horizontalAlignment: Text.AlignRight
                }
                Text {
                  text: root.headlineCaption
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 1
                  font.bold: true
                  font.letterSpacing: 1
                  horizontalAlignment: Text.AlignRight
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.heroExpanded = !root.heroExpanded
              }
            }
          }

          // ---- EXPANDED: overview line ----
          Column {
            visible: root.heroExpanded
            width: parent.width
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: {
                if (!root.snapshot) return ""
                var p = []
                if (root.snapshot.cpu && root.snapshot.cpu.model) {
                  var cpu = root.snapshot.cpu.model
                  var cores = root.snapshot.cpu.cores ? root.snapshot.cpu.cores.length : 0
                  p.push(cpu + (cores ? " (" + cores + ")" : ""))
                }
                if (root.snapshot.mem && root.snapshot.mem.total > 0) {
                  p.push(Model.bytesShort(root.snapshot.mem.total))
                }
                if (root.snapshot.mem && root.snapshot.mem.swap_total > 0) {
                  var hasZram = false
                  if (root.snapshot.blockdevs) {
                    for (var i = 0; i < root.snapshot.blockdevs.length; i++) {
                      if (root.snapshot.blockdevs[i].name && root.snapshot.blockdevs[i].name.indexOf("zram") === 0) { hasZram = true; break }
                    }
                  }
                  var label = hasZram ? "SWAP(zram)" : "SWAP(disk)"
                  p.push(label + ": " + Model.bytesShort(root.snapshot.mem.swap_used) + "/" + Model.bytesShort(root.snapshot.mem.swap_total))
                }
                return p.join("  \u00B7  ")
              }
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Separator
          Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.06) }

          // ---------- Tabs ----------
          Row {
            id: tabRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.tabs.length > 0
              ? (width - spacing * (root.tabs.length - 1)) / root.tabs.length
              : 0

            Repeater {
              model: root.tabs

              Button {
                required property var modelData
                required property int index

                width: tabRow.cellWidth
                text: modelData.label
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                fontFamily: root.fontFamily
                horizontalPadding: Style.space(4)
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.tabIndex === index && root.subPage === ""
                hasCursor: root.cursorActive && root.tabIndex === index && root.subPage === ""
                onClicked: { root.cursorActive = false; root.selectTab(index) }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Back button for sub-pages
          Item {
            width: parent.width
            height: root.subPage !== "" ? Style.space(28) : 0
            visible: root.subPage !== ""

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              radius: Style.space(6)
              color: root.alpha(root.foreground, 0.04)

              Text {
                text: "\u2190 Back"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goBack()
              }
            }
          }

          // ---------- Tab bodies: only the selected one is instantiated ----------
          Loader { width: parent.width; active: root.tabKey === "overview" && root.subPage === ""; visible: active; sourceComponent: overviewTab }
          Loader { width: parent.width; active: root.tabKey === "overview" && root.subPage === "net"; visible: active; sourceComponent: netTab }
          Loader { id: procLoader; width: parent.width; active: root.tabKey === "overview" && root.subPage === "proc"; visible: active; sourceComponent: procTabComponent }
          Loader { width: parent.width; active: root.tabKey === "cpu"; visible: active; sourceComponent: cpuTab }
          Loader { width: parent.width; active: root.tabKey === "temp"; visible: active; sourceComponent: tempTab }
          Loader { width: parent.width; active: root.tabKey === "mem"; visible: active; sourceComponent: memTab }
          Loader { width: parent.width; active: root.tabKey === "disk"; visible: active; sourceComponent: diskTab }
          Loader { width: parent.width; active: root.tabKey === "gpu"; visible: active; sourceComponent: gpuTab }
        }
      }
    }
  }

  // ======================================================= Overview
  Component {
    id: overviewTab

    Item {
      property var panel: root
      width: parent ? parent.width : 0
      height: overviewCol.implicitHeight + Style.space(20)

      Column {
        id: overviewCol
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        anchors.top: parent.top
        anchors.topMargin: Style.space(10)
        spacing: Style.space(8)

        // ---- System health header ----
        Item {
          width: parent.width
          height: healthLabel.implicitHeight

          Text {
            id: healthLabel
            text: "SYSTEM HEALTH"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "OK"
            textFormat: Text.PlainText
            color: "#66ff66"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---- Uptime + Load ----
        Text {
          width: parent.width
          text: {
            if (!root.snapshot) return ""
            var p = []
            if (root.snapshot.uptime) p.push("UP " + Model.uptime(root.snapshot.uptime))
            if (root.snapshot.load) p.push("LOAD " + Model.loadAvg(root.snapshot.load))
            return p.join("  \u00B7  ")
          }
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- CPU with meter ----
        Item {
          width: parent.width
          height: cpuLabel.implicitHeight + Style.space(8) + Style.space(6)

          Column {
            width: parent.width
            spacing: Style.space(2)

            Item {
              width: parent.width
              height: cpuLabel.implicitHeight

              Text {
                id: cpuLabel
                text: "CPU"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }
              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Text {
                  text: {
                    if (!root.snapshot || !root.snapshot.cpu) return ""
                    var cpu = root.snapshot.cpu
                    var freq = cpu.freq_mhz ? (" \u00B7 " + Model.mhz(cpu.freq_mhz)) : ""
                    return Model.percent(cpu.total) + freq
                  }
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "\u2192"
                  textFormat: Text.PlainText
                  color: "#4da6ff"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(6)
              radius: Style.space(3)
              color: root.alpha(root.foreground, 0.1)

              Rectangle {
                width: parent.width * root.clamp(root.snapshot && root.snapshot.cpu ? root.snapshot.cpu.total / 100 : 0, 0, 1)
                height: parent.height
                radius: parent.radius
                color: root.stateColor(root.snapshot && root.snapshot.cpu ? root.snapshot.cpu.total : 0, "#4da6ff")
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectTab(1)
          }
        }

        // ---- Memory with meter ----
        Item {
          width: parent.width
          height: memLabel.implicitHeight + Style.space(8) + Style.space(6)

          Column {
            width: parent.width
            spacing: Style.space(2)

            Item {
              width: parent.width
              height: memLabel.implicitHeight

              Text {
                id: memLabel
                text: "MEMORY"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }
              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Text {
                  text: {
                    if (!root.snapshot || !root.snapshot.mem) return ""
                    var m = root.snapshot.mem
                    var pct = m.total > 0 ? Math.round(m.used * 100 / m.total) : 0
                    return pct + "%  \u00B7  " + Model.bytesShort(m.used) + " / " + Model.bytesShort(m.total)
                  }
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "\u2192"
                  textFormat: Text.PlainText
                  color: "#4da6ff"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(6)
              radius: Style.space(3)
              color: root.alpha(root.foreground, 0.1)

              Rectangle {
                width: parent.width * root.clamp(root.snapshot && root.snapshot.mem && root.snapshot.mem.total > 0 ? root.snapshot.mem.used / root.snapshot.mem.total : 0, 0, 1)
                height: parent.height
                radius: parent.radius
                color: root.stateColor(root.snapshot && root.snapshot.mem && root.snapshot.mem.total > 0 ? root.snapshot.mem.used * 100 / root.snapshot.mem.total : 0, "#66ff66")
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectTab(3)
          }
        }

        // ---- Temp + Disk (side by side) ----
        Item {
          width: parent.width
          height: Style.space(20)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              text: "TEMP"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: {
                if (!root.snapshot || !root.snapshot.cpu) return ""
                var t = root.snapshot.cpu.temp
                if (t === null || t === undefined) return ""
                var c = Math.round(t)
                var band = root.tempBand(t)
                return c + "\u00B0" + " \u00B7 " + root.tempBands[band].label
              }
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "\u2192"
              textFormat: Text.PlainText
              color: "#4da6ff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              text: "DISK"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: {
                if (!root.snapshot || !root.snapshot.disks || root.snapshot.disks.length === 0) return ""
                var d = root.snapshot.disks[0]
                return Model.percent(d.used * 100 / d.total) + " \u00B7 " + Model.bytesShort(d.used) + " / " + Model.bytesShort(d.total)
              }
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "\u2192"
              textFormat: Text.PlainText
              color: "#4da6ff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.left: parent.left
            anchors.leftMargin: -Style.space(4)
            width: parent.width / 2
            height: parent.height
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectTab(2)
          }
          MouseArea {
            anchors.right: parent.right
            anchors.rightMargin: -Style.space(4)
            width: parent.width / 2
            height: parent.height
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectTab(4)
          }
        }

        // ---- Network with SSID + link ----
        Item {
          width: parent.width
          height: Style.space(20)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              text: "NETWORK"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: {
                if (!root.snapshot || !root.snapshot.net) return ""
                var n = root.snapshot.net
                var totalRx = 0, totalTx = 0
                if (n.ifaces) {
                  for (var i = 0; i < n.ifaces.length; i++) {
                    totalRx += n.ifaces[i].rx_bps || 0
                    totalTx += n.ifaces[i].tx_bps || 0
                  }
                }
                return "\u2193 " + Model.rate(totalRx) + "  \u2191 " + Model.rate(totalTx)
              }
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              text: {
                if (!root.snapshot || !root.snapshot.net) return ""
                var n = root.snapshot.net
                if (n.ifaces) {
                  for (var i = 0; i < n.ifaces.length; i++) {
                    if (n.ifaces[i].ssid) return n.ifaces[i].ssid
                  }
                }
                return ""
              }
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "\u2192"
              textFormat: Text.PlainText
              color: "#4da6ff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showSubPage("net")
          }
        }

        // ---- GPU (if present) ----
        Item {
          width: parent.width
          height: root.gpus.length > 0 ? Style.space(20) : 0
          visible: root.gpus.length > 0

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              text: "GPU"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: {
                if (!root.snapshot || !root.snapshot.gpus || root.snapshot.gpus.length === 0) return ""
                var g = root.snapshot.gpus[0]
                var pct = g.busy !== null && g.busy !== undefined ? Model.percent(g.busy) : ""
                var temp = g.temp !== null && g.temp !== undefined ? " \u00B7 " + Model.temp(g.temp) : ""
                return pct + temp
              }
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "\u2192"
              textFormat: Text.PlainText
              color: "#4da6ff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectTab(5)
          }
        }

        // ---- Separator ----
        Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.06) }

        // ---- Top Processes header + sort toggle ----
        Item {
          width: parent.width
          height: topProcLabel.implicitHeight

          Text {
            id: topProcLabel
            text: "TOP PROCESSES"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

              // CPU sort toggle
              Text {
                text: "CPU"
                textFormat: Text.PlainText
                color: root.overviewProcSort === "cpu" ? "#4da6ff" : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.overviewProcSort === "cpu"
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.overviewProcSort = "cpu"
                }
              }

              Text {
                text: "\u00B7"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              // RAM sort toggle
              Text {
                text: "RAM"
                textFormat: Text.PlainText
                color: root.overviewProcSort === "ram" ? "#4da6ff" : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.overviewProcSort === "ram"
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.overviewProcSort = "ram"
                }
              }

              Text {
                text: "\u00B7"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              // View all link
              Text {
                text: "View all \u2192"
                textFormat: Text.PlainText
                color: "#4da6ff"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showSubPage("proc")
                }
              }
          }
        }

        // ---- Top 3 processes ----
        Repeater {
          model: {
            if (!root.snapshot || !root.snapshot.processes) return []
            var procs = root.snapshot.processes.slice()
            if (root.overviewProcSort === "ram") {
              procs.sort(function(a, b) { return (b.mem || 0) - (a.mem || 0) })
            } else {
              procs.sort(function(a, b) { return (b.cpu || 0) - (a.cpu || 0) })
            }
            return procs.slice(0, 3)
          }

          Item {
            width: overviewCol.width - Style.space(14)
            height: procName.implicitHeight

            Text {
              id: procName
              text: modelData.name || ""
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              width: parent.width * 0.6
            }
            Text {
              text: root.overviewProcSort === "ram"
                ? Model.bytesShort(modelData.mem || 0)
                : Model.percent(modelData.cpu || 0)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showSubPage("proc")
            }
          }
        }
      }
    }
  }

  // ======================================================= CPU
  Component {
    id: cpuTab

    CpuTab { panel: root }
  }

  // ======================================================= Temps
  Component {
    id: tempTab

    TempTab { panel: root }
  }

  // ======================================================= Memory
  Component {
    id: memTab

    MemTab { panel: root }
  }

  // ======================================================= Disks
  Component {
    id: diskTab

    DiskTab { panel: root }
  }

  // ======================================================= Network
  Component {
    id: netTab

    NetTab { panel: root }
  }

  // ======================================================= GPU
  Component {
    id: gpuTab

    GpuTab { panel: root }
  }

  // ======================================================= Processes
  Component {
    id: procTabComponent

    ProcTab { panel: root
      listModel: procModel }
  }

  // ------------------------------------------------------------- components

  // Small bordered button for row actions.
  component ActionPill: ActionPillComponent {
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  // Transport glyph + name on the left, dim metadata flush right
  // (same anchored layout idiom as SectionRow).
  component DriveHeading: DriveHeadingComponent {
    foreground: root.foreground
    dim: root.dim
    fontFamily: root.fontFamily
  }

  // Label on the left, value on the right; the value optionally dimmed.
  component SectionRow: SectionRowComponent {
    foreground: root.foreground
    dim: root.dim
    fontFamily: root.fontFamily
  }

  // Rounded track with a proportional fill. Deliberately NOT animated: the
  // panel is a full-screen layer surface, and a per-tick width animation
  // forces it to re-render for ~300 ms of every second (~2.5% of a core);
  // snapping costs ~0.4%. Interaction-only animations (hover, expand) stay.
  component Meter: MeterComponent {
    fillColor: root.foreground
    trackColor: root.track
  }

  // Label · bar · amount, for memory breakdown rows.
  component ShareRow: ShareRowComponent {
    foreground: root.foreground
    dim: root.dim
    track: root.track
    fontFamily: root.fontFamily
  }

  // Caption over a value, for the network stat strip.
  component StatCell: StatCellComponent {
    foreground: root.foreground
    dim: root.dim
    fontFamily: root.fontFamily
  }

  // Sortable column header for the process table.
  component ColumnHeader: ColumnHeaderComponent {
    activeSort: root.sortKey === key
    sortReverse: root.sortReverse
    foreground: root.foreground
    faint: root.faint
    fontFamily: root.fontFamily
    onSortRequested: function(k) { root.setSort(k) }
  }

  component InfoPair: InfoPairComponent {
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  // Quiet line chart of the last N samples (implementation in
  // components/SparklineComponent.qml).
  component Sparkline: SparklineComponent {
    lineColor: root.foreground
    historyLength: root.historyLength
  }
}
