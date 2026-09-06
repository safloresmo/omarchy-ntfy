import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "i18n.js" as I18n

// Historial de ntfy, y tras el engranaje, el editor de suscripciones.
//
// Arriba lo que impide recibir —sin servidores, clave rechazada, sin
// conexión—, y después un mensaje por fila, el más reciente primero. Los que
// están sin leer llevan un punto; los de prioridad alta o máxima sin leer van
// en color de alerta y con glifo, porque solo el color no basta en todos los
// temas. El editor sustituye la lista mientras está abierto: una tarjeta por
// servidor con su nombre, URL, temas y credenciales.
Panel {
  id: root
  moduleName: "safloresmo.ntfy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var messages: service ? service.messages : []
  readonly property bool scanned: service ? service.scanned : false
  readonly property bool connected: service ? service.connected : false
  readonly property double readUntil: service ? service.readUntil : 0
  readonly property var servers: service ? service.servers : []
  readonly property bool multiServer: service ? (service.subscriptions.length > 1 || service.servers.length > 1) : false

  readonly property var problemServers: {
    var out = []
    for (var i = 0; i < servers.length; i++)
      if (service.isProblemState(servers[i].state) || servers[i].badTopics !== "") out.push(servers[i])
    return out
  }

  readonly property string statusText: {
    if (!service) return I18n.t("no_service")
    var s = service.stateText()
    if (service.servers.length > 0 && service.supervisorState === "running") {
      var ns = service.servers.length, nt = service.topicCount
      s += " · " + (ns === 1 ? service.hostOf(service.servers[0].server) : I18n.t("servers_n", ns))
      s += " · " + (nt === 1 ? I18n.t("topic_1") : I18n.t("topics_n", nt))
    }
    return s
  }

  readonly property color statusColor: {
    if (!service) return dim
    if (service.problem) return urgent
    if (service.connected) return Color.accent
    return dim
  }

  // ── Navegación por teclado, mismo esquema que el resto de la serie ──
  // Con `inhibitActions` en true, activate() hace todo su camino y se para
  // justo antes de salir del panel hacia el sistema. Cubre las vías de
  // salida de este panel: abrir un enlace, copiar, tocar el historial y
  // escribir el fichero de suscripciones.
  property bool inhibitActions: false

  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int navCount: editing ? 0 : messages.length

  function clampCursor() {
    if (navCount === 0) { cursorIndex = 0; return false }
    if (cursorIndex < 0) cursorIndex = 0
    if (cursorIndex >= navCount) cursorIndex = navCount - 1
    return true
  }

  function moveCursor(dx, dy) {
    if (dx > 0) { activate(); return }
    // Despertar el cursor no depende de que haya lista: con cero mensajes
    // el cursor queda activo sobre nada y el panel sigue reaccionando.
    if (!cursorActive) { cursorActive = true; clampCursor(); return }
    if (!clampCursor()) return
    cursorIndex = Math.max(0, Math.min(navCount - 1, cursorIndex + dy))
  }

  function jumpTo(n) {
    if (n < 1 || n > navCount) return
    cursorActive = true
    cursorIndex = n - 1
  }

  function current() {
    if (!clampCursor()) return null
    return messages[cursorIndex] || null
  }

  // Enter: abrir el enlace si lo hay, si no el adjunto, si no copiar el texto.
  function activate() {
    if (!clampCursor()) return
    if (!cursorActive) { cursorActive = true; return }
    var m = current()
    if (!m || !service) return
    if (inhibitActions) return
    if (m.click !== "") service.openUrl(m.click)
    else if (m.attachmentUrl !== "") service.openUrl(m.attachmentUrl)
    else service.copy(m.message !== "" ? m.message : m.title)
  }

  function copyCurrent() {
    var m = current()
    if (!m || !service || inhibitActions) return
    service.copy(m.message !== "" ? m.message : m.title)
  }

  function deleteCurrent() {
    var m = current()
    if (!m || !service || inhibitActions) return
    service.remove(m.id)
  }

  function guarded(fn) { if (!inhibitActions && service) fn() }

  function ensureVisible(item) {
    if (!item || !panelFlick) return
    var y = item.mapToItem(column, 0, 0).y
    var h = item.height
    if (y < panelFlick.contentY) panelFlick.contentY = y
    else if (y + h > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = y + h - panelFlick.height
  }

  function sanitize(t) { return service ? service.sanitize(t) : String(t || "") }

  // ── Editor de suscripciones ─────────────────────────────────────────
  //
  // `draft` es una copia de service.subscriptions. Los campos escriben en los
  // objetos de la copia; añadir o quitar reemplaza el array (el Repeater
  // recrea las tarjetas, que releen lo escrito). Nada sale del panel hasta
  // Guardar.
  property bool editing: false
  property var draft: []

  function blankSubscription() { return { name: "", server: "https://ntfy.sh", topics: "", token: "", user: "", pass: "" } }

  function startEditing() {
    var src = service ? service.subscriptions : [], copy = []
    for (var i = 0; i < src.length; i++)
      copy.push({ name: src[i].name, server: src[i].server, topics: src[i].topics, token: src[i].token, user: src[i].user, pass: src[i].pass })
    if (copy.length === 0) copy.push(blankSubscription())
    draft = copy
    cursorActive = false
    editing = true
  }

  function cancelEditing() {
    editing = false
    draft = []
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveEditing() {
    if (!service) return
    // Una tarjeta vacía del todo no es un servidor: se descarta sin ruido.
    var keep = []
    for (var i = 0; i < draft.length; i++) {
      var d = draft[i]
      if (String(d.name || "").trim() === "" && String(d.topics || "").trim() === "" && String(d.token || "") === "" && String(d.user || "") === "") continue
      keep.push(d)
    }
    if (!inhibitActions) service.saveSubscriptions(keep)
    cancelEditing()
  }

  // El `modelData` del delegado es una COPIA del elemento (el array pasa por
  // QVariantList al entrar en el Repeater): escribir ahí no cambia `draft`.
  // Se escribe por índice sobre el array de verdad.
  function setDraft(i, key, value) { if (i >= 0 && i < draft.length) draft[i][key] = value }

  function addSubscription() { draft = draft.concat([blankSubscription()]) }
  function removeSubscription(i) { draft = draft.filter(function (_, j) { return j !== i }) }

  // Teclas dentro de un campo: Escape cancela, Tab y Enter saltan al
  // siguiente. Lo demás es texto.
  function fieldKey(event, field) {
    if (event.key === Qt.Key_Escape) { cancelEditing(); event.accepted = true; return }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
      saveEditing(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      var back = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)
      var n = field.nextItemInFocusChain(!back)
      if (n) n.forceActiveFocus()
      event.accepted = true
    }
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
    } else {
      if (editing) cancelEditing()
      // Al cerrar, lo visto queda leído: es lo que hace cualquier bandeja.
      guarded(function () { service.markRead() })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Mientras se edita, las teclas son texto y van a los campos.
      blocked: root.editing
      // Solo activateRequested: Enter emite además returnRequested y se
      // actuaría dos veces por pulsación.
      onMoveRequested: function (dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onDeleteRequested: root.deleteCurrent()
      onTextKey: function (t) {
        if (t === "q" || t === "Q") { root.close(); return }
        if (t === "e" || t === "E") { root.startEditing(); return }
        if (t === "r" || t === "R") { root.guarded(function () { root.service.reconnect() }); return }
        if (t === "a" || t === "A") { root.guarded(function () { root.service.markRead() }); return }
        if (t === "c" || t === "C") { root.copyCurrent(); return }
        if (t === "t" || t === "T") { if (root.service && root.service.subscriptions.length > 0) root.guarded(function () { root.service.sendTest() }); return }
        if (t >= "1" && t <= "9") root.jumpTo(parseInt(t, 10))
      }
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

        // ── Cabecera ──────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, headerActions.implicitHeight)

          Text {
            id: heroIcon
            text: "󰃦"
            color: root.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          RowLayout {
            id: headerActions
            spacing: Style.space(4)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            PanelActionButton {
              iconText: ""
              visible: !root.editing && (root.service ? root.service.unreadCount > 0 : false)
              tooltipText: I18n.t("tip_mark_read")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.guarded(function () { root.service.markRead() })
            }
            PanelActionButton {
              iconText: ""
              visible: !root.editing
              tooltipText: I18n.t("tip_reconnect")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.guarded(function () { root.service.reconnect() })
            }
            PanelActionButton {
              iconText: root.editing ? "" : ""
              tooltipText: root.editing ? I18n.t("tip_close_editor") : I18n.t("tip_open_editor")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.editing ? root.cancelEditing() : root.startEditing()
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.editing ? I18n.t("editor_title")
                    : I18n.t("app") + (root.service && root.service.unreadCount > 0 ? "  ·  " + I18n.t("unread_n", root.service.unreadCount) : "")
              color: root.foreground
              font.family: root.fontFamily; font.pixelSize: Style.font.title
              font.bold: true; elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: (root.editing ? I18n.t("editor_saved_in") : root.statusText).toUpperCase()
              color: root.editing ? root.dim : root.statusColor
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
              font.bold: true; font.letterSpacing: 1.2
              textFormat: Text.PlainText; elide: Text.ElideRight
            }
          }
        }

        // ── Editor ────────────────────────────────────────────────────
        Column {
          width: parent.width
          visible: root.editing
          spacing: Style.space(10)

          Repeater {
            model: root.draft

            Rectangle {
              id: card
              required property var modelData
              required property int index
              readonly property var live: root.service ? root.service.serverBySlug(root.service.slugOf(modelData.name !== "" ? modelData.name : root.service.hostOf(modelData.server))) : null

              width: column.width
              implicitHeight: cardContent.implicitHeight + Style.space(20)
              color: "transparent"
              radius: Style.cornerRadius
              border.width: 1
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

              Column {
                id: cardContent
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: parent.top; anchors.topMargin: Style.space(10)
                anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(12)
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(cardTitle.implicitHeight, cardRemove.implicitHeight)
                  Text {
                    id: cardTitle
                    anchors.left: parent.left; anchors.right: cardRemove.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.t("server_n", card.index + 1)
                          + (card.live ? "  ·  " + root.service.stateName(card.live.state).toLowerCase()
                                        + (card.live.error !== "" ? " (" + card.live.error + ")" : "")
                                       : "")
                    color: card.live && root.service.isProblemState(card.live.state) ? root.urgent : root.dim
                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    font.bold: true; font.letterSpacing: 1
                    textFormat: Text.PlainText; elide: Text.ElideRight
                  }
                  PanelActionButton {
                    id: cardRemove
                    iconText: ""
                    tooltipText: I18n.t("tip_remove_server")
                    foreground: root.foreground; fontFamily: root.fontFamily
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.removeSubscription(card.index)
                  }
                }

                Field { label: I18n.t("f_name");   placeholder: I18n.t("ph_name");        value: card.modelData.name;   autoFocus: card.index === 0; onEdited: function (t) { root.setDraft(card.index, "name", t) } }
                Field { label: I18n.t("f_server"); placeholder: "https://ntfy.sh";               value: card.modelData.server; onEdited: function (t) { root.setDraft(card.index, "server", t) } }
                Field { label: I18n.t("f_topics"); placeholder: I18n.t("ph_topics");    value: card.modelData.topics; onEdited: function (t) { root.setDraft(card.index, "topics", t) } }
                Field { label: I18n.t("f_token");  placeholder: I18n.t("ph_token"); value: card.modelData.token;  secret: true; onEdited: function (t) { root.setDraft(card.index, "token", t) } }
                Field { label: I18n.t("f_user");   placeholder: I18n.t("ph_user");             value: card.modelData.user;   onEdited: function (t) { root.setDraft(card.index, "user", t) } }
                Field { label: I18n.t("f_pass");   placeholder: "";                              value: card.modelData.pass;   secret: true; onEdited: function (t) { root.setDraft(card.index, "pass", t) } }
              }
            }
          }

          Text {
            width: parent.width
            text: I18n.t("editor_help")
            color: root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
            textFormat: Text.PlainText; wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.service ? root.service.lastSaveError !== "" : false
            text: "  " + I18n.t("save_failed", root.service ? root.service.lastSaveError : "")
            color: root.urgent
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
            font.bold: true
            textFormat: Text.PlainText; wrapMode: Text.WordWrap
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: I18n.t("add_server")
              iconText: ""
              bordered: true
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.addSubscription()
            }
            Item { Layout.fillWidth: true }
            Button {
              text: I18n.t("cancel")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.cancelEditing()
            }
            Button {
              text: I18n.t("save")
              iconText: ""
              bordered: true
              selected: true
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.saveEditing()
            }
          }
        }

        // ── Avisos ────────────────────────────────────────────────────
        Item {
          width: parent.width
          visible: !root.editing && root.service && root.service.confLoaded && !root.service.configured
          implicitHeight: noServersText.implicitHeight + noServersButton.implicitHeight + Style.space(20)

          Text {
            id: noServersText
            anchors.top: parent.top
            width: parent.width
            text: I18n.t("empty_intro")
            color: root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText; wrapMode: Text.WordWrap
          }
          Button {
            id: noServersButton
            anchors.top: noServersText.bottom; anchors.topMargin: Style.space(12)
            anchors.horizontalCenter: parent.horizontalCenter
            text: I18n.t("add_a_server")
            iconText: ""
            bordered: true
            foreground: root.foreground; fontFamily: root.fontFamily
            onClicked: root.startEditing()
          }
        }

        Repeater {
          model: root.editing ? [] : root.problemServers

          Hint {
            required property var modelData
            width: column.width
            title: modelData.name + ": " + (modelData.badTopics !== "" && !root.service.isProblemState(modelData.state)
                                            ? I18n.t("bad_topics_title") : root.service.stateName(modelData.state).toLowerCase())
            body: {
              var s = modelData.state, h = root.service.hostOf(modelData.server)
              if (s === "unauthorized") return I18n.t(modelData.auth !== "none" ? "hint_unauthorized_creds" : "hint_unauthorized_none") + I18n.t("hint_unauthorized_tail")
              if (s === "forbidden") return I18n.t("hint_forbidden")
              if (s === "unreachable" || s === "reconnecting") return I18n.t("hint_unreachable", h, modelData.error !== "" ? ": " + modelData.error + "." : ".")
              if (s === "not_found") return I18n.t("hint_not_found")
              if (s === "rate_limited") return I18n.t("hint_rate_limited")
              if (s === "http_error") return I18n.t("hint_http_error", modelData.error !== "" ? modelData.error + ". " : "")
              if (modelData.badTopics !== "") return I18n.t("hint_bad_topics", modelData.badTopics)
              return ""
            }
            commands: modelData.state === "not_found" ? ["curl -s " + root.service.hostOf(modelData.server) + "/v1/health"] : []
            tone: root.urgent
            textColor: root.foreground; dimColor: root.dim
            fontName: root.fontFamily; svc: root.service
          }
        }

        Hint {
          width: column.width
          visible: !root.editing && root.service ? root.service.confState === "open" : false
          title: I18n.t("conf_open_title")
          body: I18n.t("conf_open_body")
          commands: ["chmod 600 ~/.config/sfm/ntfy.conf"]
          tone: root.urgent
          textColor: root.foreground; dimColor: root.dim
          fontName: root.fontFamily; svc: root.service
        }

        Hint {
          width: column.width
          visible: !root.editing && root.service ? (root.service.supervisorState === "" && root.service.failures >= 2) : false
          title: I18n.t("listener_dead_title")
          body: I18n.t("listener_dead_body")
                + (root.service && root.service.log.length > 0 ? root.service.log[root.service.log.length - 1] : I18n.t("nothing_said"))
          commands: ["bash ~/.config/omarchy/plugins/safloresmo.ntfy/listen.sh check"]
          tone: root.urgent
          textColor: root.foreground; dimColor: root.dim
          fontName: root.fontFamily; svc: root.service
        }

        // ── Sin mensajes ──────────────────────────────────────────────
        Item {
          width: parent.width
          visible: !root.editing && root.scanned && root.messages.length === 0 && root.service && root.service.configured && !root.service.problem
          implicitHeight: emptyText.implicitHeight + (testHint.visible ? testHint.implicitHeight + Style.space(8) : 0)

          Text {
            id: emptyText
            width: parent.width
            text: root.connected ? I18n.t("empty_connected") : I18n.t("empty_saved")
            color: root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText; wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            id: testHint
            visible: root.connected
            anchors.top: emptyText.bottom; anchors.topMargin: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter
            text: I18n.t("press_t")
            color: root.dim; opacity: 0.8
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
        }

        // ── Mensajes ──────────────────────────────────────────────────
        Repeater {
          model: root.editing ? [] : root.messages

          CursorSurface {
            id: row
            required property var modelData
            required property int index

            hasCursor: root.cursorActive && index === root.cursorIndex
            onHasCursorChanged: if (hasCursor) Qt.callLater(function () { root.ensureVisible(row) })

            width: column.width
            implicitHeight: rowContent.implicitHeight + Style.space(16)
            foreground: root.foreground

            readonly property bool unread: modelData.time > root.readUntil
            readonly property bool loud: modelData.priority >= 4
            readonly property string emojis: root.service ? root.service.emojiFor(modelData.tags) : ""
            readonly property var otherTags: root.service ? root.service.plainTags(modelData.tags) : []
            readonly property string link: modelData.click !== "" ? modelData.click : modelData.attachmentUrl

            Column {
              id: rowContent
              anchors.left: parent.left; anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(12)
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: Math.max(titleText.implicitHeight, timeText.implicitHeight)

                Rectangle {
                  id: unreadDot
                  visible: row.unread
                  width: Style.space(7); height: width; radius: width / 2
                  color: row.loud ? root.urgent : Color.accent
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: titleText
                  anchors.left: row.unread ? unreadDot.right : parent.left
                  anchors.leftMargin: row.unread ? Style.space(8) : 0
                  anchors.right: timeText.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: (row.loud && row.unread ? " " : "")
                        + (row.emojis !== "" ? row.emojis + " " : "")
                        + root.sanitize(row.modelData.title !== "" ? row.modelData.title : row.modelData.topic)
                  color: row.loud && row.unread ? root.urgent : root.foreground
                  font.family: root.fontFamily; font.pixelSize: Style.font.body
                  font.bold: row.unread
                  textFormat: Text.PlainText; elide: Text.ElideRight
                }

                Text {
                  id: timeText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.service ? root.service.fmtTime(row.modelData.time) : ""
                  color: root.dim
                  font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }

              Text {
                width: parent.width
                visible: row.modelData.message !== ""
                text: row.modelData.message
                color: root.foreground
                opacity: row.unread ? 1.0 : 0.85
                font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                maximumLineCount: 6; elide: Text.ElideRight
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(metaText.implicitHeight, actions.implicitHeight)

                Text {
                  id: metaText
                  anchors.left: parent.left; anchors.right: actions.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var p = []
                    if (root.multiServer && row.modelData.server !== "") p.push(row.modelData.server)
                    p.push(row.modelData.topic)
                    var pl = root.service ? root.service.priorityLabel(row.modelData.priority) : ""
                    if (pl !== "") p.push(pl)
                    if (row.otherTags.length > 0) p.push(row.otherTags.join(", "))
                    // El enlace y el adjunto ya los anuncia el botón de abrir;
                    // aquí solo el nombre del adjunto, que es lo que informa.
                    if (row.modelData.attachmentName !== "") p.push(I18n.t("attachment", row.modelData.attachmentName))
                    return p.join("  ·  ")
                  }
                  color: row.loud && row.unread ? root.urgent : root.dim
                  font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText; elide: Text.ElideRight
                }

                RowLayout {
                  id: actions
                  spacing: Style.space(4)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter

                  PanelActionButton {
                    iconText: ""
                    visible: row.link !== ""
                    tooltipText: row.modelData.click !== "" ? I18n.t("tip_open_link") : I18n.t("tip_open_attachment")
                    foreground: root.foreground; fontFamily: root.fontFamily
                    onClicked: root.guarded(function () { root.service.openUrl(row.link) })
                  }
                  PanelActionButton {
                    iconText: ""
                    tooltipText: I18n.t("tip_copy")
                    foreground: root.foreground; fontFamily: root.fontFamily
                    onClicked: root.guarded(function () { root.service.copy(row.modelData.message !== "" ? row.modelData.message : row.modelData.title) })
                  }
                  PanelActionButton {
                    iconText: ""
                    tooltipText: I18n.t("tip_remove")
                    foreground: root.foreground; fontFamily: root.fontFamily
                    onClicked: root.guarded(function () { root.service.remove(row.modelData.id) })
                  }
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: !root.editing && root.navCount > 0
          text: I18n.t("footer")
          color: root.dim
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          // Se parte en dos líneas antes que cortarse: una línea de atajos
          // con puntos suspensivos es la que nadie lee.
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // Un campo del editor: etiqueta a la izquierda, entrada a la derecha.
  component Field: Item {
    id: field
    property string label: ""
    property string placeholder: ""
    property string value: ""
    property bool secret: false
    property bool autoFocus: false
    signal edited(string text)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(fieldLabel.implicitHeight, fieldInput.implicitHeight)

    Text {
      id: fieldLabel
      width: Style.space(64)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: field.label
      color: root.dim
      font.family: root.fontFamily; font.pixelSize: Style.font.caption
      textFormat: Text.PlainText; elide: Text.ElideRight
    }

    TextField {
      id: fieldInput
      anchors.left: fieldLabel.right; anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: field.value
      placeholderText: field.placeholder
      password: field.secret
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.spaceReal(3)
      onTextEdited: field.edited(text)
      Keys.onPressed: function (event) { root.fieldKey(event, fieldInput) }
      Component.onCompleted: if (field.autoFocus) Qt.callLater(function () { fieldInput.forceActiveFocus() })
    }
  }

  component Hint: CursorSurface {
    id: hint
    property string title: ""
    property string body: ""
    property var commands: []
    property color tone: "white"
    property color textColor: "white"
    property color dimColor: "gray"
    property string fontName: "monospace"
    property var svc: null

    width: 0
    implicitHeight: hintContent.implicitHeight + Style.space(16)
    foreground: textColor

    Column {
      id: hintContent
      anchors.left: parent.left; anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(12)
      spacing: Style.space(4)

      Text {
        width: parent.width; text: "  " + hint.title; color: hint.tone
        font.family: hint.fontName; font.pixelSize: Style.font.bodySmall; font.bold: true
        textFormat: Text.PlainText; wrapMode: Text.WordWrap
      }
      Text {
        width: parent.width; text: hint.body; color: hint.dimColor
        visible: hint.body !== ""
        font.family: hint.fontName; font.pixelSize: Style.font.caption
        textFormat: Text.PlainText; wrapMode: Text.WordWrap
      }

      Repeater {
        model: hint.commands

        Item {
          required property var modelData
          required property int index
          width: hintContent.width
          implicitHeight: Math.max(cmdText.implicitHeight, cmdCopy.implicitHeight)

          Text {
            id: cmdText
            anchors.left: parent.left
            anchors.right: cmdCopy.left; anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData; color: hint.textColor
            font.family: hint.fontName; font.pixelSize: Style.font.caption
            textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere
          }
          PanelActionButton {
            id: cmdCopy
            iconText: ""
            tooltipText: I18n.t("tip_copy_command")
            foreground: hint.textColor; fontFamily: hint.fontName
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            onClicked: if (hint.svc && !root.inhibitActions) hint.svc.copy(modelData)
          }
        }
      }
    }
  }
}
