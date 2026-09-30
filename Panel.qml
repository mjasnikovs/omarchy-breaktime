import QtQuick
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// Settings for Break Time: an on/off switch, an interval slider, and a
// line saying when the next break is due.
//
// This panel owns no state. It reads off `hostWidget` (the BarWidget on this
// screen) and calls its actions; the widget does the writes.
Panel {
  id: root
  moduleName: "mjasnikovs.breaktime"
  ipcTarget: "mjasnikovs.breaktime"
  manageIpc: false

  property var anchorItem: null

  // The bar identifies this panel by the widget mounted in its slot, not by
  // this nested item. Bare (no host) only during the bar's own instantiation.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool enabled: hostWidget ? hostWidget.enabled : true
  readonly property int intervalMinutes: hostWidget ? hostWidget.intervalMinutes : Model.DEFAULT_INTERVAL_MINUTES
  readonly property string statusLine: hostWidget
    ? Model.statusText(hostWidget.state, hostWidget.enabled, hostWidget.now) : ""

  readonly property color contentForeground: Color.popups.text
  readonly property string contentFontFamily: Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.5)

  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    root.controller.hide()
    root.setCenterHoverRevealSuppressed(false)
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function flipEnabled() { if (root.hostWidget) root.hostWidget.setEnabled(!root.enabled) }
  function setInterval(minutes) { if (root.hostWidget) root.hostWidget.setInterval(minutes) }
  function stepInterval(delta) { root.setInterval(root.intervalMinutes + delta) }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onActivateRequested: root.flipEnabled()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.stepInterval(dx * 5)
        if (dy !== 0) root.stepInterval(-dy * 5)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        // ---- Title and switch
        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, enabledSwitch.implicitHeight)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Break Time"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          ToggleSwitch {
            id: enabledSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.enabled
            foreground: root.contentForeground
            onToggled: root.flipEnabled()
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.statusLine
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        // ---- Interval
        Item {
          width: parent.width
          height: Math.max(intervalLabel.implicitHeight, intervalValue.implicitHeight)

          Text {
            id: intervalLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Remind me every"
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: intervalValue
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Math.round(intervalSlider.liveValue) + " min"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSlider {
          id: intervalSlider
          width: parent.width
          bar: root.bar
          minimum: Model.MIN_INTERVAL_MINUTES
          maximum: Model.MAX_INTERVAL_MINUTES
          step: 5
          integer: true
          value: root.intervalMinutes
          onReleased: function(v) { root.setInterval(v) }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        // ---- Actions
        Row {
          anchors.right: parent.right
          spacing: Style.space(8)

          Button {
            text: "Reset timer"
            bordered: true
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: if (root.hostWidget) root.hostWidget.restart()
          }

          Button {
            text: "Break now"
            bordered: true
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: { root.close(); if (root.hostWidget) root.hostWidget.breakNow() }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "space on/off   ←→ interval   esc close"
          color: Qt.darker(root.contentForeground, 2.0)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
