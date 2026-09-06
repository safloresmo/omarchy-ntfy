# Wire and file formats

What `listen.sh` asks ntfy for, and what it leaves on disk for the QML.

## ntfy endpoints used

All calls go to `<server>/<topic1,topic2,…>/…`. Credentials, when a server
has them, travel as `Authorization: Bearer <token>` or HTTP basic auth,
through a curl config file with mode 600.

| Call | When | Why |
|---|---|---|
| `GET /<topics>/json?poll=1&since=<t>` | before every (re)connection | Gives the HTTP status code (the stream never does), and returns the messages that arrived since the last one stored. `since=all` the very first time, with no history: those are fetched silently. |
| `GET /<topics>/json?since=<t0>` (streaming) | after a successful poll | The live stream. `t0` is the time just before the poll, so nothing falls in the gap; repeats are dropped by id. ntfy sends a `keepalive` every 45 s; two silent windows of 75 s mean a dead connection and force a reconnect. |
| `POST /<topic>` | `send` mode only (the `t` key) | The one thing the plugin ever publishes: a test message. |

HTTP status handling: `401` → `unauthorized`, `403` → `forbidden`, `404` →
`not_found`, `429` → `rate_limited`, other non-200 → `http_error`; curl
failure → `unreachable`. Auth and 404 states retry every 60 s, rate limit
every 120 s, network errors with exponential backoff from 2 s to 60 s.

## Message record (`messages.jsonl`)

`~/.local/state/sfm/ntfy/messages.jsonl`, one JSON object per line, oldest
first, capped at `keep` (+50 slack before trimming). Only these fields are
kept from what ntfy sends; `actions` in particular are dropped on entry.

```json
{"id":"K20fArMNWlf0","time":1788636347,"server":"Homelab","topic":"homelab-…",
 "title":"Test 5/5 · End of test","message":"Test sequence finished.",
 "priority":3,"tags":["white_check_mark","test_tube"],"click":"",
 "attachment":{"name":"","url":""}}
```

| Field | Cap | Notes |
|---|---|---|
| `id` | 64 | ntfy's message id; deduplication key together with `server` |
| `time` | | Unix seconds, server clock |
| `server` | 64 | Section name from `ntfy.conf` |
| `topic` | 64 | |
| `title`, `message` | 200 / 4000 | Rendered as plain text |
| `priority` | 1–5 | Missing → 3 |
| `tags` | 12 | Emoji shortcodes resolve through `emoji.tsv`; the rest are shown as text |
| `click` | 1000 | Only `http`, `https`, `mailto` are ever opened |
| `attachment.name`, `attachment.url` | 200 / 1000 | |

Writers: every listener appends under `flock` on `messages.lock`; trimming
happens under the same lock. `delete` and `clear` rewrite the file under it
too.

## Read marker and cursors

- `read` — `until=<unix time>`. Messages with `time <= until` are read.
  Written by `read` (max time in history) and `clear` (now).
- `since-<slug>` — unix time of the last message stored from that server;
  the `since` of the next poll. `clear` sets them to now so the server cache
  is not fetched again.

## Status file

`$XDG_RUNTIME_DIR/sfm-ntfy/status`, rewritten atomically by the supervisor
whenever a listener reports (SIGUSR1). Record protocol of the `sfm.*` series:
`@name` opens a record, `key=value` lines (split at the first `=`), `.`
closes it.

```
@meta
pid=4014173
key=e4427f441acd6a45
conf=ok
servers=1
state=running
updated=1788636400
.
@homelab
name=Home lab
server=https://ntfy.example.com
topics=alerts,backups
auth=none
state=connected
since=1788636399
updated=1788636400
.
```

`@meta.key` identifies the supervisor's settings and script version: an
instance that fails the lock compares it with its own and, if different,
replaces the running supervisor. `@meta.conf` is `absent`, `ok`, `open`
(readable by others) or `unreadable`. Per-server `state` is one of
`starting`, `connecting`, `connected`, `reconnecting`, `unreachable`,
`unauthorized`, `forbidden`, `not_found`, `rate_limited`, `http_error`,
`no_topics`; `error` carries the HTTP code or curl's first line;
`bad_topics` lists topic names ntfy would reject.

Each listener writes its own record to `status.d/<slug>`; the supervisor
concatenates them. `<slug>` is the section name reduced to
`[A-Za-z0-9_-]`, unique per server.

## Subscriptions file

`~/.config/sfm/ntfy.conf`, mode 600, INI with one section per server. Keys
in English or Spanish: `server`/`servidor`, `topics`/`temas`, `token`,
`user`/`usuario`, `password`/`clave`. Keys before the first section header
form a nameless server (the pre-1.1 format). `SFM_NTFY_SERVER` /
`SFM_NTFY_TOPICS` in the environment (the shell's `server`/`topics`
settings) add one more server named `ajustes`.

## Process model

```
Service.qml ──spawns──▶ listen.sh listen   (supervisor, flock, one per session)
                           ├─▶ listen.sh worker  [server A]  ──▶ curl (stream)
                           └─▶ listen.sh worker  [server B]  ──▶ curl (stream)
```

The supervisor checks every 2 s that its parent (the shell) is alive, that
the subscriptions file has not changed (else restart every worker) and that
every worker is alive (else respawn it, at most every 10 s). Workers exit on
their own when the supervisor dies. Listeners send desktop notifications
themselves with `notify-send -a ntfy`, so a message notifies once however
many monitors, and therefore widget instances, there are.

Settings from the shell reach the supervisor as environment variables:
`SFM_NTFY_NOTIFY`, `SFM_NTFY_MIN_PRIORITY`, `SFM_NTFY_KEEP`. Test overrides:
`SFM_NTFY_STATE`, `SFM_NTFY_RUN`, `SFM_NTFY_CONF` (paths) and
`SFM_NTFY_PARENT=0` (disable the parent check).
