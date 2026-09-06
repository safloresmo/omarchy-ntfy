#!/bin/bash
#
# Puente con ntfy para el widget safloresmo.ntfy.
#
# Modos:
#   listen          supervisor: lee las suscripciones y lanza un oyente por
#                   servidor. Una sola instancia por sesión: el shell crea el
#                   widget una vez por monitor y cada uno lanza esto; los que
#                   no consiguen el cerrojo salen con 3 y el widget reintenta
#                   más tarde por si el que escucha muere.
#   worker          (interno) oyente de UN servidor; lo lanza el supervisor
#   read            marca todo como leído
#   clear           vacía el historial
#   delete <id>     quita un mensaje del historial
#   send [texto]    publica un mensaje de prueba en el primer tema del primer
#                   servidor
#   write-conf      escribe ~/.config/sfm/ntfy.conf con lo que llegue por
#                   stdin (600, atómico). Lo usa el editor del panel.
#   check           enseña la configuración resuelta, para depurar
#
# Suscripciones: ~/.config/sfm/ntfy.conf (600), una sección por servidor:
#
#   [casa]
#   servidor = https://ntfy.midominio.es
#   temas = taller, alarma
#   token = tk_…            # o usuario = / clave =
#
# Claves sueltas antes de la primera sección valen como un servidor más
# (formato antiguo). Y si por entorno llegan SFM_NTFY_SERVER/SFM_NTFY_TOPICS
# (los ajustes `server`/`topics` de shell.json), son otro servidor, «ajustes».
#
# Ficheros:
#   $XDG_STATE_HOME/sfm/ntfy/messages.jsonl  historial, un mensaje por línea,
#                                            solo los campos que se enseñan
#   $XDG_STATE_HOME/sfm/ntfy/read            until=<época>: lo anterior está leído
#   $XDG_STATE_HOME/sfm/ntfy/since-<slug>    época del último mensaje guardado
#   $XDG_RUNTIME_DIR/sfm-ntfy/status         estado, un registro por servidor
#   $XDG_RUNTIME_DIR/sfm-ntfy/status.d/      lo que escribe cada oyente
#   $XDG_RUNTIME_DIR/sfm-ntfy/lock           cerrojo del supervisor
#
# Ajustes por entorno desde Service.qml:
#   SFM_NTFY_NOTIFY (0/1)  SFM_NTFY_MIN_PRIORITY (1-5)  SFM_NTFY_KEEP
#
# Solo lectura: nunca ejecuta las «actions» que traen los mensajes, ni las
# guarda. Lo único que publica es el mensaje de prueba del modo `send`.

set -o pipefail
umask 077

STATE="${SFM_NTFY_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/sfm/ntfy}"
RUN="${SFM_NTFY_RUN:-${XDG_RUNTIME_DIR:-/tmp/sfm-$UID}/sfm-ntfy}"
CONF="${SFM_NTFY_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/sfm/ntfy.conf}"
MSGS="$STATE/messages.jsonl"
MSGLOCK="$STATE/messages.lock"
READFILE="$STATE/read"
STATUS="$RUN/status"
STATUSD="$RUN/status.d"
LOCK="$RUN/lock"
SELF="$(readlink -f "$0")"
EMOJI="$(dirname "$SELF")/emoji.tsv"

mkdir -p "$STATE" "$RUN" "$STATUSD" || exit 2

notify="${SFM_NTFY_NOTIFY:-1}"
minprio="${SFM_NTFY_MIN_PRIORITY:-1}"
keep="${SFM_NTFY_KEEP:-200}"
[[ $notify == 0 ]] || notify=1
[[ $minprio =~ ^[1-5]$ ]] || minprio=1
[[ $keep =~ ^[0-9]+$ ]] || keep=200
(( keep < 20 )) && keep=20
(( keep > 1000 )) && keep=1000

# La clave identifica «esta configuración con este script»: un supervisor
# huérfano de un shell anterior con otros ajustes, o con un script más viejo,
# se releva. Las suscripciones no entran: el supervisor las recarga solo.
KEY=$(printf '%s' "$notify|$minprio|$keep|$(stat -c %Y "$SELF" 2>/dev/null)" | md5sum | cut -c1-16)

# ── Suscripciones ─────────────────────────────────────────────────────
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

declare -a S_NAME S_SERVER S_TOPICS S_TOKEN S_USER S_PASS S_SLUG S_BAD
conf_state="absent"      # absent | ok | open (legible por otros) | unreadable
conf_mtime=""

