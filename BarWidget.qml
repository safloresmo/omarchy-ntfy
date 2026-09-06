import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "i18n.js" as I18n

// ntfy en la barra.
//
// El número son los mensajes sin leer. El color de alerta se reserva para
// mensajes sin leer de prioridad alta o máxima; el resto es informativo. Un
// problema con la conexión o la configuración se marca con un glifo, no solo
// con color, porque el color de alerta de algunos temas contrasta menos que
// el texto normal.
BarWidget {
  id: root
  moduleName: "safloresmo.ntfy"

  // Nerd Font, U+F00E6 (nf-md-bullhorn). Distinto de la campana del centro
  // de notificaciones, que es otro plugin. Carácter literal: QML no resuelve
  // el área privada escrita como \u.
  readonly property string glyph: "󰃦"
  readonly property string warnGlyph: ""

  readonly property string label: {
    if (root.vertical) return glyph
    var s = glyph
    if (service.unreadCount > 0) s += " " + service.unreadCount
    if (service.problem) s += " " + warnGlyph
    return s
  }

  readonly property color labelColor: {
    if (service.alarming) return bar ? bar.urgent : Color.urgent
    return bar ? bar.barForeground : Color.foreground
  }

  readonly property string summary: {
    var head = I18n.t("app") + " · " + service.stateText()
    if (service.supervisorState === "running" && service.servers.length > 0)
      head += " · " + I18n.t("bar_servers_topics", service.servers.length, service.topicCount)
    for (var s = 0; s < service.servers.length; s++) {
      var sv = service.servers[s]
      if (service.isProblemState(sv.state) || sv.badTopics !== "")
        head += "\n" + sv.name + ": " + service.stateName(sv.state).toLowerCase() + (sv.error !== "" ? " · " + sv.error : "")
    }
    if (service.confState === "open") head += "\n" + I18n.t("conf_open")
    if (!service.scanned) return head + "\n" + I18n.t("reading_history")
    if (service.count === 0) return head + "\n" + I18n.t("no_messages")
    var lines = [head, ""]
    var shown = 0
    for (var i = 0; i < service.messages.length && shown < 5; i++, shown++) {
      var m = service.messages[i]
      var t = service.emojiFor(m.tags) + (m.title !== "" ? m.title : m.topic)
      var body = m.message.replace(/\s+/g, " ")
      if (body.length > 80) body = body.substring(0, 80) + "…"
      lines.push((m.time > service.readUntil ? "● " : "  ") + service.fmtTime(m.time) + "  " + t + (body !== "" ? " — " + body : ""))
    }
    if (service.count > shown) lines.push(I18n.t("and_more", service.count - shown))
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
    if ("service" in t) t.service = service
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  Service { id: service; settings: root.settings; bar: root.bar }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    labelVisible: true
    foreground: root.labelColor
    dimmed: !service.configured || service.supervisorState !== "running"
    tooltipText: root.summary

    onPressed: function (b) {
      if (b === Qt.RightButton) service.markRead()
      else if (b === Qt.MiddleButton) service.reconnect()
      else root.toggle()
    }
  }
}
