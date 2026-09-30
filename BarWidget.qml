import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// The bar face of Break Time. One glyph. Click opens the settings panel.
//
// The bar mounts one of these per monitor. All of them read the same state
// file. Only the first one in the bar's slot order ("the writer") advances the
// schedule and raises the popup, so two monitors never raise two popups.
BarWidget {
  id: root
  moduleName: "mjasnikovs.breaktime"

  readonly property bool enabled: Model.boolSetting(setting("enabled", true), true)
  readonly property int intervalMinutes: Model.intervalMinutes(setting("intervalMinutes", 30))
  readonly property real intervalMs: intervalMinutes * Model.MS_PER_MINUTE

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/breaktime"
  readonly property string statePath: stateDir + "/state.json"

  property var state: Model.defaultState(Date.now(), intervalMs)
  property real now: Date.now()
  property bool stateLoaded: false
  property bool stateSeedNeeded: false

  // Only probed while a reminder is overdue, and not more than once per
  // LOCK_PROBE_MS, so nothing runs on the timer during normal operation.
  readonly property int lockProbeMs: 15000
  property real lastLockProbeAt: 0
  property bool locked: false

  // "Due but no card on screen" must hold for this long before the card is
  // raised again. The popup's own Done/Snooze write lands within
  // milliseconds; a shell restart leaves the gap open for good.
  readonly property int reraiseAfterMs: 3000
  property real dueClosedSince: 0

  readonly property string status: Model.statusOf(state, enabled, now)
  readonly property real remainingMs: Model.remainingMs(state, now)

  readonly property string glyphText: "󰅶"
  readonly property color baseForeground: bar ? bar.barForeground : Color.foreground
  readonly property color glyphColor: {
    if (root.status === "due") return bar ? bar.urgent : Color.urgent
    return root.baseForeground
  }

  // ---- Writer election.
  function amWriter() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var peers = bar.moduleWidgets(moduleName)
    return peers.length === 0 || peers[0] === root
  }

  // Any instance may write. The clock is refreshed first so a panel on this
  // screen shows the new state without waiting for the next tick.
  function commit(next) {
    if (!next) return
    root.now = Date.now()
    root.state = next
    stateFile.setText(Model.serializeState(next))
  }

  function adopt(text) {
    root.state = Model.parseState(text, Date.now(), root.intervalMs)
  }

  // ---- The scheduler. Once a second on the writer.
  function tick() {
    root.now = Date.now()
    if (!root.amWriter()) return

    if (root.stateSeedNeeded) {
      root.stateSeedNeeded = false
      root.commit(Model.start(root.now, root.intervalMs))
      return
    }

    if (!root.enabled) return

    // Due but no card on screen: the shell restarted under an open popup.
    // Raise it again once that has been true for a moment.
    if (root.state.due && !root.popupOpen()) {
      root.settleOverdueBreak()
      if (root.dueClosedSince === 0) root.dueClosedSince = root.now
      else if (root.now - root.dueClosedSince >= root.reraiseAfterMs) root.requestPopup()
      return
    }
    root.dueClosedSince = 0

    var action = Model.tick(root.state, root.now)
    if (action === "restart") root.commit(Model.start(root.now, root.intervalMs))
    else if (action === "fire") root.requestPopup()
  }

  // The popup ends the break itself. This is the fallback for a popup that
  // never reported back (shell killed mid-break).
  function settleOverdueBreak() {
    if (!root.amWriter() || !root.enabled) return
    if (!Model.isBreakOver(root.state, root.now + Model.MS_PER_MINUTE)) return
    root.commit(Model.finishBreak(root.now, root.intervalMs))
  }

  // Never raise the popup over the lock screen. Ask the shell, but not more
  // than once every lockProbeMs.
  function requestPopup() {
    var at = Date.now()
    if (at - root.lastLockProbeAt < root.lockProbeMs) return
    root.lastLockProbeAt = at
    if (!lockProbe.running) lockProbe.running = true
  }

  function popupOpen() {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.isPluginOpen !== "function") return false
    return host.isPluginOpen(root.moduleName) === true
  }

  function applyLockProbe(raw) {
    root.locked = String(raw || "").trim() === "true"
    if (root.locked) return
    if (!root.amWriter() || !root.enabled) return
    var stillDue = root.state.due && !root.popupOpen()
    if (!stillDue && Model.tick(root.state, Date.now()) !== "fire") return
    root.showPopup()
  }

  function showPopup() {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.summon !== "function") {
      root.commit(Model.start(Date.now(), root.intervalMs))
      return
    }

    // A break already running (shell restarted under the popup) keeps its
    // start time so the progress bar carries on where it was.
    if (!root.state.due) root.commit(Model.fire(root.state, Date.now()))
    var raised = host.summon(root.moduleName, JSON.stringify({
      statePath: root.statePath,
      intervalMs: root.intervalMs
    })) === true

    // Overlay failed to load (happens during a hot-reload). Start over rather
    // than sit on "due" forever.
    if (!raised) root.commit(Model.start(Date.now(), root.intervalMs))
  }

  // ---- Actions. Shared by the panel and the IPC target. Any instance may
  //      run them; they all end in one write every instance reads back.
  function restart() { root.commit(Model.start(Date.now(), root.intervalMs)) }
  function snoozeNow() { root.commit(Model.snooze(root.state, Date.now())) }

  // The user asked for it, so nobody is behind a lock screen. Straight to
  // the popup, no probe, from whichever screen was clicked.
  function breakNow() {
    if (!root.enabled) return
    if (root.state.due && root.popupOpen()) return
    root.lastLockProbeAt = Date.now()
    root.showPopup()
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Either way the timer starts over. Turning off while the popup is up
  // takes the popup down: it watches the file and closes when "due" clears.
  function setEnabled(value) {
    var next = value === true
    if (next === root.enabled) return
    root.persistSettings({ enabled: next })
    root.restart()
  }

  function setInterval(minutes) {
    var next = Model.intervalMinutes(minutes)
    if (next === root.intervalMinutes) return
    root.persistSettings({ intervalMinutes: next })
    root.commit(Model.start(Date.now(), next * Model.MS_PER_MINUTE))
  }

  function statusJson() {
    var at = Date.now()
    return JSON.stringify({
      status: Model.statusOf(root.state, root.enabled, at),
      enabled: root.enabled,
      intervalMinutes: root.intervalMinutes,
      remainingSeconds: Math.ceil(Model.remainingMs(root.state, at) / 1000),
      breakRemainingSeconds: Math.ceil(Model.breakRemainingMs(root.state, at) / 1000),
      snoozes: root.state.snoozes,
      locked: root.locked
    })
  }

  // ---- Panel plumbing. Shape contract for shell summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Component.onCompleted: ensureDirProc.running = true

  SystemClock {
    id: clock
    precision: SystemClock.Seconds
    onDateChanged: root.tick()
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: Qt.callLater(function() { stateFile.reload() })
  }

  Process {
    id: lockProbe
    command: ["omarchy-shell", "lock", "isLocked"]
    stdout: StdioCollector { id: lockOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyLockProbe(exitCode === 0 ? lockOut.text : "false")
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.stateLoaded = true
      root.adopt(stateFile.text())
    }
    onFileChanged: stateFile.reload()
    onLoadFailed: {
      if (root.stateLoaded) return
      root.state = Model.defaultState(Date.now(), root.intervalMs)
      root.stateSeedNeeded = true
    }
  }

  // Five minutes without mouse or keyboard means the user left. Inhibitors
  // (a playing video) do not count: a film is still screen time.
  IdleMonitor {
    id: idleMonitor
    enabled: root.enabled
    timeout: Model.IDLE_RESET_SECONDS
    respectInhibitors: false
    onIsIdleChanged: {
      if (!root.amWriter() || !root.enabled) return
      var at = Date.now()
      root.now = at
      if (idleMonitor.isIdle) root.commit(Model.goIdle(root.state, at))
      else root.commit(Model.endIdle(root.state, at, root.intervalMs))
    }
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

  IpcHandler {
    target: "mjasnikovs.breaktime"

    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function reset(): void { root.restart() }
    function snooze(): void { root.snoozeNow() }
    function breakNow(): void { root.breakNow() }
    function interval(minutes: int): void { root.setInterval(minutes) }
    function enable(): void { root.setEnabled(true) }
    function disable(): void { root.setEnabled(false) }
    function status(): string { return root.statusJson() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphText
    foreground: root.glyphColor
    dimmed: !root.enabled || root.status === "away"
    tooltipText: Model.tooltipFor(root.state, root.enabled, root.intervalMinutes, root.now)

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.breakNow()
      else root.togglePanel()
    }
  }
}
