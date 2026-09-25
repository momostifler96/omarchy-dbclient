# DB Client for Omarchy

A database client for the [Omarchy](https://omarchy.org) shell, in the spirit of
the VS Code *Database Client* extension: a connection tree, query tabs, a result
grid, and a driver installer that asks before touching your system.

| Engine            | Driver (Python)       | Tree                                    | Query language                   |
|-------------------|-----------------------|-----------------------------------------|----------------------------------|
| MySQL / MariaDB   | `PyMySQL`             | databases → tables/views → columns      | SQL                              |
| PostgreSQL        | `psycopg` 3           | databases → schemas → tables → columns  | SQL (`$$` bodies supported)      |
| Oracle            | `oracledb` (thin)     | schemas → tables/views → columns        | SQL, PL/SQL blocks ended by `/`  |
| ClickHouse        | `clickhouse-connect`  | databases → tables → columns            | SQL (HTTP interface)             |
| Redis / Valkey    | `redis`               | db0…dbN → keys (by type)                | one command per line             |
| SQLite            | built in              | tables/views → columns                  | SQL                              |
| MongoDB           | `pymongo`             | databases → collections → indexes       | mongosh-style (`db.c.find(...)`) |

Oracle uses the thin driver, so no Instant Client is needed.

## Install

```bash
omarchy plugin add https://github.com/momostifler96/omarchy-dbclient.git --enable
~/.config/omarchy/plugins/momoledev.dbclient/install.sh --bindings --menu
```

`install.sh` links `omarchy-dbclient` into `~/.local/bin`. `--bindings` adds the
global shortcuts below to `~/.config/hypr/bindings.lua`, and `--menu` adds a
*DB Client* entry to the Omarchy menu. Each file gets a backup first.

| Global (Hyprland)      | Action                        |
|------------------------|-------------------------------|
| `Super+Alt+D`          | Toggle the DB client window   |
| `Super+Shift+Alt+D`    | New connection                |

The only requirement is `python3`, which Omarchy already ships.

## Drivers

Only SQLite works out of the box. The first time you connect to another engine
(or pick it in the connection form), the app warns you that the driver is
missing and asks how to install it:

- **pacman** (MySQL, PostgreSQL, Redis, MongoDB): installs `python-pymysql`,
  `python-psycopg`, `python-redis` or `python-pymongo` in a floating terminal,
  where you type your sudo password. The app picks the driver up automatically
  once pacman finishes.
- **pip**: installs into a private venv in `~/.local/share/omarchy-dbclient/venv`.
  No sudo, and nothing touches the system Python. This is the only option for
  Oracle and ClickHouse, which aren't in the official repos. `uv` is used when
  it's available.

Nothing is installed without a click. The *Drivers* button (top of the
sidebar) and `omarchy-dbclient drivers` show what's installed.

## Usage

Open the window from the bar icon, with `Super+Alt+D`, or with `omarchy-dbclient`.

- **+** in the sidebar adds a connection. **Test** checks it before you save it.
- Click a connection to connect and expand it. Double-click a table, collection
  or key (or hover and press ▷) to open it in a query tab.
- Row buttons on a connection: new query, refresh, disconnect, edit, delete.
- Run the whole editor, or only the selection, with `Ctrl+Enter` or `F5`.
  Several statements separated by `;` each produce a result, and you can
  switch between them above the grid.
- Double-click a cell (or press `Enter`) to see its full value, with JSON
  pretty-printed. `Ctrl+C` copies the selected cell.
- *Copy CSV*, *Copy JSON* and *Export CSV* (to `~/Downloads`) work on the
  current result.
- Tabs and their text are kept when you close the window, and across restarts.

| In the window             | Action                         |
|---------------------------|--------------------------------|
| `Ctrl+Enter` / `F5`       | Run (selection or everything)  |
| `Ctrl+T` / `Ctrl+W`       | New / close query tab          |
| `Ctrl+Tab`                | Next tab                       |
| `Ctrl+N`                  | New connection                 |
| `Esc`                     | Close the current dialog       |

UI language: the `AUTO / EN / FR` switch at the bottom of the sidebar.

### MongoDB syntax

```js
show dbs
use shop
show collections
db.users.find({age: {$gt: 18}, name: /^al/i}, {name: 1}).sort({age: -1}).skip(10).limit(20)
db.users.findOne({_id: ObjectId("64b7f0c2a1b2c3d4e5f60718")})
db.users.aggregate([{$group: {_id: "$city", n: {$sum: 1}}}])
db.users.countDocuments({})    // also: distinct, insertOne/Many, updateOne/Many, replaceOne,
                               //       deleteOne/Many, getIndexes, createIndex, drop
db.getCollection("logs.2024").find()
db.runCommand({dbStats: 1})
```

Literals may use unquoted keys, single quotes, trailing commas, `ObjectId()`,
`ISODate()`, `NumberLong()`, `NumberDecimal()`, `UUID()` and `/regex/flags`.

### Redis syntax

One command per line, quoting like a shell: `GET "key with spaces"`,
`HGETALL user:1`, `SCAN 0 MATCH session:* COUNT 100`, `SELECT 2`.

## Command line

```bash
omarchy-dbclient                          # toggle the window
omarchy-dbclient open "Prod PG"           # open and expand a connection (id or name)
omarchy-dbclient query "Prod PG" "SELECT now()" [database]
omarchy-dbclient new                      # new connection form
omarchy-dbclient list                     # saved connections
omarchy-dbclient drivers                  # driver status
```

## Files

| Path                                          | Content                                  |
|-----------------------------------------------|------------------------------------------|
| `~/.config/omarchy-dbclient/connections.json` | saved connections, mode 600 (passwords included) |
| `~/.config/omarchy-dbclient/settings.json`    | UI language                              |
| `~/.local/state/omarchy-dbclient/tabs.json`   | open query tabs                          |
| `~/.local/share/omarchy-dbclient/venv`        | drivers installed with pip               |

## How it works

`Panel.qml` is a `panel` plugin with `keepLoaded: true`, so the window and its
state live inside `omarchy-shell` between openings. All database work happens
in `backend/dbclient.py`, a single Python process that speaks JSON lines over
stdin/stdout. It keeps one session per connection, runs each request in its own
thread, and reconnects once if a connection drops.

Because the panel stays loaded, edits to its QML take effect after
`omarchy restart shell`.

## Tests

```bash
python3 tests/smoke.py              # MySQL, PostgreSQL, Redis, MongoDB, ClickHouse in Docker
python3 tests/smoke.py oracle       # Oracle Free (large image)
```

## License

MIT
