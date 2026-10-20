import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "zangetsu.electroline"
  ipcTarget: "electroline"
  manageIpc: false

  readonly property bool hideWhenAllOff: setting("hideWhenAllOff", false) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // A card has to lift off the panel without inventing a colour the theme never
  // chose, so both surfaces are the foreground at a low alpha.
  readonly property color cardFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color cardLine: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

  readonly property bool unavailable: ac.lastError !== "" || ac.needsLogin
  readonly property color barIconColor: ac.anyOn ? barForeground : Qt.darker(barForeground, 1.55)

  visible: !hideWhenAllOff || ac.anyOn
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: ac
    settings: root.settings
    panelOpen: root.opened
  }

  // --- Keyboard cursor ---------------------------------------------------
  //
  // Every panel in Omarchy walks with j/k and acts with Enter, so this one
  // does too. The cursor is kept as "<puid>/<control>" rather than an index:
  // the list of stops is rebuilt whenever a unit turns on or off, and an index
  // would then point at whatever slid into that slot.
  property string cursorKey: ""
  // Dropdowns handle their own keys while open, so the panel steps aside.
  property int openDropdowns: 0
  // Each dropdown registers itself so Enter can open the one under the cursor.
  property var controls: ({})

  readonly property var stops: {
    var list = []
    var units = ac.units
    for (var i = 0; i < units.length; i++) {
      var unit = units[i]
      if (!unit.online) continue
      list.push({ puid: unit.puid, kind: "power" })
      if (!Model.isOn(unit)) continue
      if (unit.targetProperty !== "") list.push({ puid: unit.puid, kind: "temp" })
      if (unit.ecoProperty !== "") list.push({ puid: unit.puid, kind: "eco" })
      if (unit.modeProperty !== "") list.push({ puid: unit.puid, kind: "mode" })
      if (unit.fanProperty !== "") list.push({ puid: unit.puid, kind: "fan" })
      if (unit.sleepProperty !== "") list.push({ puid: unit.puid, kind: "sleep" })
      if (unit.swingProperty !== "") list.push({ puid: unit.puid, kind: "swing" })
    }
    return list
  }

  function stopKey(puid, kind) { return puid + "/" + kind }
  function isCursor(puid, kind) { return cursorKey === stopKey(puid, kind) }
  function setCursor(puid, kind) { cursorKey = stopKey(puid, kind) }

  function cursorPosition() {
    for (var i = 0; i < stops.length; i++) {
      if (stopKey(stops[i].puid, stops[i].kind) === cursorKey) return i
    }
    return -1
  }

  function moveCursor(delta) {
    if (stops.length === 0) return
    var at = cursorPosition()
    // The first keypress lands on an end rather than jumping to the middle.
    if (at < 0) {
      var start = delta > 0 ? 0 : stops.length - 1
      cursorKey = stopKey(stops[start].puid, stops[start].kind)
      return
    }
    var next = Math.max(0, Math.min(stops.length - 1, at + delta))
    cursorKey = stopKey(stops[next].puid, stops[next].kind)
  }

  // Left and right only mean something on the temperature, where they are the
  // one-degree buttons without the mouse.
  function moveCursorH(delta) {
    var at = cursorPosition()
    if (at < 0) { moveCursor(delta > 0 ? 1 : -1); return }
    var stop = stops[at]
    if (stop.kind === "temp") ac.stepTarget(stop.puid, delta > 0 ? 1 : -1)
  }

  function activateCursor() {
    var at = cursorPosition()
    if (at < 0) { moveCursor(1); return }
    var stop = stops[at]
    if (stop.kind === "power") { ac.togglePower(stop.puid); return }
    if (stop.kind === "eco") {
      var unit = ac.unitAt(stop.puid)
      ac.setEco(stop.puid, !(unit && unit.eco === 1))
      return
    }
    if (stop.kind === "temp") return
    var control = controls[stopKey(stop.puid, stop.kind)]
    if (control) control.open()
  }

  function registerControl(puid, kind, item) {
    controls[stopKey(puid, kind)] = item
  }

  function forgetControl(puid, kind) {
    delete controls[stopKey(puid, kind)]
  }

  // A cursor left behind would highlight a control nobody is looking at.
  onOpenedChanged: if (!opened) {
    cursorKey = ""
    // Closing takes every popup with it, and a count left above zero would
    // keep the panel deaf to j/k and Enter the next time it opens.
    openDropdowns = 0
  }

  // A tile destroyed while its list is open — the unit went offline, or someone
  // turned it off from the phone, and the poll rebuilt the cards — never
  // reports the popup closing.
  function tileOpenChanged(isOpen) {
    openDropdowns = Math.max(0, openDropdowns + (isOpen ? 1 : -1))
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { ac.refresh(); return "ok" }
    // "No air conditioner" before the first poll would be a lie told to whoever
    // scripted this.
    function status(): string { return ac.loading ? "Loading…" : ac.summary }
    function error(): string { return ac.lastError === "" ? "none" : ac.lastError }
    // Takes the puid the panel shows, so a keybinding can drive one unit.
    function power(puid: string, on: string): string {
      ac.setPower(puid, on === "on" || on === "1" || on === "true")
      return "ok"
    }
    function temperature(puid: string, celsius: string): string {
      ac.setTarget(puid, parseInt(celsius, 10))
      return "ok"
    }
  }

  // Every tile is a dropdown wired to the panel cursor the same way, so the
  // wiring lives here once and each tile only brings its own data.
  component CardTile: Dropdown {
    id: tile
    required property string puid
    required property string kind

    fontFamily: root.fontFamily
    hasCursor: root.isCursor(tile.puid, tile.kind)
    onHovered: function (on) { if (on) root.setCursor(tile.puid, tile.kind) }
    onPopupOpenChanged: root.tileOpenChanged(tile.popupOpen)
    Component.onCompleted: root.registerControl(tile.puid, tile.kind, tile)
    Component.onDestruction: {
      root.forgetControl(tile.puid, tile.kind)
      if (tile.popupOpen) root.tileOpenChanged(false)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        AcIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          filled: ac.anyOn
          crossed: root.unavailable
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.MiddleButton) ac.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.openDropdowns > 0
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: root.activateCursor()
      onTextKey: function (t) {
        if (t === "r" || t === "R") ac.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Electroline"
          meta: ac.loading ? "Loading…" : ac.summary
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: ac.anyOn ? 1.0 : 0.5
          iconComponent: Component {
            AcIcon {
              iconSize: Style.font.display
              color: ac.anyOn ? root.foreground : root.dim
              filled: ac.anyOn
              crossed: root.unavailable
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: ac.actionStatus !== "" || ac.lastError !== ""
          width: parent.width
          text: ac.actionStatus !== "" ? ac.actionStatus : ac.lastError
          color: ac.lastError !== "" && ac.actionStatus === "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: ac.needsLogin || (!ac.installed && ac.checkedInstall)
          width: parent.width
          text: "Run scripts/setup-electroline in this plugin's folder to sign in to ConnectLife."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // One card per unit: everything about a machine inside its own frame,
        // because two machines side by side in one flat list is what made the
        // first version unreadable.
        Repeater {
          model: ac.units

          Rectangle {
            id: card
            required property var modelData

            readonly property bool on: Model.isOn(modelData)
            readonly property bool reachable: modelData.online
            readonly property string puid: modelData.puid
            // What the slider shows mid-drag, before anything is sent.
            readonly property int shownTarget: slider.dragging
              ? Math.round(slider.liveValue)
              : (modelData.target === null ? Model.MIN_TEMP : modelData.target)

            width: column.width
            implicitHeight: inner.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: root.cardFill
            border.color: root.cardLine
            border.width: 1
            opacity: card.reachable ? 1.0 : 0.55

            Column {
              id: inner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              // Name on the left with the room reading beside it, power on the
              // right: the two things you look for before anything else.
              Item {
                width: parent.width
                implicitHeight: Math.max(name.implicitHeight, powerButton.height)

                Text {
                  id: name
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  // Capped rather than stretched: a long room name gives way to
                  // the reading beside it instead of pushing it off the card.
                  width: Math.min(implicitWidth,
                                  parent.width - powerButton.width - ambient.implicitWidth - Style.space(20))
                  elide: Text.ElideRight
                  text: card.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: ambient
                  textFormat: Text.PlainText
                  anchors.left: name.right
                  anchors.leftMargin: Style.space(8)
                  anchors.baseline: name.baseline
                  text: Model.formatTemp(card.modelData.current, true)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                PanelActionButton {
                  id: powerButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "⏻"
                  tooltipText: card.on ? "Turn off" : "Turn on"
                  bordered: true
                  enabled: card.reachable
                  hasCursor: root.isCursor(card.puid, "power")
                  foreground: card.on ? Color.accent : root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onHovered: function (on) { if (on) root.setCursor(card.puid, "power") }
                  onClicked: ac.togglePower(card.puid)
                }
              }

              // A sleeping unit still says what it would do once woken, so the
              // card is worth reading even when there is nothing to drive.
              Text {
                textFormat: Text.PlainText
                visible: !card.on && card.reachable && text !== ""
                width: parent.width
                text: Model.offSummary(card.modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              // Everything below only means something while the unit runs.
              Column {
                width: parent.width
                spacing: Style.space(10)
                visible: card.on && card.reachable

                Item {
                  width: parent.width
                  implicitHeight: Math.max(bigTemp.implicitHeight, ecoRow.implicitHeight)

                  Text {
                    id: bigTemp
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(card.shownTarget)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(34)
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: bigTemp.right
                    anchors.leftMargin: Style.space(3)
                    anchors.baseline: bigTemp.baseline
                    text: "°C"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  // Just a label and a switch: a bordered row up here competed
                  // with the number that the card is really about.
                  Row {
                    id: ecoRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)
                    visible: card.modelData.ecoProperty !== ""

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Eco"
                      color: card.modelData.eco === 1 ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: card.modelData.eco === 1
                      hasCursor: root.isCursor(card.puid, "eco")
                      foreground: root.foreground
                      onHovered: function (on) { if (on) root.setCursor(card.puid, "eco") }
                      onToggled: ac.setEco(card.puid, card.modelData.eco !== 1)
                    }
                  }
                }

                Item {
                  id: tempRow
                  width: parent.width
                  implicitHeight: Math.max(slider.implicitHeight, minus.height)
                  enabled: card.modelData.targetProperty !== ""

                  // The temperature is three controls that act as one stop, so
                  // the cursor paints the row rather than one of the buttons.
                  CursorSurface {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    z: -1
                    hasCursor: root.isCursor(card.puid, "temp")
                    foreground: root.foreground
                  }

                  PanelActionButton {
                    id: minus
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "−"
                    tooltipText: "One degree down"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onHovered: function (on) { if (on) root.setCursor(card.puid, "temp") }
                    onClicked: ac.stepTarget(card.puid, -1)
                  }

                  PanelSlider {
                    id: slider
                    anchors.left: minus.right
                    anchors.right: plus.left
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    bar: root.bar
                    minimum: Model.MIN_TEMP
                    maximum: Model.MAX_TEMP
                    step: 1
                    integer: true
                    value: card.modelData.target === null ? Model.MIN_TEMP : card.modelData.target
                    // A wheel notch fires a release each: the service collects
                    // them and only the last degree reaches the cloud.
                    onReleased: function (value) { ac.setTarget(card.puid, value) }
                  }

                  PanelActionButton {
                    id: plus
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "+"
                    tooltipText: "One degree up"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onHovered: function (on) { if (on) root.setCursor(card.puid, "temp") }
                    onClicked: ac.stepTarget(card.puid, 1)
                  }
                }

                Item {
                  width: parent.width
                  implicitHeight: lowLabel.implicitHeight

                  Text {
                    id: lowLabel
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    text: Model.MIN_TEMP + "°"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    text: Model.MAX_TEMP + "°"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Two by two, so each setting keeps its name next to its value
                // instead of being a row of unlabelled buttons.
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(10)
                  rowSpacing: Style.space(8)

                  readonly property real cellWidth: (width - columnSpacing) / 2

                  CardTile {
                    width: parent.cellWidth
                    visible: card.modelData.modeProperty !== ""
                    puid: card.puid
                    kind: "mode"
                    label: "Mode"
                    options: Model.MODES
                    value: card.modelData.mode === null ? "" : String(card.modelData.mode)
                    onChanged: function (value) { ac.setMode(card.puid, value) }
                  }

                  CardTile {
                    width: parent.cellWidth
                    visible: card.modelData.fanProperty !== ""
                    puid: card.puid
                    kind: "fan"
                    label: "Fan speed"
                    options: Model.FAN_SPEEDS
                    value: card.modelData.fan === null ? "" : String(card.modelData.fan)
                    onChanged: function (value) { ac.setFan(card.puid, value) }
                  }

                  CardTile {
                    width: parent.cellWidth
                    visible: card.modelData.sleepProperty !== ""
                    puid: card.puid
                    kind: "sleep"
                    label: "Sleep"
                    options: Model.SLEEP_MODES
                    value: card.modelData.sleep === null ? "" : String(card.modelData.sleep)
                    onChanged: function (value) { ac.setSleep(card.puid, value) }
                  }

                  CardTile {
                    width: parent.cellWidth
                    visible: card.modelData.swingProperty !== ""
                    puid: card.puid
                    kind: "swing"
                    label: "Airflow"
                    options: Model.SWING_MODES
                    value: card.modelData.swing === null ? "" : String(card.modelData.swing)
                    onChanged: function (value) { ac.setSwing(card.puid, value) }
                  }
                }
              }

              // Only trouble is worth a line of its own: "Connected" under every
              // card said the same thing forever.
              Text {
                textFormat: Text.PlainText
                visible: !card.reachable
                width: parent.width
                text: "Offline — the cloud cannot reach it"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !ac.loading && ac.units.length === 0 && ac.lastError === ""
          width: parent.width
          text: "The account has no air conditioner this widget can drive."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
