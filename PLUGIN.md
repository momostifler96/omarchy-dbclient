# DB Client

**A database client for Omarchy, in the spirit of the VS Code *Database Client* extension.**
Browse schemas, write queries with syntax highlighting, and edit table data in place — for
MySQL/MariaDB, PostgreSQL, Oracle, ClickHouse, Redis/Valkey, SQLite and MongoDB, from one
native window that follows your Omarchy theme.

![Query editor with syntax highlighting and results](https://raw.githubusercontent.com/momostifler96/omarchy-dbclient/main/screenshots/query-editor.png)

## Features

- **7 engines, one window**: MySQL / MariaDB, PostgreSQL, Oracle (thin driver, no Instant Client),
  ClickHouse, Redis / Valkey, SQLite and MongoDB.
- **Schema tree**: databases, schemas, tables, views, materialized views, functions, procedures,
  packages, sequences, triggers, events, indexes, dictionaries, collections and keys, grouped in folders.
  Right-click any object for its actions: open data, `SELECT`, show DDL, create, create index,
  truncate, drop (always with a confirmation that shows the exact SQL).
- **Query tabs** with syntax highlighting for SQL, Redis commands and mongosh syntax, in your theme's colors.
  Run everything or only the selection (`Ctrl+Enter` / `F5`); multi-statement scripts, `DELIMITER`,
  `$$` bodies and PL/SQL `/` blocks are handled.
- **Editable data grid**: edit cells inline, add rows, delete rows, set `NULL`, then review and
  **Save** all pending changes in a single transaction (or discard them). Filter with a `WHERE`
  clause (or a Mongo filter / Redis pattern), sort by column, paginate.
- **Selection & export**: select all rows (`Ctrl+A`), copy cells or rows (TSV, ready for a spreadsheet),
  copy as CSV / JSON, export to CSV.
- **Keyboard first**: switch tabs with `Ctrl+Tab`, `Alt+1…9` or the `Ctrl+P` tab switcher, close all tabs
  with `Ctrl+Shift+W`, and navigate the sidebar with the arrow keys (`→` expands, `←` goes to the parent,
  `Enter` opens, type a name to jump to it).
- **Driver installer**: missing drivers are detected and you are asked before anything is installed —
  via **pacman** (in a floating terminal, you type your sudo password) or **pip** into a private venv
  (no sudo, system Python untouched).
- **CLI & shortcuts**: `Super+Alt+D` toggles the window, `Super+Shift+Alt+D` creates a connection,
  and `omarchy-dbclient query|table|open|new` drives it from scripts.
- English and French UI.

## Screenshots

**Data editor** — edit, insert and delete rows, then save everything at once.

![Data editor](https://raw.githubusercontent.com/momostifler96/omarchy-dbclient/main/screenshots/data-editor.png)

**ClickHouse** — the same query tabs for every engine.

![ClickHouse query](https://raw.githubusercontent.com/momostifler96/omarchy-dbclient/main/screenshots/clickhouse.png)

**Tab switcher** (`Ctrl+P`) — jump between open queries and tables.

![Tab switcher](https://raw.githubusercontent.com/momostifler96/omarchy-dbclient/main/screenshots/tab-switcher.png)

**New connection** — pick an engine, test, save.

![New connection](https://raw.githubusercontent.com/momostifler96/omarchy-dbclient/main/screenshots/new-connection.png)

## Install

```bash
omarchy plugin add https://github.com/momostifler96/omarchy-dbclient.git --enable
~/.config/omarchy/plugins/momoledev.dbclient/install.sh --bindings --menu
```

`--bindings` adds the `Super+Alt+D` / `Super+Shift+Alt+D` shortcuts and `--menu` adds a *DB Client*
entry to the Omarchy menu (both files are backed up first). The only requirement is `python3`;
SQLite works out of the box and other drivers are offered the first time you need them.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Super+Alt+D` | Toggle the window |
| `Ctrl+Enter` / `F5` | Run the query (or the selection) |
| `Ctrl+T` / `Ctrl+W` / `Ctrl+Shift+W` | New tab / close tab / close all tabs |
| `Ctrl+Tab`, `Ctrl+Shift+Tab`, `Alt+1…9` | Switch tabs |
| `Ctrl+P` | Open-tabs switcher |
| `Ctrl+Shift+E` | Focus the sidebar (then arrows, `Enter`, `Menu`) |
| `Ctrl+S` / `Ctrl+I` | Save changes / add a row |
| `Ctrl+A` / `Ctrl+C` / `Del` | Select all rows / copy / delete rows |
| `Ctrl+N` | New connection |

## Links

- Source, full documentation and issues: <https://github.com/momostifler96/omarchy-dbclient>
- License: MIT
