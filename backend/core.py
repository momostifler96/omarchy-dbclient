"""Shared helpers for the Omarchy DB client backend.

Speaks JSON lines on stdin/stdout. Every request is {"id", "cmd", ...} and
gets exactly one {"id", "ok", "result"|"error"} reply; long-running commands
may also emit {"event", ...} lines in between (install logs, driver changes).

Drivers are plain Python packages. They are imported from the system
site-packages (pacman: python-pymysql, ...) or from a private venv in
~/.local/share/omarchy-dbclient/venv (pip, no sudo). Nothing is installed
without an explicit "install_driver" request, which the UI only sends after
the user has confirmed.
"""

import base64
import datetime
import decimal
import glob
import importlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time

HOME = os.path.expanduser("~")
CONFIG_DIR = os.environ.get("DBCLIENT_CONFIG_DIR", os.path.join(HOME, ".config", "omarchy-dbclient"))
DATA_DIR = os.environ.get("DBCLIENT_DATA_DIR", os.path.join(HOME, ".local", "share", "omarchy-dbclient"))
CONN_FILE = os.path.join(CONFIG_DIR, "connections.json")
SETTINGS_FILE = os.path.join(CONFIG_DIR, "settings.json")
STATE_FILE = os.path.join(os.environ.get("DBCLIENT_STATE_DIR", os.path.join(HOME, ".local", "state", "omarchy-dbclient")), "tabs.json")
VENV_DIR = os.path.join(DATA_DIR, "venv")

DRIVERS = {
    "mysql":      {"label": "MySQL / MariaDB", "module": "pymysql",            "pip": "PyMySQL",            "pacman": "python-pymysql",  "port": 3306},
    "postgresql": {"label": "PostgreSQL",      "module": "psycopg",            "pip": "psycopg[binary]",    "pacman": "python-psycopg",  "port": 5432},
    "oracle":     {"label": "Oracle",          "module": "oracledb",           "pip": "oracledb",           "pacman": None,              "port": 1521},
    "clickhouse": {"label": "ClickHouse",      "module": "clickhouse_connect", "pip": "clickhouse-connect", "pacman": None,              "port": 8123},
    "redis":      {"label": "Redis / Valkey",  "module": "redis",              "pip": "redis",              "pacman": "python-redis",    "port": 6379},
    "sqlite":     {"label": "SQLite",          "module": "sqlite3",            "pip": None,                 "pacman": None,              "port": 0},
    "mongodb":    {"label": "MongoDB",         "module": "pymongo",            "pip": "pymongo",            "pacman": "python-pymongo",  "port": 27017},
}

MAX_CELL = 20000

_out_lock = threading.Lock()


def emit(obj):
    line = json.dumps(obj, default=str, ensure_ascii=False)
    with _out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

def add_venv_to_path():
    for site in glob.glob(os.path.join(VENV_DIR, "lib", "python*", "site-packages")):
        if site not in sys.path:
            sys.path.append(site)
    importlib.invalidate_caches()


def driver_available(kind):
    module = DRIVERS[kind]["module"]
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def driver_status():
    add_venv_to_path()
    out = {}
    for kind, d in DRIVERS.items():
        out[kind] = {
            "label": d["label"],
            "module": d["module"],
            "pip": d["pip"],
            "pacman": d["pacman"] if d["pacman"] and shutil.which("pacman") else None,
            "port": d["port"],
            "installed": driver_available(kind),
            "builtin": d["pip"] is None,
        }
    return {"drivers": out, "venv": VENV_DIR, "python": sys.executable}


def require_driver(kind):
    if kind not in DRIVERS:
        raise ValueError("Unknown database type: %s" % kind)
    if not driver_available(kind):
        err = RuntimeError("Driver '%s' is not installed" % DRIVERS[kind]["module"])
        err.code = "driver_missing"
        err.kind = kind
        raise err
    return importlib.import_module(DRIVERS[kind]["module"])


