# DB Client for Omarchy

A database client for the [Omarchy](https://omarchy.org) shell, in the spirit of
the VS Code *Database Client* extension: a schema tree with views, functions,
procedures, sequences and triggers, query tabs, an editable data grid, and a
driver installer that asks before touching your system.

| Engine            | Driver (Python)       | Objects in the tree                                                              | Query language                    |
|-------------------|-----------------------|----------------------------------------------------------------------------------|-----------------------------------|
| MySQL / MariaDB   | `PyMySQL`             | tables, views, functions, procedures, triggers, events, indexes                  | SQL, `DELIMITER` supported        |
| PostgreSQL        | `psycopg` 3           | schemas, tables, views, materialized views, functions, procedures, sequences, triggers, indexes | SQL, `$$` bodies supported |
| Oracle            | `oracledb` (thin)     | tables, views, materialized views, functions, procedures, packages, sequences, triggers, indexes | SQL, PL/SQL units ended by `/` |
| ClickHouse        | `clickhouse-connect`  | tables, views, dictionaries                                                      | SQL (HTTP interface)              |
| Redis / Valkey    | `redis`               | db0…dbN → keys, by type                                                          | one command per line              |
| SQLite            | built in              | tables, views, indexes, triggers                                                 | SQL, trigger bodies supported     |
| MongoDB           | `pymongo`             | databases → collections and views → indexes                                     | mongosh-style (`db.c.find(...)`)  |

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
- The editor highlights SQL (keywords, types, functions, strings, numbers,
  comments, quoted identifiers, `$1`/`:name` parameters), Redis commands and
  mongosh syntax, with colors taken from the current Omarchy theme. They
  follow theme switches live.
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
| `Ctrl+Enter` / `F5`       | Run (selection or everything); reload in a table tab |
| `Ctrl+S` / `Ctrl+I`       | Save changes / add a row (table tab) |
| `Ctrl+T` / `Ctrl+W`       | New / close query tab          |
| `Ctrl+Shift+W`            | Close all tabs (also the `⊠` button; right-click a tab for close others / to the right) |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab (also `Ctrl+PgDown` / `Ctrl+PgUp`) |
| `Alt+1` … `Alt+8`, `Alt+9` | Go to tab 1…8, last tab        |
| `Ctrl+P`                  | Open-tabs switcher (also the `☰` button) |
| `Ctrl+Shift+E`            | Focus the sidebar              |
| `Ctrl+N`                  | New connection                 |
| `Esc`                     | Close the current dialog       |

Sidebar keyboard navigation (after `Ctrl+Shift+E` or a click):

| Key                       | Action                                         |
|---------------------------|------------------------------------------------|
| `↑` `↓` `PgUp` `PgDown` `Home` `End` | Move                                |
| `→` / `←`                 | Expand (then go to first child) / collapse (then go to parent) |
| `Enter`                   | Open the table data / DDL, or expand           |
| `Space`                   | Expand / collapse                              |
| `Menu` / `Shift+F10`      | Actions menu (arrows + `Enter` inside)         |
| `Del` / `F2`              | Drop the object (with confirmation) / edit the connection |
| letters                   | Jump to the next name starting with them       |
| `Tab`                     | Back to the editor / grid                      |

UI language: the `AUTO / EN / FR` switch at the bottom of the sidebar.

### Schema objects

Objects are grouped in folders (Tables, Views, Functions, Triggers…).
Right-click a node, or use its `⋯` button, to see what you can do with it:

- **Open data**: open a table, view or collection in the data editor. This is
  also what a double-click on a table does.
- **SELECT in a query tab**: run the default query on the object.
- **View / edit definition**: opens the DDL in a query tab. Views, functions,
  procedures and triggers come out as a runnable `CREATE OR REPLACE` (or
  `DROP … IF EXISTS` + `CREATE`) script, so running the tab applies your edit.
  Tables show their `CREATE TABLE` for reference. This is also what a
  double-click on a function or trigger does.
- **New…** on a folder: opens a ready-to-edit template (table, view, function,
  procedure, sequence, trigger, event, package…). On a connection: new database.
- **New index**, **Refresh materialized view**, **Empty (TRUNCATE)**,
  **Drop**: these show the exact statement and ask for confirmation first.

### Data editor

**Open data** opens a table tab with an editable grid.

| Action                          | How                                                        |
|---------------------------------|------------------------------------------------------------|
| Edit a cell                     | double-click, `F2`, `Enter`, or just start typing          |
| Next cell / next row            | `Tab` / `Enter` while editing, `Esc` cancels               |
| Add a row                       | `+` or `Ctrl+I`. Unset cells stay `DEFAULT`                 |
| Select rows                     | click the row number (`Ctrl` toggles, `Shift` extends, `Shift+↑↓` too) |
| Select all                      | `Ctrl+A` or the `✓✓` button; `Ctrl+C` then copies the rows as TSV |
| Delete / restore selected rows  | `−` or `Del`                                               |
| Set NULL                        | `NULL` button                                              |
| Save                            | `Save (n)` or `Ctrl+S`                                     |
| Discard                         | `↶` (undo all pending changes)                             |
| Filter                          | the `WHERE …` field (Mongo: `{age: {$gt: 18}}`, Redis: `MATCH` pattern) |
| Sort                            | click a column header                                      |
| Pages                           | `‹` `›` and the page-size field                            |

Changes stay pending until you save. Modified cells are highlighted, new rows
are green, deleted rows red and struck through, and the tab gets a `●`. On
save everything runs in **one transaction**: if a row changed or disappeared in
the meantime, nothing is written.

Rows are identified by their primary key. Without one, the editor falls back
to PostgreSQL `ctid`, SQLite `rowid` or Oracle `ROWID`. MySQL tables without a
primary or unique `NOT NULL` key, and all views, are read-only.

Engine specifics:
- **ClickHouse**: updates and deletes are mutations (`ALTER TABLE … UPDATE`,
  lightweight `DELETE`), run with `mutations_sync = 1`. They are not
  transactional.
- **MongoDB**: edited cells accept mongosh literals: `42`, `true`, `["a"]`,
  `{city: "Lyon"}`, `ObjectId("…")`. Anything else is stored as a string.
  Quote a value (`"42"`) to force a string.
- **Redis**: each key opens as a grid shaped by its type (string, hash,
  list, set, sorted set). Streams are read-only. The TTL is kept when a value
  is changed.

### MongoDB syntax

```js
show dbs
use shop
show collections
db.users.find({age: {$gt: 18}, name: /^al/i}, {name: 1}).sort({age: -1}).skip(10).limit(20)
db.users.findOne({_id: ObjectId("64b7f0c2a1b2c3d4e5f60718")})
db.users.aggregate([{$group: {_id: "$city", n: {$sum: 1}}}])
db.users.countDocuments({})    // also: distinct, insertOne/Many, updateOne/Many, replaceOne,
                               //       deleteOne/Many, getIndexes, createIndex, dropIndex, drop
db.createCollection("logs")
db.createView("adults", "users", [{$match: {age: {$gte: 18}}}])
db.dropDatabase()
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
omarchy-dbclient table "Prod PG" users [db.schema]   # open a table in the data editor
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
in `backend/`, a single Python process that speaks JSON lines over
stdin/stdout: `dbclient.py` (server), `core.py` (drivers, script splitting,
the shared data editor), `sql_engines.py` and `nosql_engines.py`. It keeps one session per connection, runs each request in its own
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
