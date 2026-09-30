import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// The reminder card. One small centered window per monitor. Work stays
// visible around it. Snooze pushes the reminder 5 minutes out. Done starts
// a fresh interval.
//
// The bar widget summons this with the state file path and the interval.
// The card writes the outcome to that file itself; the bar widget picks it
// up through its file watch. If the file stops saying "due" (the user walked
// away and came back), the card closes on its own.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false
  // A file change arriving this soon after open is the bar widget's own
  // "fire" write landing, not the user coming back from a break.
  readonly property int settleMs: 2000
  property real openedAt: 0
  property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/breaktime/state.json"
  property real intervalMs: Model.DEFAULT_INTERVAL_MINUTES * Model.MS_PER_MINUTE

  readonly property string fontFamily: Style.font.family
  readonly property color foreground: Color.popups.text
  readonly property color background: Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  readonly property string titleText: "Time for a break"
  readonly property string bodyText: "Drink water, stretch your legs, don't look at screens!"

  function open(payloadJson) {
    if (root.opened) return

    var payload = ({})
    try {
      payload = JSON.parse(payloadJson || "{}")
    } catch (e) {
      payload = ({})
    }

    if (payload.statePath) root.statePath = String(payload.statePath)
    var interval = Number(payload.intervalMs)
    if (isFinite(interval) && interval > 0) root.intervalMs = interval

    root.openedAt = Date.now()
    root.opened = true
    stateFile.reload()
  }

  // Called by the shell on hide. A close from outside (hotkey, shell
  // restart) counts as a snooze so the reminder comes back.
  function close() {
    if (root.opened) root.finish("snooze")
  }

  function snooze() { root.finish("snooze") }
  function done() { root.finish("done") }

  function finish(outcome) {
    if (!root.opened) return
    root.opened = false
    root.writeOutcome(outcome)
    root.dismiss()
  }

  function writeOutcome(outcome) {
    var at = Date.now()
    var current = Model.parseState(stateFile.text(), at, root.intervalMs)
    var next = outcome === "done" ? Model.done(at, root.intervalMs) : Model.snooze(current, at)
    stateFile.setText(Model.serializeState(next))
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mjasnikovs.breaktime")
  }

  // The bar widget cleared "due" behind our back (user came back after a
  // real break). Nothing left to ask.
  function syncWithFile() {
    if (!root.opened) return
    if (Date.now() - root.openedAt < root.settleMs) return
    var current = Model.parseState(stateFile.text(), Date.now(), root.intervalMs)
    if (!current.due) root.dismiss()
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.snooze()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.done()
      event.accepted = true
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: stateFile.reload()
    onLoaded: root.syncWithFile()
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: window
        required property var modelData

        screen: modelData
        visible: root.opened
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight
        WlrLayershell.namespace: "omarchy-breaktime"
        WlrLayershell.layer: WlrLayer.Overlay
        // OnDemand: keys work once the card is clicked. Typing elsewhere is
        // never stolen by a reminder.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

        BorderSurface {
          id: card
          anchors.centerIn: parent
          color: root.background
          radius: Style.cornerRadius
          borderSpec: root.borderSpec
          padding: Style.space(24)
          implicitWidth: column.implicitWidth + padding * 2
          implicitHeight: column.implicitHeight + padding * 2

          Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { root.handleKey(event) }
          }

          MouseArea {
            anchors.fill: parent
            onPressed: function(mouse) {
              keyCatcher.forceActiveFocus()
              mouse.accepted = false
            }
          }

          Column {
            id: column
            anchors.centerIn: parent
            spacing: Style.space(14)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "󰅶"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.fontPx(3)
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.titleText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              width: Style.space(320)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.bodyText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Item { width: 1; height: Style.space(4) }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(10)

              Button {
                text: "Snooze 5 min"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.snooze()
              }

              Button {
                text: "Done"
                bordered: true
                selected: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.done()
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "esc snooze   enter done"
              color: Qt.darker(root.foreground, 2.0)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