_sec_new() {   # _sec_new <nombre>
  S_NAME+=("$1"); S_SERVER+=(""); S_TOPICS+=(""); S_TOKEN+=(""); S_USER+=(""); S_PASS+=(""); S_SLUG+=(""); S_BAD+=("")
}

parse_conf() {
  S_NAME=(); S_SERVER=(); S_TOPICS=(); S_TOKEN=(); S_USER=(); S_PASS=(); S_SLUG=(); S_BAD=()
  conf_state="absent"; conf_mtime=""
  local cur=-1 line k v
  if [[ -e $CONF ]]; then
    if [[ ! -r $CONF ]]; then conf_state="unreadable"
    else
      conf_mtime=$(stat -c %Y "$CONF" 2>/dev/null)
      local mode; mode=$(stat -c %a "$CONF" 2>/dev/null)
      conf_state="ok"; [[ ${mode: -2} != 00 ]] && conf_state="open"
      while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*[#\;] ]] && continue
        line=$(trim "$line")
        [[ -z $line ]] && continue
        if [[ $line =~ ^\[(.*)\]$ ]]; then
          _sec_new "$(trim "${BASH_REMATCH[1]}")"; cur=$(( ${#S_NAME[@]} - 1 )); continue
        fi
        [[ $line == *=* ]] || continue
        if (( cur < 0 )); then _sec_new ""; cur=0; fi
        k="${line%%=*}"; k="${k//[[:space:]]/}"
        v=$(trim "${line#*=}")
        case $k in
          servidor|server) S_SERVER[cur]=$v ;;
          temas|topics)    S_TOPICS[cur]=$v ;;
          token)           S_TOKEN[cur]=$v ;;
          usuario|user)    S_USER[cur]=$v ;;
          clave|password)  S_PASS[cur]=$v ;;
        esac
      done <"$CONF"
    fi
  fi
  # Los ajustes de shell.json (`omarchy bar set safloresmo.ntfy topics …`) siguen
  # valiendo: son un servidor más.
  if [[ -n ${SFM_NTFY_TOPICS:-} ]]; then
    _sec_new "ajustes"; cur=$(( ${#S_NAME[@]} - 1 ))
    S_SERVER[cur]="${SFM_NTFY_SERVER:-}"; S_TOPICS[cur]="$SFM_NTFY_TOPICS"
  fi

  local i t clean bad host slug n
  declare -A used=()
  for (( i = 0; i < ${#S_NAME[@]}; i++ )); do
    [[ -z ${S_SERVER[i]} ]] && S_SERVER[i]="https://ntfy.sh"
    S_SERVER[i]="${S_SERVER[i]%/}"
    [[ ${S_SERVER[i]} != *://* ]] && S_SERVER[i]="https://${S_SERVER[i]}"
    host="${S_SERVER[i]#*://}"; host="${host%%/*}"
    [[ -z ${S_NAME[i]} ]] && S_NAME[i]="$host"
    # Temas: coma o espacio como separador; solo lo que ntfy admite.
    clean=""; bad=""
    for t in ${S_TOPICS[i]//,/ }; do
      if [[ $t =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then clean="${clean:+$clean,}$t"
      else bad="${bad:+$bad }$t"; fi
    done
    S_TOPICS[i]=$clean; S_BAD[i]=$bad
    # El slug nombra ficheros: solo caracteres seguros, y único.
    slug="${S_NAME[i]//[^A-Za-z0-9_-]/_}"; slug="${slug:0:32}"; [[ -z $slug ]] && slug="s$i"
    n=$slug; while [[ -n ${used[$n]} ]]; do n="$slug-$i"; done
    used[$n]=1; S_SLUG[i]=$n
  done
}

# Escribe la configuración de curl de un servidor en un fichero 600: nada de
# credenciales en la línea de mandatos, que cualquiera lee en `ps`.
write_curlrc() {   # write_curlrc <fichero> <token> <usuario> <clave>
  local f=$1 token=$2 user=$3 pass=$4
  local esc_t="${token//\\/\\\\}"; esc_t="${esc_t//\"/\\\"}"
  local esc_u="${user//\\/\\\\}";  esc_u="${esc_u//\"/\\\"}"
  local esc_p="${pass//\\/\\\\}";  esc_p="${esc_p//\"/\\\"}"
  {
    echo "silent"
    echo "show-error"
    echo "location"
    echo "max-redirs = 3"
    echo 'header = "Accept: application/json"'
    if [[ -n $token ]]; then printf 'header = "Authorization: Bearer %s"\n' "$esc_t"
    elif [[ -n $user ]]; then printf 'user = "%s:%s"\n' "$esc_u" "$esc_p"; fi
  } >"$f"
  chmod 600 "$f"
}

auth_kind() { if [[ -n $1 ]]; then echo token; elif [[ -n $2 ]]; then echo basic; else echo none; fi; }

status_meta() { [[ -r $STATUS ]] && sed -n "/^@meta\$/,/^\.\$/s/^$1=//p" "$STATUS" | head -n 1; }

# ── Emojis de las etiquetas ───────────────────────────────────────────
declare -A EMOJIS
load_emoji() {
  [[ -r $EMOJI ]] || return 0
  local k v
  while IFS=$'\t' read -r k v; do [[ -n $k && $k != \#* ]] && EMOJIS[$k]=$v; done <"$EMOJI"
}

# ── Supervisor ────────────────────────────────────────────────────────
PARENT="${SFM_NTFY_PARENT:-$PPID}"
parent_alive() { [[ $PARENT == 0 ]] || kill -0 "$PARENT" 2>/dev/null; }

declare -A WPID
need_agg=0
holder=0

aggregate() {
  local tmp="$STATUS.tmp.$$" i f
  {
    echo "@meta"
    echo "pid=$$"
    echo "key=$KEY"
    echo "conf=$conf_state"
    echo "servers=${#S_NAME[@]}"
    echo "state=${1:-running}"
    echo "updated=$(date +%s)"
    echo "."
    for (( i = 0; i < ${#S_NAME[@]}; i++ )); do
      f="$STATUSD/${S_SLUG[i]}"
      if [[ -s $f ]]; then cat "$f"
      else
        echo "@${S_SLUG[i]}"; echo "name=${S_NAME[i]}"; echo "server=${S_SERVER[i]}"
        echo "topics=${S_TOPICS[i]}"; echo "state=starting"; echo "."
      fi
    done
  } >"$tmp" && mv -f "$tmp" "$STATUS"
  need_agg=0
}

spawn_worker() {   # spawn_worker <índice>
  local i=$1
  SFM_NTFY_W_NAME="${S_NAME[i]}" SFM_NTFY_W_SERVER="${S_SERVER[i]}" SFM_NTFY_W_TOPICS="${S_TOPICS[i]}" \
  SFM_NTFY_W_TOKEN="${S_TOKEN[i]}" SFM_NTFY_W_USER="${S_USER[i]}" SFM_NTFY_W_PASS="${S_PASS[i]}" \
  SFM_NTFY_W_SLUG="${S_SLUG[i]}" SFM_NTFY_W_BAD="${S_BAD[i]}" \
    bash "$SELF" worker 9>&- &
  WPID[${S_SLUG[i]}]=$!
}

kill_workers() {
  local p
  for p in "${WPID[@]}"; do kill -TERM "$p" 2>/dev/null; done
  for p in "${WPID[@]}"; do wait "$p" 2>/dev/null; done
  WPID=()
}

spawn_all() {
  kill_workers
  rm -f "$STATUSD"/*
  parse_conf
  local i
  for (( i = 0; i < ${#S_NAME[@]}; i++ )); do spawn_worker "$i"; done
  aggregate
}

cleanup() {
  kill_workers
  if (( holder )); then aggregate stopped; fi
}

listen() {
  # El descriptor del cerrojo no debe llegar a ningún hijo: un `sleep` o un
  # oyente huérfanos lo retendrían y el relevo esperaría a que murieran.
  exec 9>>"$LOCK"
  if ! flock -n 9; then
    # Otro widget (otro monitor, o un shell anterior que no llegó a matarlo)
    # ya escucha. Si lo hace con otros ajustes u otro script, se le releva.
    local okey opid
    okey=$(status_meta key); opid=$(status_meta pid)
    if [[ -n $opid && $okey != "$KEY" ]] && kill -0 "$opid" 2>/dev/null; then
      kill -TERM "$opid" 2>/dev/null
      flock -w 5 9 || exit 3
    else
      exit 3
    fi
  fi
  holder=1
  trap cleanup EXIT
  trap 'exit 143' TERM INT HUP
  trap 'need_agg=1' USR1

  spawn_all
  local slug i ticks=0 mt
  while :; do
    sleep 2 9>&- & wait $!; kill $! 2>/dev/null
    parent_alive || exit 0
    (( ticks++ ))
    # Cambió el fichero de suscripciones (el editor del panel, o a mano):
    # todo de nuevo con lo nuevo.
    mt=""; [[ -e $CONF ]] && mt=$(stat -c %Y "$CONF" 2>/dev/null)
    if [[ $mt != "$conf_mtime" ]]; then spawn_all; continue; fi
    # Un oyente muerto se relanza, con calma: cada 10 s como mucho.
    if (( ticks % 5 == 0 )); then
      for (( i = 0; i < ${#S_NAME[@]}; i++ )); do
        slug=${S_SLUG[i]}
        kill -0 "${WPID[$slug]}" 2>/dev/null || spawn_worker "$i"
      done
    fi
    (( need_agg )) && aggregate
  done
}

# ── Oyente de un servidor ─────────────────────────────────────────────
W_NAME="${SFM_NTFY_W_NAME:-}"; W_SERVER="${SFM_NTFY_W_SERVER:-}"; W_TOPICS="${SFM_NTFY_W_TOPICS:-}"
W_TOKEN="${SFM_NTFY_W_TOKEN:-}"; W_USER="${SFM_NTFY_W_USER:-}"; W_PASS="${SFM_NTFY_W_PASS:-}"
W_SLUG="${SFM_NTFY_W_SLUG:-}"; W_BAD="${SFM_NTFY_W_BAD:-}"

wstatus() {   # wstatus state=… [error=…] [since=…]
  local f="$STATUSD/$W_SLUG" tmp="$STATUSD/.$W_SLUG.$$"
  {
    echo "@$W_SLUG"
    echo "name=$W_NAME"
    echo "server=$W_SERVER"
    echo "topics=$W_TOPICS"
    echo "auth=$(auth_kind "$W_TOKEN" "$W_USER")"
    [[ -n $W_BAD ]] && echo "bad_topics=$W_BAD"
    printf '%s\n' "$@"
    echo "updated=$(date +%s)"
    echo "."
  } >"$tmp" && mv -f "$tmp" "$f"
  kill -USR1 "$PPID" 2>/dev/null
}

declare -A SEEN
load_history() {
  [[ -s $MSGS ]] || return 0
  local k
  while IFS= read -r k; do [[ -n $k ]] && SEEN[$k]=1; done < <(jq -r '((.server // "") + "/" + (.id // ""))' "$MSGS" 2>/dev/null)
}

# Varios oyentes escriben el mismo historial: añadir y recortar van bajo
# cerrojo, que si no un recorte pisa lo que otro acaba de añadir.
store() {
  local rec=$1 n
  {
    flock 8
    printf '%s\n' "$rec" >>"$MSGS"
    n=$(wc -l <"$MSGS")
    if (( n > keep + 50 )); then
      tail -n "$keep" "$MSGS" >"$MSGS.tmp.$$" && mv -f "$MSGS.tmp.$$" "$MSGS"
    fi
  } 8>>"$MSGLOCK"
}

notify_msg() {
  local prio=$1 topic=$2 title=$3 body=$4 tags=$5
  [[ $notify == 1 ]] || return 0
  (( prio >= minprio )) || return 0
  local urg=normal
  (( prio >= 4 )) && urg=critical
  (( prio <= 2 )) && urg=low
  # Como en las apps de ntfy: las etiquetas con emoji van delante del título.
  local t pre=""
  for t in $tags; do [[ -n ${EMOJIS[$t]} ]] && pre="$pre${EMOJIS[$t]} "; done
  [[ -z $title ]] && title="$topic"
  notify-send -a ntfy -u "$urg" -- "$pre$title" "$body" 2>/dev/null
}

# Recibe líneas JSON de ntfy (flujo o sondeo), se queda con los mensajes,
# filtra los campos, deduplica por id, guarda y avisa.
JQ_MSG='select(.event == "message" and (.id | type) == "string")
  | { id: .id,
      time: (.time // 0),
      server: $name,
      topic: (.topic // ""),
      title: ((.title // "") | .[0:200]),
      message: ((.message // "") | .[0:4000]),
      priority: (.priority // 3),
      tags: ((.tags // []) | map(tostring) | .[0:12]),
      click: ((.click // "") | .[0:1000]),
      attachment: ((.attachment // {}) | { name: ((.name // "") | .[0:200]), url: ((.url // "") | .[0:1000]) }) }'

ingest() {      # ingest <fichero-con-lineas-json> <silencioso 0/1>
  local file=$1 silent=$2 rec id fields
  while IFS= read -r rec; do
    [[ -z $rec ]] && continue
    id=$(jq -r '.id' <<<"$rec" 2>/dev/null) || continue
    [[ -z $id || -n ${SEEN[$W_NAME/$id]} ]] && continue
    SEEN[$W_NAME/$id]=1
    store "$rec"
    # Campos separados por NUL: el mensaje puede llevar saltos de línea.
    mapfile -d '' fields < <(jq -j '[.time, .priority, .topic, .title, .message, (.tags | join(" "))] | map(tostring) | join("\u0000") + "\u0000"' <<<"$rec" 2>/dev/null)
    [[ ${fields[0]} =~ ^[0-9]+$ ]] && { printf '%s\n' "${fields[0]}" >"$STATE/since-$W_SLUG.tmp" && mv -f "$STATE/since-$W_SLUG.tmp" "$STATE/since-$W_SLUG"; }
    [[ $silent == 1 ]] || notify_msg "${fields[1]:-3}" "${fields[2]}" "${fields[3]}" "${fields[4]}" "${fields[5]}"
  done < <(jq -c --arg name "$W_NAME" "$JQ_MSG" "$file" 2>/dev/null)
}

cpid=""
stop_curl() {
  [[ -n $cpid ]] || return 0
  pkill -TERM -P "$cpid" 2>/dev/null
  kill -TERM "$cpid" 2>/dev/null
  wait "$cpid" 2>/dev/null
  cpid=""
}

worker() {
  [[ -n $W_SLUG ]] || exit 2
  trap 'stop_curl; exit 143' TERM INT HUP
  load_emoji
  load_history
  local curlrc="$RUN/curl-$W_SLUG.conf" out="$RUN/poll-$W_SLUG.json" err="$RUN/curl-$W_SLUG.err"
  local sincef="$STATE/since-$W_SLUG"
  write_curlrc "$curlrc" "$W_TOKEN" "$W_USER" "$W_PASS"

  local backoff=2 t0 since silent code rc line timeouts fd
  while :; do
    parent_alive || exit 0
    if [[ -z $W_TOPICS ]]; then
      wstatus state=no_topics
      sleep 30 & wait $!
      continue
    fi

    # 1) Un sondeo corto: da el código HTTP (el flujo no lo enseña) y trae lo
    #    que llegó mientras no escuchábamos. La primera vez no hay marca:
    #    se coge la caché del servidor sin avisar de nada, que es viejo.
    wstatus state=connecting
    t0=$(date +%s)
    since=$(cat "$sincef" 2>/dev/null); silent=0
    [[ $since =~ ^[0-9]+$ ]] || { since=all; silent=1; }
    : >"$err"
    code=$(curl -K "$curlrc" -m 25 -o "$out" -w '%{http_code}' "$W_SERVER/$W_TOPICS/json?poll=1&since=$since" 2>"$err")
    rc=$?
    if (( rc != 0 )); then
      wstatus state=unreachable "error=$(head -c 200 "$err" | head -n 1)"
      sleep "$backoff" & wait $!
      (( backoff < 60 )) && backoff=$(( backoff * 2 ))
      continue
    fi
    case $code in
      200) ;;
      401) wstatus state=unauthorized "error=HTTP 401"; sleep 60 & wait $!; continue ;;
      403) wstatus state=forbidden    "error=HTTP 403"; sleep 60 & wait $!; continue ;;
      404) wstatus state=not_found    "error=HTTP 404"; sleep 60 & wait $!; continue ;;
      429) wstatus state=rate_limited "error=HTTP 429"; sleep 120 & wait $!; continue ;;
      *)   wstatus state=http_error   "error=HTTP $code"; sleep 30 & wait $!; continue ;;
    esac
    ingest "$out" "$silent"
    rm -f "$out"

    # 2) El flujo. `since=t0` cubre el hueco entre el sondeo y esto: lo que
    #    venga repetido lo para la deduplicación por id.
    wstatus state=connected "since=$t0"
    backoff=2
    exec {fd}< <(curl -K "$curlrc" -N "$W_SERVER/$W_TOPICS/json?since=$t0" 2>"$err"; echo "@exit $?")
    cpid=$!
    timeouts=0
    while :; do
      if IFS= read -r -t 75 -u "$fd" line; then
        timeouts=0
        [[ $line == "@exit "* ]] && break
        [[ $line == *'"message"'* ]] && ingest <(printf '%s\n' "$line") 0
      else
        rc=$?
        (( rc > 128 )) || break            # fin del flujo
        # ntfy manda un keepalive cada 45 s. Dos silencios seguidos (150 s)
        # es una conexión muerta que TCP aún no ha dado por perdida.
        (( ++timeouts >= 2 )) && break
      fi
      parent_alive || { stop_curl; exit 0; }
    done
    stop_curl
    exec {fd}<&-
    wstatus state=reconnecting "error=$(head -c 200 "$err" | head -n 1)"
    sleep "$backoff" & wait $!
    (( backoff < 60 )) && backoff=$(( backoff * 2 ))
  done
}

# ── Modos sueltos ─────────────────────────────────────────────────────
mark_read() {
  local until=""
  [[ -s $MSGS ]] && until=$(jq -s 'map(.time // 0) | max' "$MSGS" 2>/dev/null)
  [[ $until =~ ^[0-9]+$ ]] || until=$(date +%s)
  printf 'until=%s\n' "$until" >"$READFILE.tmp" && mv -f "$READFILE.tmp" "$READFILE"
}

clear_history() {
  { flock 8; : >"$MSGS"; } 8>>"$MSGLOCK"
  # Sin marca, el próximo sondeo traería la caché del servidor otra vez.
  local f
  for f in "$STATE"/since-*; do [[ -e $f && $f != *.tmp ]] && date +%s >"$f"; done
  mark_read
}

delete_msg() {
  local id=$1
  [[ -n $id && -s $MSGS ]] || return 0
  { flock 8; jq -c --arg id "$id" 'select(.id != $id)' "$MSGS" >"$MSGS.tmp.$$" 2>/dev/null && mv -f "$MSGS.tmp.$$" "$MSGS"; } 8>>"$MSGLOCK"
}

send_test() {
  parse_conf
  (( ${#S_NAME[@]} > 0 )) || { echo "sin servidores configurados" >&2; exit 1; }
  local i=0 topic="${S_TOPICS[0]%%,*}"
  [[ -n $topic ]] || { echo "el primer servidor no tiene temas" >&2; exit 1; }
  local text="${*:-Prueba desde Omarchy $(date +%H:%M:%S)}" rc="$RUN/curl-send.conf" code
  write_curlrc "$rc" "${S_TOKEN[i]}" "${S_USER[i]}" "${S_PASS[i]}"
  code=$(curl -K "$rc" -m 15 -o /dev/null -w '%{http_code}' -H "Title: safloresmo.ntfy" -H "Tags: white_check_mark" --data-binary "$text" "${S_SERVER[i]}/$topic")
  rm -f "$rc"
  echo "HTTP $code -> ${S_SERVER[i]}/$topic"
  [[ $code == 200 ]]
}

write_conf() {
  mkdir -p "$(dirname "$CONF")" || exit 2
  local tmp="$CONF.tmp.$$"
  cat >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONF"
}

check() {
  parse_conf
  echo "conf:      $CONF ($conf_state)"
  echo "avisos:    $([[ $notify == 1 ]] && echo "sí, prioridad >= $minprio" || echo no)"
  echo "historial: $MSGS ($( [[ -s $MSGS ]] && wc -l <"$MSGS" || echo 0 ) mensajes, tope $keep)"
  echo "supervisor: pid $(status_meta pid) $(status_meta state)"
  local i
  for (( i = 0; i < ${#S_NAME[@]}; i++ )); do
    echo "[${S_NAME[i]}] ${S_SERVER[i]}  temas: ${S_TOPICS[i]:-(ninguno)}  auth: $(auth_kind "${S_TOKEN[i]}" "${S_USER[i]}")" \
         "$( [[ -n ${S_BAD[i]} ]] && echo " rechazados: ${S_BAD[i]}")" \
         "estado: $(sed -n "/^@${S_SLUG[i]}\$/,/^\.\$/s/^state=//p" "$STATUS" 2>/dev/null | head -n 1)"
  done
}

case ${1:-listen} in
  listen)     listen ;;
  worker)     worker ;;
  read)       mark_read ;;
  clear)      clear_history ;;
  delete)     delete_msg "$2" ;;
  send)       shift; send_test "$@" ;;
  write-conf) write_conf ;;
  check)      check ;;
  *) echo "uso: ${0##*/} listen|read|clear|delete <id>|send [texto]|write-conf|check" >&2; exit 2 ;;
esac
