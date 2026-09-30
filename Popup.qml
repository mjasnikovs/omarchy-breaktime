import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// The break card. One small centered window per monitor. Work stays visible
// around it. A progress bar fills over the 5-minute break. The bar widget
// ends the break when the time is up; this card only shows it, and closes
// when the file no longer holds the break it was opened for.
//
// The one thing the card writes is a snooze. Everything else that changes
// the file (break over, user came back, plugin turned off) happens in the
// bar widget, and the card follows through its file watch.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false
  // Fixed on purpose. The summon payload never chooses where this card
  // reads or writes.
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/breaktime/state.json"

  // Which break this card belongs to. When the file's breakStartedAt is
  // anything else, this card is stale and closes.
  property real breakStartedAt: 0
  property real now: Date.now()

  readonly property real progress: Model.breakProgress(breakStartedAt, now)
  readonly property string clockText: Model.formatClock(Model.breakRemainingMs(breakStartedAt, now))

  readonly property string fontFamily: Style.font.family
  readonly property color foreground: Color.popups.text
  readonly property color background: Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color trackColor: Style.selectedFillFor(foreground, Color.accent)
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

    var startedAt = Number(payload.breakStartedAt)
    root.now = Date.now()
    // Summoned by hand from a terminal: show a break starting now.
    root.breakStartedAt = isFinite(startedAt) && startedAt > 0 ? startedAt : root.now
    root.opened = true
    stateFile.reload()
  }

  // Called by the shell when something else hides this plugin (for example
  // `omarchy-shell shell hide`). Treat it as "not now".
  function close() {
    if (root.opened) root.snooze()
  }

  function snooze() {
    if (!root.opened) return
    root.opened = false
    var at = Date.now()
    var current = Model.parseState(stateFile.text(), at, Model.DEFAULT_INTERVAL_MINUTES * Model.MS_PER_MINUTE)
    stateFile.setText(Model.serializeState(Model.snooze(current, at)))
    root.dismiss()
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mjasnikovs.breaktime")
  }

  // The file is the truth. If it no longer holds this break, close.
  function syncWithFile() {
    if (!root.opened) return
    var current = Model.parseState(stateFile.text(), Date.now(), Model.DEFAULT_INTERVAL_MINUTES * Model.MS_PER_MINUTE)
    if (current.breakStartedAt !== root.breakStartedAt) root.dismiss()
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.snooze()
      event.accepted = true
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onFileChanged: stateFile.reload()
    onLoaded: root.syncWithFile()
  }

  // 250 ms so the bar moves smoothly rather than in one-second steps.
  Timer {
    interval: 250
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
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
              text: "󰔟"
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

            // ---- The break itself: a bar that fills over five minutes.
            Item {
              width: Style.space(320)
              height: meter.height + clock.implicitHeight + Style.space(6)

              Rectangle {
                id: meter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: Math.max(6, Style.space(8))
                radius: height / 2
                color: root.trackColor

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: parent.width * root.progress
                  radius: parent.radius
                  color: Color.accent
                }
              }

              Text {
                id: clock
                anchors.top: meter.bottom
                anchors.topMargin: Style.space(6)
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: root.clockText + " left"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Snooze 5 min"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.snooze()
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "esc snooze"
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
