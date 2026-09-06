import QtQuick
import Quickshell
import Quickshell.Io
import "i18n.js" as I18n

// Estado de ntfy para el widget y el panel.
//
// El trabajo de red lo hace listen.sh: un supervisor que lanza un oyente por
// servidor y deja lo que llega en ficheros: el historial, la marca de leído
// y el estado de cada conexión. Este objeto no habla con ntfy: vigila esos
// ficheros, y lee y escribe el de suscripciones (~/.config/sfm/ntfy.conf)
// para el editor del panel.
//
// La razón es que el shell instancia el widget una vez por monitor. Si cada
// instancia abriera sus conexiones, cada mensaje avisaría tantas veces como
// pantallas. Con un solo supervisor (cerrojo en listen.sh) y todos los
// widgets leyendo los mismos ficheros, el aviso sale una vez y todas las
// barras enseñan lo mismo.
Item {
  id: root

  property var settings: ({})
  property var bar: null

  // ── Ajustes ─────────────────────────────────────────────────────────
  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return n < min ? min : (n > max ? max : n)
  }

  readonly property bool notify: setting("notify", true) !== false
  readonly property int minPriority: intSetting("minPriority", 1, 1, 5)
  readonly property int keep: intSetting("keep", 200, 20, 1000)
  // `server`/`topics` en shell.json (`omarchy bar set …`) siguen valiendo:
  // el supervisor los trata como un servidor más, «ajustes».
  readonly property string legacyServer: String(setting("server", "")).trim()
  readonly property string legacyTopics: String(setting("topics", "")).trim()
  readonly property string configKey: notify + "|" + minPriority + "|" + keep + "|" + legacyServer + "|" + legacyTopics
  onConfigKeyChanged: restart()

  // ── Rutas ───────────────────────────────────────────────────────────
  function env(name, fallback) {
    var v = Quickshell.env(name)
    return v === undefined || v === null || String(v) === "" ? fallback : String(v)
  }
  readonly property string home: env("HOME", "")
  readonly property string stateDir: env("XDG_STATE_HOME", home + "/.local/state") + "/sfm/ntfy"
  readonly property string runDir: env("XDG_RUNTIME_DIR", "/tmp") + "/sfm-ntfy"
  readonly property string confPath: env("XDG_CONFIG_HOME", home + "/.config") + "/sfm/ntfy.conf"
  readonly property string script: String(Qt.resolvedUrl("listen.sh")).replace("file://", "")
  readonly property string emojiPath: String(Qt.resolvedUrl("emoji.tsv")).replace("file://", "")

  // ── Estado ──────────────────────────────────────────────────────────
  property var messages: []          // más reciente primero
  property bool historyLoaded: false // se leyó el historial, o se supo que no existe
  readonly property bool scanned: historyLoaded
  property double readUntil: 0       // mensajes con time <= readUntil están leídos

  // Lo que escribe el supervisor en $XDG_RUNTIME_DIR/sfm-ntfy/status: un
  // registro @meta y uno por servidor. `supervisorState` vacío significa que
  // ningún supervisor ha escrito todavía, que NO es «conectando».
  property string supervisorState: ""   // running | stopped | ""
  property int holderPid: 0
  property string confState: ""         // absent | ok | open | unreadable
  property var servers: []              // [{slug,name,server,topics,auth,badTopics,state,error,since}]
  property double statusUpdated: 0

  // Suscripciones tal como están en ntfy.conf, para el editor. Aquí sí van
  // las credenciales: es el proceso del propio usuario y él las edita.
  property var subscriptions: []        // [{name,server,topics,token,user,pass}]
  property bool confLoaded: false

  property var emoji: ({})
  property var log: []               // últimas líneas del supervisor, para depurar
  property bool listening: false     // este widget tiene un proceso supervisor vivo
  property int failures: 0
  property string lastSaveError: ""

  readonly property int count: messages.length
  readonly property int serverCount: servers.length
  readonly property bool configured: subscriptions.length > 0 || legacyTopics !== ""

  readonly property int topicCount: {
    var n = 0
    for (var i = 0; i < servers.length; i++) if (servers[i].topics !== "") n += servers[i].topics.split(",").length
    return n
  }

  readonly property int unreadCount: {
    var n = 0
    for (var i = 0; i < messages.length; i++) if (messages[i].time > readUntil) n++
    return n
  }
  // Un mensaje sin leer de prioridad alta o máxima es lo único que pone la
  // barra en color de alerta. Lo demás es informativo.
  readonly property bool alarming: {
    for (var i = 0; i < messages.length; i++)
      if (messages[i].time > readUntil && messages[i].priority >= 4) return true
    return false
  }

  function isProblemState(s) {
    return s === "unauthorized" || s === "forbidden" || s === "not_found" || s === "unreachable"
        || s === "rate_limited" || s === "http_error" || s === "reconnecting"
  }
  readonly property int connectedCount: {
    var n = 0
    for (var i = 0; i < servers.length; i++) if (servers[i].state === "connected") n++
    return n
  }
  readonly property int problemCount: {
    var n = 0
    for (var i = 0; i < servers.length; i++) if (isProblemState(servers[i].state) || servers[i].badTopics !== "") n++
    return n
  }
  readonly property bool connected: servers.length > 0 && connectedCount === servers.length
  readonly property bool problem: problemCount > 0 || confState === "open" || confState === "unreadable"

  // ── Utilidades ──────────────────────────────────────────────────────
  function num(v) { var n = parseInt(String(v), 10); return isFinite(n) ? n : 0 }
  function str(v, l) { var s = String(v === undefined || v === null ? "" : v); return s.length > l ? s.substring(0, l) : s }

  function sanitize(t) {
    return String(t || "").replace(/[<>&]/g, function (c) {
      return c === "<" ? "&lt;" : (c === ">" ? "&gt;" : "&amp;")
    })
  }

  function hostOf(url) {
    var m = /^[a-z]+:\/\/([^\/]+)/i.exec(String(url || ""))
    return m ? m[1] : String(url || "")
  }

  // Mismo slug que listen.sh: nombra ficheros y casa el editor con el estado.
  function slugOf(name) {
    var s = String(name || "").replace(/[^A-Za-z0-9_-]/g, "_").substring(0, 32)
    return s
  }
  function serverBySlug(slug) {
    for (var i = 0; i < servers.length; i++) if (servers[i].slug === slug) return servers[i]
    return null
  }

  function emojiFor(tags) {
    var out = ""
    for (var i = 0; i < (tags || []).length; i++) {
      var e = emoji[tags[i]]
      if (e) out += e
    }
    return out
  }
  function plainTags(tags) {
    var out = []
    for (var i = 0; i < (tags || []).length; i++) if (!emoji[tags[i]]) out.push(tags[i])
    return out
  }

  function priorityLabel(p) {
    if (p >= 5) return I18n.t("prio_max")
    if (p === 4) return I18n.t("prio_high")
    if (p === 2) return I18n.t("prio_low")
    if (p <= 1) return I18n.t("prio_min")
    return ""
  }

  function fmtTime(t) {
    if (!t) return ""
    var d = new Date(t * 1000), now = new Date()
    var sameDay = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
    if (sameDay) return Qt.formatTime(d, "HH:mm")
    var y = new Date(now.getTime() - 86400000)
    if (d.getFullYear() === y.getFullYear() && d.getMonth() === y.getMonth() && d.getDate() === y.getDate()) return I18n.t("yesterday", Qt.formatTime(d, "HH:mm"))
    return Qt.formatDateTime(d, "d MMM HH:mm")
  }

  readonly property var knownStates: ["starting", "connecting", "connected", "reconnecting", "unreachable", "unauthorized",
                                       "forbidden", "not_found", "rate_limited", "http_error", "no_topics", "stopped"]
  function stateName(s) { return knownStates.indexOf(s) >= 0 ? I18n.t("st_" + s) : String(s) }
  function tr(key, a, b) { return I18n.t(key, a, b) }

  // Resumen para la cabecera y la barra.
  function stateText() {
    if (supervisorState === "") return listening ? I18n.t("st_starting") : I18n.t("no_listener")
    if (supervisorState === "stopped") return I18n.t("st_stopped")
    if (servers.length === 0) return I18n.t("no_servers")
    if (servers.length === 1) return stateName(servers[0].state)
    if (connected) return I18n.t("st_connected")
    if (problemCount > 0) return I18n.t("n_problems", problemCount, servers.length)
    return I18n.t("n_connected", connectedCount, servers.length)
  }

  // ── Ficheros ────────────────────────────────────────────────────────
  function _parseHistory(text) {
    var lines = String(text || "").split("\n"), out = []
    for (var i = lines.length - 1; i >= 0 && out.length < keep; i--) {
      var s = lines[i].trim()
      if (s === "") continue
      var m
      try { m = JSON.parse(s) } catch (e) { continue }   // línea a medio escribir: la próxima recarga la trae
      if (!m || typeof m.id !== "string") continue
      var tags = []
      if (Array.isArray(m.tags)) for (var j = 0; j < m.tags.length && j < 12; j++) tags.push(str(m.tags[j], 64))
      var att = m.attachment && typeof m.attachment === "object" ? m.attachment : {}
      out.push({
        id: str(m.id, 64),
        time: num(m.time),
        server: str(m.server, 64),
        topic: str(m.topic, 64),
        title: str(m.title, 200),
        message: str(m.message, 4000),
        priority: Math.max(1, Math.min(5, num(m.priority) || 3)),
        tags: tags,
        click: str(m.click, 1000),
        attachmentUrl: str(att.url, 1000),
        attachmentName: str(att.name, 200)
      })
    }
    messages = out
    historyLoaded = true
  }

  function _kv(text) {
    var out = {}, lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq <= 0) continue
      out[lines[i].substring(0, eq)] = lines[i].substring(eq + 1)
    }
    return out
  }

  // Protocolo de la serie sfm.*: `@registro`, `clave=valor`, `.`; se parte
  // por el PRIMER `=` porque los valores pueden llevar más.
  function _records(text) {
    var out = [], cur = null, lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i]
      if (s === "") continue
      if (s.charAt(0) === "@") { cur = { _name: s.substring(1) }; continue }
      if (s === ".") { if (cur) out.push(cur); cur = null; continue }
      if (!cur) continue
      var eq = s.indexOf("=")
      if (eq <= 0) continue
      cur[s.substring(0, eq)] = s.substring(eq + 1)
    }
    return out
  }

  function _parseStatus(text) {
    var recs = _records(text), list = []
    var meta = null
    for (var i = 0; i < recs.length; i++) {
      var r = recs[i]
      if (r._name === "meta") { meta = r; continue }
      list.push({
        slug: str(r._name, 64),
        name: str(r["name"], 64),
        server: str(r["server"], 300),
        topics: str(r["topics"], 1000),
        auth: str(r["auth"], 16),
        badTopics: str(r["bad_topics"], 300),
        state: str(r["state"], 32),
        error: str(r["error"], 200),
        since: num(r["since"])
      })
    }
    servers = list
    supervisorState = meta ? str(meta["state"], 16) : ""
    holderPid = meta ? num(meta["pid"]) : 0
    confState = meta ? str(meta["conf"], 16) : ""
    statusUpdated = meta ? num(meta["updated"]) : 0
    if (supervisorState === "running") failures = 0
  }

  // INI de ntfy.conf → lista de suscripciones. Mismas reglas que listen.sh:
  // claves antes de la primera sección son un servidor sin nombre.
  function _parseConf(text) {
    var out = [], cur = null, lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i].trim()
      if (s === "" || s.charAt(0) === "#" || s.charAt(0) === ";") continue
      var sec = /^\[(.*)\]$/.exec(s)
      if (sec) { cur = { name: sec[1].trim(), server: "", topics: "", token: "", user: "", pass: "" }; out.push(cur); continue }
      var eq = s.indexOf("=")
      if (eq <= 0) continue
      if (!cur) { cur = { name: "", server: "", topics: "", token: "", user: "", pass: "" }; out.push(cur) }
      var k = s.substring(0, eq).replace(/\s+/g, ""), v = s.substring(eq + 1).trim()
      if (k === "servidor" || k === "server") cur.server = v
      else if (k === "temas" || k === "topics") cur.topics = v
      else if (k === "token") cur.token = v
      else if (k === "usuario" || k === "user") cur.user = v
      else if (k === "clave" || k === "password") cur.pass = v
    }
    for (var j = 0; j < out.length; j++) {
      if (out[j].name === "") out[j].name = hostOf(out[j].server !== "" ? out[j].server : "https://ntfy.sh")
    }
    subscriptions = out
    confLoaded = true
  }

  function _parseEmoji(text) {
    var map = {}, lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab <= 0 || lines[i].charAt(0) === "#") continue
      map[lines[i].substring(0, tab)] = lines[i].substring(tab + 1).trim()
    }
    emoji = map
  }

  // `text()` está desfasado dentro de la señal de cambio: los dos caminos
  // pasan por reload → onLoaded, que es como lo hace Commons/Color.qml.
  FileView {
    path: root.stateDir + "/messages.jsonl"
    watchChanges: true
    printErrors: false
    onLoaded: root._parseHistory(text())
    onFileChanged: reload()
    onLoadFailed: { root.messages = []; root.historyLoaded = true }
  }

  FileView {
    path: root.stateDir + "/read"
    watchChanges: true
    printErrors: false
    onLoaded: root.readUntil = root.num(root._kv(text())["until"])
    onFileChanged: reload()
    onLoadFailed: root.readUntil = 0
  }

  FileView {
    path: root.runDir + "/status"
    watchChanges: true
    printErrors: false
    onLoaded: root._parseStatus(text())
    onFileChanged: reload()
    onLoadFailed: root._parseStatus("")
  }

  FileView {
    path: root.confPath
    watchChanges: true
    printErrors: false
    onLoaded: root._parseConf(text())
    onFileChanged: reload()
    onLoadFailed: root._parseConf("")
  }

  FileView {
    path: root.emojiPath
    watchChanges: true
    onFileChanged: reload()
    printErrors: false
    onLoaded: root._parseEmoji(text())
  }

  // ── El supervisor ───────────────────────────────────────────────────
  //
  // Solo arranca cuando el widget está dentro del shell (tiene `bar`). Un
  // banco de pruebas que instancie este servicio a pelo no debe abrir
  // conexiones ni relevar al supervisor de verdad.
  readonly property bool hosted: bar !== null && bar !== undefined
  property bool _restartWanted: false

  function _log(line) {
    var s = String(line || "").trim()
    if (s === "") return
    var next = log.slice(-19)
    next.push(s)
    log = next
  }

  Process {
    id: listener
    command: ["bash", root.script, "listen"]
    environment: ({
      SFM_NTFY_NOTIFY: root.notify ? "1" : "0",
      SFM_NTFY_MIN_PRIORITY: String(root.minPriority),
      SFM_NTFY_KEEP: String(root.keep),
      SFM_NTFY_SERVER: root.legacyServer,
      SFM_NTFY_TOPICS: root.legacyTopics
    })
    running: false
    stdout: SplitParser { onRead: function (l) { root._log(l) } }
    stderr: SplitParser { onRead: function (l) { root._log(l) } }
    onStarted: root.listening = true
    onExited: function (code) {
      root.listening = false
      if (root._restartWanted) {
        root._restartWanted = false
        retry.interval = 300
      } else if (code === 3) {
        // Otro widget (otro monitor) escucha. Se reintenta por si muere.
        retry.interval = 60000
      } else {
        console.warn("safloresmo.ntfy: el supervisor terminó con código " + code)
        retry.interval = Math.min(60000, 2000 * Math.pow(2, Math.min(5, root.failures)))
        root.failures += 1
      }
      retry.restart()
    }
  }

  Timer { id: retry; repeat: false; onTriggered: if (root.hosted) listener.running = true }

  function restart() {
    if (listener.running) { _restartWanted = true; listener.running = false }
    else if (hosted) { retry.interval = 300; retry.restart() }
  }

  // Los ajustes llegan justo después de crear el widget: arrancar en
  // Component.onCompleted lanzaba un supervisor con los ajustes vacíos y lo
  // mataba medio segundo después. Se espera a que asienten.
  function _startSoon() { if (hosted && !listener.running && !retry.running) { retry.interval = 500; retry.restart() } }
  onHostedChanged: _startSoon()
  Component.onCompleted: _startSoon()

  // ── Guardar suscripciones ───────────────────────────────────────────
  //
  // El texto va por stdin a `listen.sh write-conf`, que lo deja en
  // ~/.config/sfm/ntfy.conf con permisos 600 y de forma atómica. El
  // supervisor ve cambiar el fichero y relanza los oyentes.
  function composeConf(list) {
    var out = ["# Suscripciones de safloresmo.ntfy. Lo escribe el editor del panel; se puede editar a mano.", ""]
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      var name = String(s.name || "").trim().replace(/[\[\]\n\r]/g, "")
      var server = String(s.server || "").trim().replace(/[\n\r]/g, "")
      if (server === "") server = "https://ntfy.sh"
      if (server.indexOf("://") < 0) server = "https://" + server
      if (name === "") name = hostOf(server)
      out.push("[" + name + "]")
      out.push("servidor = " + server)
      out.push("temas = " + String(s.topics || "").replace(/[\n\r]/g, "").split(/[\s,]+/).filter(function (t) { return t !== "" }).join(", "))
      if (String(s.token || "").trim() !== "") out.push("token = " + String(s.token).trim().replace(/[\n\r]/g, ""))
      if (String(s.user || "").trim() !== "") {
        out.push("usuario = " + String(s.user).trim().replace(/[\n\r]/g, ""))
        out.push("clave = " + String(s.pass || "").replace(/[\n\r]/g, ""))
      }
      out.push("")
    }
    return out.join("\n")
  }

  function saveSubscriptions(list) {
    if (!hosted) return
    if (writer.running) { lastSaveError = I18n.t("save_busy"); return }
    lastSaveError = ""
    writer.pending = composeConf(list)
    writer.running = true
  }

  Process {
    id: writer
    property string pending: ""
    command: ["bash", root.script, "write-conf"]
    running: false
    stdinEnabled: true
    onStarted: {
      write(pending)
      pending = ""
      // Cerrar stdin es lo que deja terminar al `cat` del otro lado.
      stdinEnabled = false
    }
    onExited: function (code) {
      if (code !== 0) root.lastSaveError = I18n.t("save_exit", code)
    }
  }

  // ── Acciones ────────────────────────────────────────────────────────
  function quote(v) {
    if (bar && typeof bar.shellQuote === "function") return bar.shellQuote(v)
    return "'" + String(v || "").replace(/'/g, "'\\''") + "'"
  }
  function run(c) { if (bar && typeof bar.run === "function") bar.run(c) }
  function tool(mode, arg) {
    run("bash " + quote(script) + " " + mode + (arg !== undefined ? " " + quote(arg) : ""))
  }

  function markRead() { if (unreadCount > 0) tool("read") }
  function clearAll() { tool("clear") }
  function remove(id) { if (id) tool("delete", id) }
  function sendTest() { tool("send", I18n.t("test_message")) }
  function reconnect() { restart() }
  function copy(t) { if (t) run("printf %s " + quote(t) + " | wl-copy") }

  // Solo esquemas que abren en el navegador o el correo: un `click` de ntfy
  // lo escribe quien publica, y llega tal cual.
  function openUrl(u) {
    var s = String(u || "")
    if (/^(https?|mailto):/i.test(s)) run("xdg-open " + quote(s))
  }
}
