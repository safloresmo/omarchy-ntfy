# ntfy for Omarchy

Bar widget for Omarchy 4 that receives your [ntfy](https://ntfy.sh)
notifications: every message published to your topics pops up as a desktop
notification and stays in a panel with the history, links and attachments.
Works with the public `ntfy.sh` server and with your own, with or without
credentials, and with several servers at once.

The interface follows the system language: English by default, Spanish when
the locale says so. No language switch.

*Versión en español: [README.es.md](README.es.md).*

![preview](preview.png)

## What you get

**In the bar** — the bullhorn glyph and the number of unread messages. The
alert colour is reserved for an unread message of high or max priority (4 or
5 in ntfy terms); a connection or configuration problem adds a warning glyph,
not just a colour, because on some themes the alert colour has less contrast
than normal text. The tooltip lists the last five messages.

**In the panel**
- One row per message, newest first: emoji from the tags, title, text, topic,
  priority, attachment name. Unread rows carry a dot; unread high-priority
  rows are drawn in the alert colour with a warning glyph.
- Open the message's `click` URL or its attachment, copy the text, remove it
  from the history.
- Warnings on top for whatever prevents receiving: no servers, credentials
  rejected, server unreachable, subscriptions file readable by other users…
- **Servers and topics are edited in the panel** (gear icon or `e`): one card
  per server with its name, URL, comma-separated topics and, when needed, an
  access token or user and password. Add or remove servers, `Ctrl+↵` saves.

**On the desktop** — one notification per message through `notify-send`,
with the urgency derived from the ntfy priority (1–2 low, 3 normal, 4–5
critical) and the tag emojis in front of the title, like the ntfy apps do.

## Install

```bash
omarchy plugin add https://github.com/safloresmo/omarchy-ntfy.git   # or copy the folder
omarchy plugin enable safloresmo.ntfy
```

Then open the panel, press the gear, add a server and its topics, save. To
check it works, press `t` in the panel: it publishes a test message to the
first topic of the first server. Or from anywhere:

```bash
curl -d "Hello from the workshop" -H "Title: Test" -H "Tags: rocket" https://ntfy.sh/your-topic
```

Topics on `ntfy.sh` are public to anyone who knows their name. A long random
name is the only protection there is without an account.

### Subscriptions file

The editor writes `~/.config/sfm/ntfy.conf` with mode **600**, one section
per server. It can be edited by hand; the listener notices and reconnects:

```ini
[home]
server = https://ntfy.example.org
topics = workshop, alarm
token = tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

`ntfy.conf.example` has the full format (Spanish keys `servidor`, `temas`,
`usuario`, `clave` work too). Credentials never go into the shell's settings,
which are world-readable.

`omarchy bar set safloresmo.ntfy topics a,b` (and `server`) still works: the listener
treats it as one more server, named “ajustes”.

## Settings

Servers and topics are not shell settings; they live in the file above. The
rest, in Setup › Plugins › ntfy or with `omarchy bar set safloresmo.ntfy <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `notify` | `true` | Send desktop notifications |
| `minPriority` | `1` | Minimum ntfy priority (1–5) that notifies; below it, history only |
| `keep` | `200` | Messages kept in the history |

## Keyboard

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k` | Move the cursor |
| `↵`, `→` | Open the link; without one, the attachment; without either, copy the text |
| `x` | Remove the message from the history |
| `c` | Copy the text |
| `a` | Mark everything as read |
| `t` | Publish a test message to the first topic |
| `e` | Open the servers and topics editor |
| `r` | Reconnect |
| `1`–`9` | Jump to message n |
| `q`, `Esc` | Close |

In the editor: `Tab`/`↵` next field, `Ctrl+↵` save, `Esc` cancel.

Mouse on the bar icon: left click opens the panel, right click marks all as
read, middle click reconnects. Closing the panel marks what was shown as
read, as any tray does.

## How it is built

`listen.sh` is a supervisor that starts one listener per server. Each
listener streams the topics over HTTP (`/json`) with `curl` and appends what
arrives to `~/.local/state/sfm/ntfy/messages.jsonl` under a lock, since
several write to it. The QML never talks to ntfy: it watches that file, the
read marker, the subscriptions file and a status file with one record per
server (`$XDG_RUNTIME_DIR/sfm-ntfy/status`).

**One listener per session.** The shell instantiates a bar widget once per
monitor; if each opened its own connection, every message would notify once
per screen. The script takes a `flock`; instances that do not get it exit and
the widget retries once a minute in case the supervisor dies. A supervisor
running with other settings, or with an older copy of the script, is
replaced. A change in the subscriptions needs none of that: the supervisor
sees the file change and restarts the listeners.

**Nothing is lost across reconnects.** Before opening the stream, a poll
with `since=<last stored message>` fetches whatever arrived while offline,
and notifies about it. Only the very first time, with no history, the
server cache is fetched silently: it is old news. Deduplication is by
message id.

**Read-only.** ntfy messages can carry `actions` (open a URL, fire an HTTP
request, send a broadcast). They are neither executed nor stored: they are
filtered out on entry. Only the displayed fields of a message are kept. The
only thing the plugin ever publishes is the test message behind `t`.

**No new dependencies**: bash, curl, jq, flock and notify-send, all from the
base system. The wire and file formats are described in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Security notes

- Credentials go to `curl` through a config file with mode 600, never on the
  command line where `ps` shows them; the subscriptions file is written with
  mode 600 and the panel warns if it is ever found more open than that.
- The `click` URL of a message is whatever the publisher wrote. The panel
  only hands `http`, `https` and `mailto` URLs to `xdg-open`.
- Titles and bodies are rendered as plain text, never as rich text.

## Debugging

```bash
~/.config/omarchy/plugins/safloresmo.ntfy/listen.sh check
```

Prints each server with its topics, credential type and state, plus the
supervisor's. The other modes (`read`, `clear`, `delete <id>`,
`send [text]`, `write-conf`) are the ones the panel uses and can be run by
hand.

## Tests

The `sfm.*` series ships two checkers (in the author's setup repository,
`archivos/plugins/`): `check-qml.sh`, a static pass for QML mistakes that
silently stop a component from instantiating, and `check-panel.sh`, which
instantiates `Service.qml` and `Panel.qml` in a headless Quickshell and
drives the keyboard cursor through edge cases with every action inhibited.
Both pass in English and Spanish locales. The listener was exercised against
`ntfy.sh` with throwaway topics: two servers at once, credential rejection,
a subscriptions reload, forced reconnection and takeover between instances.