def run_logged(req_id, argv):
    emit({"event": "install_log", "id": req_id, "line": "$ " + " ".join(argv)})
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        emit({"event": "install_log", "id": req_id, "line": line.rstrip()})
    return proc.wait()


def install_pip(req_id, kind):
    package = DRIVERS[kind]["pip"]
    py = os.path.join(VENV_DIR, "bin", "python")
    if not os.path.exists(py):
        os.makedirs(DATA_DIR, exist_ok=True)
        if run_logged(req_id, [sys.executable, "-m", "venv", VENV_DIR]) != 0:
            raise RuntimeError("Could not create the venv (is python's ensurepip available? try: sudo pacman -S python-pip)")
    if shutil.which("uv"):
        argv = ["uv", "pip", "install", "--python", py, "--upgrade", package]
    else:
        argv = [py, "-m", "pip", "install", "--disable-pip-version-check", "--upgrade", package]
    if run_logged(req_id, argv) != 0:
        raise RuntimeError("pip failed to install %s" % package)


def install_pacman(req_id, kind):
    package = DRIVERS[kind]["pacman"]
    # sudo needs a password prompt, so the install runs in a visible terminal
    # and we poll until the module becomes importable.
    command = "omarchy-pkg-add %s" % shlex.quote(package)
    launcher = shutil.which("omarchy-launch-floating-terminal-with-presentation")
    if launcher:
        subprocess.Popen([launcher, command], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    else:
        subprocess.Popen(["xdg-terminal-exec", "-e", "bash", "-c", "sudo pacman -S --needed %s; read -n1" % shlex.quote(package)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    emit({"event": "install_log", "id": req_id, "line": "Waiting for pacman to install %s in the terminal…" % package})
    deadline = time.time() + 600
    while time.time() < deadline:
        time.sleep(2)
        importlib.invalidate_caches()
        if driver_available(kind):
            return
    raise RuntimeError("Timed out waiting for %s to be installed" % package)


def install_driver(req_id, kind, method):
    if kind not in DRIVERS:
        raise ValueError("Unknown database type: %s" % kind)
    if DRIVERS[kind]["pip"] is None or driver_available(kind):
        return driver_status()
    if method == "pacman" and DRIVERS[kind]["pacman"]:
        install_pacman(req_id, kind)
    else:
        install_pip(req_id, kind)
    add_venv_to_path()
    if not driver_available(kind):
        raise RuntimeError("Installed, but '%s' still cannot be imported" % DRIVERS[kind]["module"])
    emit({"event": "install_log", "id": req_id, "line": "✓ %s ready" % DRIVERS[kind]["module"]})
    status = driver_status()
    emit({"event": "drivers", "result": status})
    return status


# ---------------------------------------------------------------------------
# Saved connections
# ---------------------------------------------------------------------------

def load_connections():
    try:
        with open(CONN_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except FileNotFoundError:
        return []


def store_connections(conns):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONN_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(conns, f, indent=2)
    os.replace(tmp, CONN_FILE)


def load_settings():
    try:
        with open(SETTINGS_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def find_connection(conn_id):
    for c in load_connections():
        if c.get("id") == conn_id:
            return c
    raise KeyError("Unknown connection: %s" % conn_id)


# ---------------------------------------------------------------------------
# Value / result helpers
# ---------------------------------------------------------------------------

def cell(v):
    if v is None or isinstance(v, bool):
        return v
    if isinstance(v, int):
        return v if abs(v) < 2 ** 53 else str(v)
    if isinstance(v, float):
        return v if v == v and v not in (float("inf"), float("-inf")) else str(v)
    if isinstance(v, (bytes, bytearray, memoryview)):
        b = bytes(v)
        try:
            s = b.decode("utf-8")
            if s.isprintable():
                return s[:MAX_CELL]
        except UnicodeDecodeError:
            pass
        return "0x" + b[:MAX_CELL // 2].hex()
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, (dict, list, tuple)):
        return json.dumps(to_jsonable(v), ensure_ascii=False, default=str)[:MAX_CELL]
    s = str(v)
    return s[:MAX_CELL]


def to_jsonable(v):
    if isinstance(v, dict):
        return {str(k): to_jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple, set)):
        return [to_jsonable(x) for x in v]
    if isinstance(v, (bytes, bytearray)):
        try:
            return bytes(v).decode("utf-8")
        except UnicodeDecodeError:
            return base64.b64encode(bytes(v)).decode()
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat()
    if isinstance(v, decimal.Decimal):
        return str(v)
    return str(v)


def result_set(columns, rows, limit, elapsed, statement=""):
    truncated = len(rows) > limit
    rows = rows[:limit]
    return {
        "columns": [str(c) for c in columns],
        "rows": [[cell(v) for v in r] for r in rows],
        "rowCount": len(rows),
        "truncated": truncated,
        "elapsedMs": round(elapsed * 1000, 1),
        "statement": statement[:200],
        "message": "",
    }


def message_result(message, elapsed, statement="", affected=None):
    return {
        "columns": [], "rows": [], "rowCount": 0, "truncated": False,
        "elapsedMs": round(elapsed * 1000, 1), "statement": statement[:200],
        "message": message, "affected": affected,
    }


# ---------------------------------------------------------------------------
# SQL script splitting
# ---------------------------------------------------------------------------

PLSQL_RE = re.compile(r"(?is)^(begin|declare|create\s+(or\s+replace\s+)?((non)?editionable\s+)?"
                      r"(procedure|function|package|trigger|type))\b")
SQLITE_TRIGGER_RE = re.compile(r"(?is)^create\s+(temp\s+|temporary\s+)?trigger\b")
DELIMITER_RE = re.compile(r"[ \t]*delimiter[ \t]+(\S+)[ \t]*(\r?\n|$)", re.I)


def strip_leading_comments(s):
    return re.sub(r"^(\s|--[^\n]*(\n|$)|/\*.*?\*/)*", "", s, flags=re.S)


def is_comment_only(stmt):
    s = re.sub(r"/\*.*?\*/", "", stmt, flags=re.S)
    s = re.sub(r"--[^\n]*", "", s)
    return not s.strip()


def split_sql(text, dialect="sql"):
    """Split a script into statements on top-level delimiters, ignoring
    quotes and comments. Understands PostgreSQL $$ bodies, MySQL
    `DELIMITER` lines, Oracle PL/SQL units ended by a '/' line and SQLite
    CREATE TRIGGER … BEGIN … END blocks."""
    if dialect == "oracle":
        out = []
        for part in re.split(r"(?m)^\s*/\s*$", text):
            out.extend(_split(part, dialect))
        return out
    return _split(text, dialect)


def _split(text, dialect):
    out, buf, i, n = [], [], 0, len(text)
    quote = dollar = None
    delim = ";"

    def flush():
        stmt = "".join(buf).strip()
        if stmt and not is_comment_only(stmt):
            out.append(stmt)
        buf.clear()

    while i < n:
        c = text[i]
        if dollar:
            if text.startswith(dollar, i):
                buf.append(dollar)
                i += len(dollar)
                dollar = None
                continue
        elif quote:
            if c == quote:
                if i + 1 < n and text[i + 1] == quote:
                    buf.append(c * 2)
                    i += 2
                    continue
                quote = None
            elif c == "\\" and quote != '"' and dialect in ("mysql", "clickhouse") and i + 1 < n:
                buf.append(text[i:i + 2])
                i += 2
                continue
        elif dialect == "mysql" and (i == 0 or text[i - 1] == "\n") and DELIMITER_RE.match(text, i):
            flush()
            m = DELIMITER_RE.match(text, i)
            delim = m.group(1)
            i = m.end()
            continue
        elif c in ("'", '"', "`"):
            quote = c
        elif c == "-" and text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            buf.append(text[i:j])
            i = j
            continue
        elif c == "/" and text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            buf.append(text[i:j])
            i = j
            continue
        elif c == "$" and dialect == "postgresql":
            m = re.match(r"\$[A-Za-z_]*\$", text[i:])
            if m:
                dollar = m.group(0)
                buf.append(dollar)
                i += len(dollar)
                continue
        elif text.startswith(delim, i):
            head = strip_leading_comments("".join(buf))
            # Bodies whose inner ';' must not split the statement.
            if (dialect == "oracle" and PLSQL_RE.match(head)) or (
                    dialect == "sqlite" and SQLITE_TRIGGER_RE.match(head)
                    and not re.search(r"(?i)\bend\s*$", "".join(buf))):
                buf.append(delim)
                i += len(delim)
                continue
            flush()
            i += len(delim)
            continue
        buf.append(c)
        i += 1
    flush()
    return out


# ---------------------------------------------------------------------------
# Tree nodes
# ---------------------------------------------------------------------------

def node(label, kind, path, leaf=False, detail="", action="", database="", ops=None, open=""):
    """One row of the schema tree.

    ops   actions offered in the UI menu: data, select, ddl, create,
          create_index, truncate, refresh, drop
    open  what a double-click does: data (editable grid), sql (run
          `action`), ddl (open the definition)"""
    return {"label": label, "kind": kind, "path": path, "leaf": leaf, "detail": detail,
            "action": action, "database": database, "ops": ops or [], "open": open}


def folder(name, path, database=""):
    """A group such as Tables or Functions; the UI translates `name`."""
    return node(name, "folder", path, database=database, ops=["create"])


def sql_result(sql, database="", confirm=False, title=""):
    return {"sql": sql, "database": database, "confirm": confirm, "title": title}


# ---------------------------------------------------------------------------
# Adapter base + SQL data editor
# ---------------------------------------------------------------------------

KEY = "__dbc_key"


class Adapter:
    dialect = "sql"
    quote_char = '"'
    editable_kinds = ("table",)

    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.RLock()

    def close(self):
        pass

    def default_database(self):
        return self.cfg.get("database") or ""

    def q(self, name):
        c = self.quote_char
        return c + str(name).replace(c, c * 2) + c

    def object_sql(self, path, op):
        raise ValueError("Not available for this object")

    def run_sql(self, conn, text, limit):
        """Run every statement of a script through a DB-API connection."""
        results = []
        for stmt in split_sql(text, self.dialect):
            t0 = time.time()
            cur = conn.cursor()
            try:
                cur.execute(stmt)
                if cur.description:
                    cols = [d[0] for d in cur.description]
                    rows = cur.fetchmany(limit + 1)
                    results.append(result_set(cols, rows, limit, time.time() - t0, stmt))
                else:
                    rc = cur.rowcount
                    msg = "OK" if rc is None or rc < 0 else "%d row(s) affected" % rc
                    results.append(message_result(msg, time.time() - t0, stmt, rc))
            finally:
                try:
                    cur.close()
                except Exception:
                    pass
        return results

    # -- data editor hooks (SQL engines) -----------------------------------
    #   columns_info(path) -> [{"name", "type", "pk"}]
    #   table_sql(path)    -> qualified name used in DML
    #   from_sql(path)     -> FROM clause of the SELECT (Oracle adds an alias)
    #   key_mode(path, info) -> ("pk", [cols]) | ("rowid", select_expr) | (None, reason)
    #   fetch(path, sql)   -> (columns, rows)
    #   param(value, type, params) -> placeholder, appending to params
    #   rowid_where(value, params)
    #   transaction(path, statements) -> affected rows

    def from_sql(self, path):
        return self.table_sql(path)

    def paginate(self, sql, offset, count):
        return "%s LIMIT %d OFFSET %d" % (sql, count, offset)

    def new_params(self):
        return []

    def col_editable(self, typ):
        return not re.search(r"blob|binary|bytea|\braw\b|bfile", typ or "", re.I)

    def update_stmt(self, table, sets, where):
        return "UPDATE %s SET %s WHERE %s" % (table, sets, where)

    def default_insert(self, table, info):
        return "INSERT INTO %s DEFAULT VALUES" % table

    def table_data(self, path, where, order, desc, offset, limit):
        t0 = time.time()
        info = self.columns_info(path)
        types = {c["name"]: c["type"] for c in info}
        if path[0] in self.editable_kinds:
            mode = self.key_mode(path, info)
        else:
            mode = (None, "Views are read-only")
        select = "*"
        if mode[0] == "rowid":
            select = mode[1] + ", " + ("t.*" if self.from_sql(path) != self.table_sql(path) else "*")
        sql = "SELECT %s FROM %s" % (select, self.from_sql(path))
        if where and where.strip():
            sql += " WHERE " + where
        if order:
            sql += " ORDER BY %s %s" % (self.q(order), "DESC" if desc else "ASC")
        cols, rows = self.fetch(path, self.paginate(sql, int(offset or 0), limit + 1))
        keys = []
        if mode[0] == "rowid":
            idx = [c.lower() for c in cols].index(KEY)
            keys = [{KEY: r[idx]} for r in rows]
            cols = cols[:idx] + cols[idx + 1:]
            rows = [tuple(r[:idx]) + tuple(r[idx + 1:]) for r in rows]
        elif mode[0] == "pk":
            idx = {c: cols.index(c) for c in mode[1] if c in cols}
            keys = [{c: r[i] for c, i in idx.items()} for r in rows]
        res = result_set(cols, rows, limit, time.time() - t0, sql)
        editable = mode[0] is not None
        res.update({
            "keys": [{k: cell(v) for k, v in key.items()} for key in keys[:limit]],
            "types": [types.get(c, "") for c in cols],
            "colEditable": [editable and self.col_editable(types.get(c, "")) for c in cols],
            "editable": editable,
            "readonlyReason": "" if editable else mode[1],
            "keyColumns": mode[1] if mode[0] == "pk" else [],
            "hasMore": len(rows) > limit,
            "offset": int(offset or 0),
        })
        return res

    def key_where(self, mode, key, types, params):
        if mode[0] == "rowid":
            return self.rowid_where(key[KEY], params)
        parts = []
        for c in mode[1]:
            v = key.get(c)
            parts.append("%s IS NULL" % self.q(c) if v is None else
                         "%s = %s" % (self.q(c), self.param(v, types.get(c, ""), params)))
        return " AND ".join(parts)

    def apply_changes(self, path, changes):
        info = self.columns_info(path)
        types = {c["name"]: c["type"] for c in info}
        mode = self.key_mode(path, info)
        if mode[0] is None:
            raise ValueError(mode[1])
        table = self.table_sql(path)
        stmts = []
        for ch in changes:
            params = self.new_params()
            op = ch.get("op")
            values = ch.get("values") or {}
            if op == "insert":
                if values:
                    cols = list(values)
                    phs = [self.param(values[c], types.get(c, ""), params) for c in cols]
                    sql = "INSERT INTO %s (%s) VALUES (%s)" % (table, ", ".join(self.q(c) for c in cols), ", ".join(phs))
                else:
                    sql = self.default_insert(table, info)
                stmts.append((sql, params, False))
            elif op == "update":
                if not values:
                    continue
                sets = ", ".join("%s = %s" % (self.q(c), self.param(v, types.get(c, ""), params)) for c, v in values.items())
                where = self.key_where(mode, ch["key"], types, params)
                stmts.append((self.update_stmt(table, sets, where), params, True))
            elif op == "delete":
                where = self.key_where(mode, ch["key"], types, params)
                stmts.append(("DELETE FROM %s WHERE %s" % (table, where), params, True))
            else:
                raise ValueError("Unknown change: %s" % op)
        affected = self.transaction(path, stmts)
        return {"applied": len(stmts), "affected": affected}

    def check_rowcount(self, cur, sql, expect):
        if expect and cur.rowcount == 0:
            raise RuntimeError("Row not found, it may have been changed or deleted meanwhile. "
                               "Nothing was saved.\n" + sql)
        return max(cur.rowcount or 0, 0)
