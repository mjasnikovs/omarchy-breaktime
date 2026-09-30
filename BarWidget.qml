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
// file. Only the first one in the bar's slot order ("the writer") runs the
// scheduler: it fires, finishes, and restarts breaks on the clock, and it
// alone reacts to the on/off setting. Any instance may write a user action
// (reset, snooze, break now, interval); every write is the whole state, so
// the last one wins and nothing is merged.
BarWidget {
  id: root
  moduleName: "mjasnikovs.breaktime"

  readonly property bool enabled: Model.boolSetting(setting("enabled", true), true)
  readonly property int intervalMinutes: Model.intervalMinutes(setting("intervalMinutes", Model.DEFAULT_INTERVAL_MINUTES))
  readonly property real intervalMs: intervalMinutes * Model.MS_PER_MINUTE

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/breaktime"
  readonly property string statePath: stateDir + "/state.json"

  // A copy of the file. commit() sets it ahead of the write so this screen
  // redraws at once; the file watch replaces it with what actually landed.
  property var state: Model.start(Date.now(), intervalMs)

  // Display clock. Refreshed every tick and on every write, so a panel on
  // this screen never shows a value derived from a second-old clock.
  property real now: Date.now()

  property bool stateLoaded: false
  property bool stateSeedNeeded: false

  // Set on the first load when the file already says a break is on: the
  // shell restarted under an open popup. The first tick raises it again.
  property bool raiseOnFirstTick: false

  // The lock probe runs only when a reminder comes due, and no more than
  // once per lockProbeMs while the screen stays locked.
  readonly property int lockProbeMs: 15000
  property real lastLockProbeAt: 0

  readonly property string status: Model.statusOf(state, enabled)

  readonly property string glyphText: "󰔟"
  readonly property color baseForeground: bar ? bar.barForeground : Color.foreground
  readonly property color glyphColor: root.status === "due" ? (bar ? bar.urgent : Color.urgent) : root.baseForeground

  // ---- Writer election.
  function amWriter() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var peers = bar.moduleWidgets(moduleName)
    return peers.length === 0 || peers[0] === root
  }

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

    var action = Model.tick(root.state, root.now)

    // A break that ran out is finished whether or not the plugin is on, so
    // a card never sits at 0:00 after shell.json was edited by hand.
    if (action === "finish") {
      root.commit(Model.finishBreak(root.state, root.now, root.intervalMs))
      return
    }
    if (!root.enabled) return

    if (root.raiseOnFirstTick) {
      root.raiseOnFirstTick = false
      if (Model.isDue(root.state)) root.requestPopup()
      return
    }

    if (action === "restart") root.commit(Model.start(root.now, root.intervalMs))
    else if (action === "fire") root.requestPopup()
  }

  // Never raise the popup over the lock screen. Ask the shell first.
  function requestPopup() {
    var at = Date.now()
    if (at - root.lastLockProbeAt < root.lockProbeMs) return
    root.lastLockProbeAt = at
    if (!lockProbe.running) lockProbe.running = true
  }

  // The probe took time. Check again that a card is still wanted: the state
  // may have moved on (snooze, reset, break finished, plugin turned off).
  function applyLockProbe(raw) {
    if (String(raw || "").trim() === "true") return
    if (!root.enabled || !root.amWriter()) return
    var now = Date.now()
    var wanted = Model.isDue(root.state)
      ? !Model.isBreakOver(root.state, now)
      : Model.tick(root.state, now) === "fire"
    if (wanted) root.showPopup()
  }

  function popupOpen() {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.isPluginOpen !== "function") return false
    return host.isPluginOpen(root.moduleName) === true
  }

  // Write "break on" first, then summon. The write blocks, so the popup's
  // first read of the file already agrees with the payload it was handed.
  function showPopup() {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.summon !== "function") return
    if (root.popupOpen()) return

    // A break already on (shell restarted under the popup) keeps its start
    // time so the progress bar carries on where it was.
    var next = Model.isDue(root.state) ? root.state : Model.fire(root.state, Date.now())
    root.commit(next)

    var raised = host.summon(root.moduleName, JSON.stringify({ breakStartedAt: next.breakStartedAt })) === true

    // The shell refused (plugin disabled or unknown at that moment). No
    // break was offered, so start over rather than sit on "due".
    if (!raised) root.commit(Model.start(Date.now(), root.intervalMs))
  }

  // ---- Actions. Any instance may run them.
  function restart() { root.commit(Model.start(Date.now(), root.intervalMs)) }

  // Snooze means "not this break". Outside a break it would only pull the
  // next reminder closer, so it does nothing.
  function snoozeNow() {
    if (!Model.isDue(root.state)) return
    root.commit(Model.snooze(root.state, Date.now()))
  }

  // The user asked for it, so nobody is behind a lock screen.
  function breakNow() {
    if (!root.enabled) return
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

  // Only the setting is written here. The writer reacts to the change in
  // onEnabledChanged below, whether it came from this panel, another
  // screen's panel, or a hand edit of shell.json.
  function setEnabled(value) {
    var next = value === true
    if (next === root.enabled) return
    root.persistSettings({ enabled: next })
  }

  // During a break only the setting changes; finishBreak picks up the new
  // interval. Otherwise the timer starts over at the new length.
  function setInterval(minutes) {
    var next = Model.intervalMinutes(minutes)
    if (next === root.intervalMinutes) return
    root.persistSettings({ intervalMinutes: next })
    if (!Model.isDue(root.state)) root.commit(Model.start(Date.now(), next * Model.MS_PER_MINUTE))
  }

  // Either way the timer starts over. Turning off during a break takes the
  // popup down: it watches the file and closes when the break is gone.
  onEnabledChanged: if (root.stateLoaded && root.amWriter()) root.restart()

  function statusJson() {
    var at = Date.now()
    return JSON.stringify({
      status: Model.statusOf(root.state, root.enabled),
      enabled: root.enabled,
      intervalMinutes: root.intervalMinutes,
      remainingSeconds: Math.ceil(Model.remainingMs(root.state, at) / 1000),
      breakRemainingSeconds: Math.ceil(Model.breakRemainingMs(root.state.breakStartedAt, at) / 1000),
      snoozes: root.state.snoozes
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
    blockWrites: true
    printErrors: false
    onLoaded: {
      var first = !root.stateLoaded
      root.stateLoaded = true
      root.stateSeedNeeded = false
      root.adopt(stateFile.text())
      if (first && Model.isDue(root.state)) root.raiseOnFirstTick = true
    }
    onFileChanged: stateFile.reload()
    onLoadFailed: {
      if (root.stateLoaded) return
      root.state = Model.start(Date.now(), root.intervalMs)
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
      if (idleMonitor.isIdle) root.commit(Model.goIdle(root.state, at))
      else root.commit(Model.endIdle(at, root.intervalMs))
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
