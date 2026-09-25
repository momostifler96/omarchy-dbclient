#!/usr/bin/env python3
"""Backend for the Omarchy DB client plugin.

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
import traceback
import uuid

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


def split_sql(text, dialect="sql"):
    """Split on top-level ';', ignoring quotes, comments and $$ bodies."""
    if dialect == "oracle" and re.search(r"(?m)^\s*/\s*$", text):
        parts = re.split(r"(?m)^\s*/\s*$", text)
        return [p.strip() for p in parts if p.strip()]
    out, buf, i, n = [], [], 0, len(text)
    quote = None
    dollar = None
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
        elif c == ";":
            stmt = "".join(buf).strip()
            if stmt and not is_comment_only(stmt):
                out.append(stmt)
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    stmt = "".join(buf).strip()
    if stmt and not is_comment_only(stmt):
        out.append(stmt)
    return out


def is_comment_only(stmt):
    s = re.sub(r"/\*.*?\*/", "", stmt, flags=re.S)
    s = re.sub(r"--[^\n]*", "", s)
    return not s.strip()


def node(label, kind, path, leaf=False, detail="", action="", database=""):
    return {"label": label, "kind": kind, "path": path, "leaf": leaf,
            "detail": detail, "action": action, "database": database}


# ---------------------------------------------------------------------------
# Adapters
# ---------------------------------------------------------------------------

class Adapter:
    dialect = "sql"

    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.RLock()

    def close(self):
        pass

    def default_database(self):
        return self.cfg.get("database") or ""

    def run_sql(self, conn, text, limit):
        """Run every statement through a DB-API connection."""
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


class SqliteAdapter(Adapter):
    dialect = "sqlite"

    def __init__(self, cfg):
        super().__init__(cfg)
        import sqlite3
        path = os.path.expanduser(cfg.get("file") or cfg.get("database") or ":memory:")
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)

    def close(self):
        self.conn.close()

    def children(self, path):
        if not path:
            rows = self.conn.execute(
                "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') "
                "AND name NOT LIKE 'sqlite_%' ORDER BY type, name").fetchall()
            return [node(n, t, ["table", n], detail=t,
                         action='SELECT * FROM "%s" LIMIT 100;' % n.replace('"', '""')) for n, t in rows]
        if path[0] == "table":
            rows = self.conn.execute('PRAGMA table_info("%s")' % path[1].replace('"', '""')).fetchall()
            return [node(r[1], "column", ["column", path[1], r[1]], leaf=True,
                         detail=(r[2] or "") + (" PK" if r[5] else "") + (" NOT NULL" if r[3] else "")) for r in rows]
        return []

    def query(self, text, database, limit):
        return self.run_sql(self.conn, text, limit)


class MysqlAdapter(Adapter):
    dialect = "mysql"

    def __init__(self, cfg):
        super().__init__(cfg)
        pymysql = require_driver("mysql")
        kwargs = dict(host=cfg.get("host") or "127.0.0.1", port=int(cfg.get("port") or 3306),
                      user=cfg.get("user") or None, password=cfg.get("password") or "",
                      database=cfg.get("database") or None, autocommit=True, connect_timeout=10,
                      charset="utf8mb4")
        if cfg.get("ssl"):
            kwargs["ssl"] = {}
        self.conn = pymysql.connect(**kwargs)

    def close(self):
        self.conn.close()

    def fetch(self, sql, args=None):
        self.conn.ping(reconnect=True)
        with self.conn.cursor() as cur:
            cur.execute(sql, args)
            return cur.fetchall()

    def children(self, path):
        q = lambda s: "`%s`" % s.replace("`", "``")
        if not path:
            return [node(r[0], "database", ["db", r[0]], database=r[0]) for r in self.fetch("SHOW DATABASES")]
        if path[0] == "db":
            rows = self.fetch("SELECT table_name, table_type, table_rows FROM information_schema.tables "
                              "WHERE table_schema=%s ORDER BY table_type, table_name", (path[1],))
            return [node(r[0], "view" if "VIEW" in r[1] else "table", ["table", path[1], r[0]],
                         detail="view" if "VIEW" in r[1] else ("~%s rows" % r[2] if r[2] is not None else ""),
                         action="SELECT * FROM %s.%s LIMIT 100;" % (q(path[1]), q(r[0])), database=path[1])
                    for r in rows]
        if path[0] == "table":
            rows = self.fetch("SELECT column_name, column_type, is_nullable, column_key FROM information_schema.columns "
                              "WHERE table_schema=%s AND table_name=%s ORDER BY ordinal_position", (path[1], path[2]))
            return [node(r[0], "column", ["column"] + path[1:] + [r[0]], leaf=True,
                         detail=r[1] + (" " + r[3] if r[3] else "") + (" NOT NULL" if r[2] == "NO" else ""),
                         database=path[1]) for r in rows]
        return []

    def query(self, text, database, limit):
        self.conn.ping(reconnect=True)
        if database:
            self.conn.select_db(database)
        return self.run_sql(self.conn, text, limit)


class PostgresAdapter(Adapter):
    dialect = "postgresql"

    def __init__(self, cfg):
        super().__init__(cfg)
        self.psycopg = require_driver("postgresql")
        self.conns = {}
        self.get(self.default_database())

    def default_database(self):
        return self.cfg.get("database") or "postgres"

    def get(self, database):
        database = database or self.default_database()
        conn = self.conns.get(database)
        if conn is not None and not conn.closed:
            return conn
        cfg = self.cfg
        conn = self.psycopg.connect(
            host=cfg.get("host") or "127.0.0.1", port=int(cfg.get("port") or 5432),
            user=cfg.get("user") or None, password=cfg.get("password") or None,
            dbname=database, connect_timeout=10, autocommit=True,
            sslmode="require" if cfg.get("ssl") else "prefer")
        self.conns[database] = conn
        return conn

    def close(self):
        for c in self.conns.values():
            try:
                c.close()
            except Exception:
                pass

    def fetch(self, database, sql, args=None):
        with self.get(database).cursor() as cur:
            cur.execute(sql, args)
            return cur.fetchall()

    def children(self, path):
        q = lambda s: '"%s"' % s.replace('"', '""')
        if not path:
            rows = self.fetch(None, "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname")
            return [node(r[0], "database", ["db", r[0]], database=r[0]) for r in rows]
        db = path[1]
        if path[0] == "db":
            rows = self.fetch(db, "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%%' "
                                  "AND nspname <> 'information_schema' ORDER BY nspname = 'public' DESC, nspname")
            return [node(r[0], "schema", ["schema", db, r[0]], database=db) for r in rows]
        if path[0] == "schema":
            rows = self.fetch(db, "SELECT c.relname, c.relkind, c.reltuples::bigint FROM pg_class c "
                                  "JOIN pg_namespace n ON n.oid = c.relnamespace "
                                  "WHERE n.nspname = %s AND c.relkind IN ('r','v','m','p','f') "
                                  "ORDER BY c.relkind, c.relname", (path[2],))
            kinds = {"r": "table", "p": "table", "f": "table", "v": "view", "m": "view"}
            return [node(r[0], kinds[r[1]], ["table", db, path[2], r[0]],
                         detail={"v": "view", "m": "materialized view"}.get(r[1], "~%d rows" % r[2] if r[2] and r[2] > 0 else ""),
                         action="SELECT * FROM %s.%s LIMIT 100;" % (q(path[2]), q(r[0])), database=db)
                    for r in rows]
        if path[0] == "table":
            rows = self.fetch(db, "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, "
                                  "EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary "
                                  "AND a.attnum = ANY(i.indkey)) "
                                  "FROM pg_attribute a WHERE a.attrelid = (quote_ident(%s) || '.' || quote_ident(%s))::regclass "
                                  "AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum", (path[2], path[3]))
            return [node(r[0], "column", ["column"] + path[1:] + [r[0]], leaf=True,
                         detail=r[1] + (" PK" if r[3] else "") + (" NOT NULL" if r[2] else ""), database=db)
                    for r in rows]
        return []

    def query(self, text, database, limit):
        return self.run_sql(self.get(database), text, limit)


class OracleAdapter(Adapter):
    dialect = "oracle"

    def __init__(self, cfg):
        super().__init__(cfg)
        oracledb = require_driver("oracle")
        dsn = cfg.get("dsn") or "%s:%s/%s" % (cfg.get("host") or "127.0.0.1", cfg.get("port") or 1521,
                                              cfg.get("database") or "FREEPDB1")
        self.conn = oracledb.connect(user=cfg.get("user"), password=cfg.get("password"), dsn=dsn,
                                     tcp_connect_timeout=10)
        self.conn.autocommit = True

    def close(self):
        self.conn.close()

    def fetch(self, sql, args=None):
        with self.conn.cursor() as cur:
            cur.execute(sql, args or {})
            return cur.fetchall()

    def children(self, path):
        q = lambda s: '"%s"' % s.replace('"', '""')
        if not path:
            me = (self.cfg.get("user") or "").upper()
            rows = self.fetch("SELECT DISTINCT owner FROM all_objects WHERE object_type IN ('TABLE','VIEW') ORDER BY owner")
            owners = [r[0] for r in rows]
            owners.sort(key=lambda o: (o != me, o))
            return [node(o, "schema", ["schema", o]) for o in owners]
        if path[0] == "schema":
            rows = self.fetch("SELECT object_name, object_type FROM all_objects WHERE owner = :o "
                              "AND object_type IN ('TABLE','VIEW') ORDER BY object_type, object_name", {"o": path[1]})
            return [node(r[0], r[1].lower(), ["table", path[1], r[0]], detail=r[1].lower(),
                         action="SELECT * FROM %s.%s FETCH FIRST 100 ROWS ONLY" % (q(path[1]), q(r[0])))
                    for r in rows]
        if path[0] == "table":
            rows = self.fetch("SELECT column_name, data_type, data_length, nullable FROM all_tab_columns "
                              "WHERE owner = :o AND table_name = :t ORDER BY column_id", {"o": path[1], "t": path[2]})
            return [node(r[0], "column", ["column", path[1], path[2], r[0]], leaf=True,
                         detail="%s(%s)%s" % (r[1], r[2], " NOT NULL" if r[3] == "N" else "")) for r in rows]
        return []

    def query(self, text, database, limit):
        stmts = split_sql(text, "oracle")
        results = []
        for stmt in stmts:
            s = stmt.strip()
            # SQL statements must not end with ';', PL/SQL blocks must.
            if not re.match(r"(?is)^(begin|declare|create\s+(or\s+replace\s+)?(procedure|function|package|trigger|type))\b", s):
                s = s.rstrip(";").rstrip()
            results.extend(self.run_sql_one(s, limit))
        return results

    def run_sql_one(self, stmt, limit):
        t0 = time.time()
        with self.conn.cursor() as cur:
            cur.execute(stmt)
            if cur.description:
                cols = [d[0] for d in cur.description]
                return [result_set(cols, cur.fetchmany(limit + 1), limit, time.time() - t0, stmt)]
            rc = cur.rowcount
            return [message_result("%d row(s) affected" % rc if rc and rc > 0 else "OK", time.time() - t0, stmt, rc)]


class ClickhouseAdapter(Adapter):
    dialect = "clickhouse"
    READ = ("SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXISTS", "EXPLAIN", "CHECK")

    def __init__(self, cfg):
        super().__init__(cfg)
        cc = require_driver("clickhouse")
        self.client = cc.get_client(host=cfg.get("host") or "127.0.0.1", port=int(cfg.get("port") or 8123),
                                    username=cfg.get("user") or "default", password=cfg.get("password") or "",
                                    database=cfg.get("database") or "", secure=bool(cfg.get("ssl")),
                                    connect_timeout=10)

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass

    def children(self, path):
        q = lambda s: "`%s`" % s.replace("`", "\\`")
        if not path:
            rows = self.client.query("SELECT name FROM system.databases ORDER BY name").result_rows
            return [node(r[0], "database", ["db", r[0]], database=r[0]) for r in rows]
        if path[0] == "db":
            rows = self.client.query("SELECT name, engine, total_rows FROM system.tables WHERE database = {d:String} "
                                     "ORDER BY name", parameters={"d": path[1]}).result_rows
            return [node(r[0], "view" if "View" in r[1] else "table", ["table", path[1], r[0]],
                         detail=r[1] + (" · %s rows" % r[2] if r[2] is not None else ""),
                         action="SELECT * FROM %s.%s LIMIT 100;" % (q(path[1]), q(r[0])), database=path[1])
                    for r in rows]
        if path[0] == "table":
            rows = self.client.query("SELECT name, type, is_in_primary_key FROM system.columns "
                                     "WHERE database = {d:String} AND table = {t:String} ORDER BY position",
                                     parameters={"d": path[1], "t": path[2]}).result_rows
            return [node(r[0], "column", ["column", path[1], path[2], r[0]], leaf=True,
                         detail=r[1] + (" PK" if r[2] else ""), database=path[1]) for r in rows]
        return []

    def query(self, text, database, limit):
        results = []
        if database:
            self.client.database = database
        for stmt in split_sql(text, "clickhouse"):
            t0 = time.time()
            first = re.sub(r"^(\s|--[^\n]*\n|/\*.*?\*/)*", "", stmt, flags=re.S).split(None, 1)
            verb = first[0].upper() if first else ""
            if verb == "USE" and len(first) > 1:
                self.client.database = first[1].strip().strip("`\"")
                results.append(message_result("Database changed to %s" % self.client.database, time.time() - t0, stmt))
                continue
            if verb in self.READ:
                r = self.client.query(stmt, settings={"max_result_rows": limit + 1, "result_overflow_mode": "break"})
                results.append(result_set(r.column_names, list(r.result_rows), limit, time.time() - t0, stmt))
            else:
                out = self.client.command(stmt)
                summary = getattr(out, "summary", None) or {}
                msg = "OK"
                if isinstance(summary, dict) and summary.get("written_rows"):
                    msg = "%s row(s) written" % summary["written_rows"]
                elif isinstance(out, (str, int)) and out != "":
                    msg = str(out)
                results.append(message_result(msg, time.time() - t0, stmt))
        return results


class RedisAdapter(Adapter):
    dialect = "redis"

    def __init__(self, cfg):
        super().__init__(cfg)
        self.redis = require_driver("redis")
        self.clients = {}
        self.get(int(cfg.get("database") or 0)).ping()

    def default_database(self):
        return str(self.cfg.get("database") or "0")

    def get(self, db):
        db = int(db or 0)
        if db not in self.clients:
            cfg = self.cfg
            if cfg.get("uri"):
                self.clients[db] = self.redis.Redis.from_url(cfg["uri"], db=db, socket_connect_timeout=10)
            else:
                self.clients[db] = self.redis.Redis(
                    host=cfg.get("host") or "127.0.0.1", port=int(cfg.get("port") or 6379), db=db,
                    username=cfg.get("user") or None, password=cfg.get("password") or None,
                    ssl=bool(cfg.get("ssl")), socket_connect_timeout=10)
        return self.clients[db]

    def close(self):
        for c in self.clients.values():
            try:
                c.close()
            except Exception:
                pass

    @staticmethod
    def quote(s):
        return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"') if re.search(r'[\s"\'\\]', s) or not s else s

    def children(self, path):
        if not path:
            client = self.get(0)
            try:
                keyspace = client.info("keyspace")
            except Exception:
                # INFO can be disabled by ACLs or proxies: show the configured db only.
                db = int(self.cfg.get("database") or 0)
                return [node("db%d" % db, "database", ["db", str(db)],
                             detail="%d keys" % self.get(db).dbsize(), database=str(db))]
            try:
                count = int(client.config_get("databases").get("databases", 16))
            except Exception:
                count = 16
            out = []
            for i in range(count):
                info = keyspace.get("db%d" % i)
                if info or i == 0 or i == int(self.cfg.get("database") or 0):
                    keys = info.get("keys", 0) if isinstance(info, dict) else 0
                    out.append(node("db%d" % i, "database", ["db", str(i)], detail="%d keys" % keys, database=str(i)))
            return out
        if path[0] == "db":
            client = self.get(path[1])
            pattern = path[2] if len(path) > 2 else "*"
            keys = []
            for k in client.scan_iter(match=pattern, count=500):
                keys.append(k)
                if len(keys) >= 1000:
                    break
            keys.sort()
            pipe = client.pipeline()
            for k in keys:
                pipe.type(k)
            types = pipe.execute() if keys else []
            out = []
            for k, t in zip(keys, types):
                name = k.decode("utf-8", "replace")
                t = t.decode() if isinstance(t, bytes) else str(t)
                qk = self.quote(name)
                action = {"string": "GET %s", "hash": "HGETALL %s", "list": "LRANGE %s 0 99",
                          "set": "SSCAN %s 0 COUNT 100", "zset": "ZRANGE %s 0 99 WITHSCORES",
                          "stream": "XRANGE %s - + COUNT 100"}.get(t, "TYPE %s") % qk
                out.append(node(name, "key", ["key", path[1], name], leaf=True, detail=t, action=action,
                                database=path[1]))
            if len(keys) >= 1000:
                out.append(node("… first 1000 keys (use SCAN to see more)", "info", ["info"], leaf=True))
            return out
        return []

    def query(self, text, database, limit):
        client = self.get(database or self.default_database())
        results = []
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            t0 = time.time()
            argv = shlex.split(line)
            if argv[0].upper() == "SELECT" and len(argv) == 2:
                database = argv[1]
                client = self.get(database)
                results.append(message_result("OK (db%s)" % database, time.time() - t0, line))
                continue
            reply = client.execute_command(*argv)
            results.append(self.reply_to_result(argv, reply, limit, time.time() - t0, line))
        return results

    def reply_to_result(self, argv, reply, limit, elapsed, line):
        cmd = argv[0].upper()
        dec = lambda v: v.decode("utf-8", "replace") if isinstance(v, bytes) else v
        if isinstance(reply, dict):
            return result_set(["field", "value"], [[dec(k), dec(v)] for k, v in reply.items()], limit, elapsed, line)
        if isinstance(reply, (list, tuple, set)):
            items = list(reply)
            if cmd in ("SCAN", "SSCAN", "HSCAN", "ZSCAN") and len(items) == 2 and isinstance(items[1], (list, dict)):
                cursor, items = dec(items[0]), items[1]
                if isinstance(items, dict):
                    return result_set(["field", "value"], [[dec(k), dec(v)] for k, v in items.items()], limit, elapsed,
                                      line + "  (next cursor %s)" % cursor)
                if cmd == "HSCAN":
                    items = list(items)
                    return result_set(["field", "value"], [[dec(items[i]), dec(items[i + 1])] for i in range(0, len(items) - 1, 2)],
                                      limit, elapsed, line + "  (next cursor %s)" % cursor)
            if cmd == "ZRANGE" and "WITHSCORES" in [a.upper() for a in argv] and items and isinstance(items[0], (list, tuple)):
                return result_set(["member", "score"], [[dec(m), s] for m, s in items], limit, elapsed, line)
            if cmd == "XRANGE" or cmd == "XREVRANGE":
                return result_set(["id", "fields"], [[dec(i), {dec(k): dec(v) for k, v in f.items()}] for i, f in items],
                                  limit, elapsed, line)
            return result_set(["#", "value"], [[i + 1, dec(v) if not isinstance(v, (list, tuple)) else to_jsonable(v)]
                                               for i, v in enumerate(items)], limit, elapsed, line)
        if cmd == "INFO" and isinstance(reply, dict):
            return result_set(["key", "value"], list(reply.items()), limit, elapsed, line)
        return result_set(["result"], [[dec(reply)]], limit, elapsed, line)


# --- MongoDB -----------------------------------------------------------------

class JsParser:
    """Tolerant parser for mongosh-style literals: unquoted keys, single
    quotes, trailing commas, ObjectId(), ISODate(), /regex/ ..."""

    def __init__(self, text, bson):
        self.s, self.i, self.bson = text, 0, bson

    def error(self, msg):
        raise ValueError("%s at position %d: …%s" % (msg, self.i, self.s[self.i:self.i + 30]))

    def ws(self):
        while self.i < len(self.s):
            if self.s[self.i].isspace():
                self.i += 1
            elif self.s.startswith("//", self.i):
                j = self.s.find("\n", self.i)
                self.i = len(self.s) if j < 0 else j
            elif self.s.startswith("/*", self.i):
                j = self.s.find("*/", self.i)
                self.i = len(self.s) if j < 0 else j + 2
            else:
                break

    def peek(self):
        self.ws()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.error("Expected '%s'" % ch)
        self.i += 1

    def ident(self):
        self.ws()
        m = re.compile(r"[A-Za-z_$][\w$]*").match(self.s, self.i)
        if not m:
            self.error("Expected identifier")
        self.i = m.end()
        return m.group(0)

    def string(self):
        q = self.s[self.i]
        self.i += 1
        out = []
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == "\\":
                nxt = self.s[self.i + 1:self.i + 2]
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                self.i += 2
                continue
            if c == q:
                self.i += 1
                return "".join(out)
            out.append(c)
            self.i += 1
        self.error("Unterminated string")

    def args(self):
        """Parse '(a, b, …)'; the opening paren is the next char."""
        self.expect("(")
        out = []
        while self.peek() != ")":
            out.append(self.value())
            if self.peek() == ",":
                self.i += 1
            elif self.peek() != ")":
                self.error("Expected ',' or ')'")
        self.i += 1
        return out

    def value(self):
        c = self.peek()
        if c == "{":
            self.i += 1
            obj = {}
            while self.peek() != "}":
                k = self.string() if self.peek() in "'\"" else self.key()
                self.expect(":")
                obj[k] = self.value()
                if self.peek() == ",":
                    self.i += 1
                elif self.peek() != "}":
                    self.error("Expected ',' or '}'")
            self.i += 1
            return obj
        if c == "[":
            self.i += 1
            arr = []
            while self.peek() != "]":
                arr.append(self.value())
                if self.peek() == ",":
                    self.i += 1
                elif self.peek() != "]":
                    self.error("Expected ',' or ']'")
            self.i += 1
            return arr
        if c in "'\"":
            return self.string()
        if c == "/":
            j = self.i + 1
            while j < len(self.s) and self.s[j] != "/":
                j += 2 if self.s[j] == "\\" else 1
            pattern = self.s[self.i + 1:j]
            m = re.compile(r"[imxs]*").match(self.s, j + 1)
            self.i = m.end()
            return self.bson.regex.Regex(pattern, m.group(0))
        m = re.compile(r"-?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?").match(self.s, self.i)
        if m:
            self.i = m.end()
            t = m.group(0)
            return float(t) if any(x in t for x in ".eE") else int(t)
        word = self.ident()
        if word == "new":
            word = self.ident()
        lits = {"true": True, "false": False, "null": None, "undefined": None}
        if word in lits:
            return lits[word]
        if self.peek() != "(":
            self.error("Unknown identifier '%s'" % word)
        a = self.args()
        if word == "ObjectId":
            return self.bson.ObjectId(a[0]) if a else self.bson.ObjectId()
        if word in ("ISODate", "Date"):
            if not a:
                return datetime.datetime.now(datetime.timezone.utc)
            if isinstance(a[0], (int, float)):
                return datetime.datetime.fromtimestamp(a[0] / 1000, datetime.timezone.utc)
            return datetime.datetime.fromisoformat(str(a[0]).replace("Z", "+00:00"))
        if word in ("NumberLong", "NumberInt", "Int32", "Long"):
            return int(a[0])
        if word in ("NumberDecimal", "Decimal128"):
            return self.bson.decimal128.Decimal128(str(a[0]))
        if word == "UUID":
            return uuid.UUID(str(a[0]))
        self.error("Unsupported constructor '%s'" % word)

    def key(self):
        self.ws()
        m = re.compile(r"[\w$.]+").match(self.s, self.i)
        if not m:
            self.error("Expected key")
        self.i = m.end()
        return m.group(0)


class MongoAdapter(Adapter):
    dialect = "mongodb"
    CALL = re.compile(r"\s*db\s*\.\s*(?:getCollection\(\s*(['\"])(?P<q>.+?)\1\s*\)|(?P<c>[\w$-]+(?:\.[\w$-]+)*?))\s*\.\s*(?P<m>\w+)\s*(?=\()", re.S)

    def __init__(self, cfg):
        super().__init__(cfg)
        self.pymongo = require_driver("mongodb")
        import bson
        self.bson = bson
        opts = dict(serverSelectionTimeoutMS=8000, connectTimeoutMS=10000)
        if cfg.get("uri"):
            self.client = self.pymongo.MongoClient(cfg["uri"], **opts)
        else:
            if cfg.get("user"):
                opts.update(username=cfg["user"], password=cfg.get("password") or "",
                            authSource=cfg.get("authSource") or "admin")
            if cfg.get("ssl"):
                opts["tls"] = True
            self.client = self.pymongo.MongoClient(cfg.get("host") or "127.0.0.1", int(cfg.get("port") or 27017), **opts)
        self.client.admin.command("ping")

    def default_database(self):
        if self.cfg.get("database"):
            return self.cfg["database"]
        try:
            return self.client.get_default_database().name
        except Exception:
            return "test"

    def close(self):
        self.client.close()

    def children(self, path):
        if not path:
            return [node(n, "database", ["db", n], database=n) for n in sorted(self.client.list_database_names())]
        if path[0] == "db":
            names = sorted(self.client[path[1]].list_collection_names())
            return [node(n, "collection", ["coll", path[1], n], database=path[1],
                         action="db.getCollection(%s).find({}).limit(100)" % json.dumps(n)) for n in names]
        if path[0] == "coll":
            coll = self.client[path[1]][path[2]]
            out = []
            for name, spec in coll.index_information().items():
                keys = ", ".join("%s:%s" % (k, v) for k, v in spec.get("key", []))
                out.append(node(name, "index", ["index", path[1], path[2], name], leaf=True, detail=keys,
                                database=path[1]))
            return out
        return []

    def docs_result(self, docs, limit, elapsed, statement):
        docs = list(docs)
        cols = []
        seen = set()
        for d in docs[:limit]:
            if not isinstance(d, dict):
                d = {"value": d}
            for k in d.keys():
                if k not in seen:
                    seen.add(k)
                    cols.append(k)
        if "_id" in seen:
            cols.remove("_id")
            cols.insert(0, "_id")
        rows = []
        for d in docs:
            if not isinstance(d, dict):
                d = {"value": d}
            rows.append([d.get(c) for c in cols])
        res = result_set(cols, rows, limit, elapsed, statement)
        res["documents"] = [json.dumps(to_jsonable(d), ensure_ascii=False, default=str) for d in docs[:limit]]
        return res

    def query(self, text, database, limit):
        db = self.client[database or self.default_database()]
        results = []
        for stmt in self.split(text):
            t0 = time.time()
            s = stmt.strip()
            low = s.lower()
            if low in ("show dbs", "show databases"):
                rows = [[d["name"], d.get("sizeOnDisk")] for d in self.client.list_databases()]
                results.append(result_set(["name", "sizeOnDisk"], rows, limit, time.time() - t0, s))
                continue
            if low in ("show collections", "show tables", "db.getcollectionnames()"):
                results.append(result_set(["name"], [[n] for n in sorted(db.list_collection_names())], limit, time.time() - t0, s))
                continue
            if low.startswith("use "):
                db = self.client[s[4:].strip()]
                results.append(message_result("switched to db %s" % db.name, time.time() - t0, s))
                continue
            m = re.match(r"\s*db\s*\.\s*(runCommand|adminCommand)\s*(?=\()", s)
            if m:
                p = JsParser(s, self.bson)
                p.i = m.end()
                a = p.args()
                target = self.client.admin if m.group(1) == "adminCommand" else db
                reply = target.command(a[0] if isinstance(a[0], dict) else {a[0]: 1})
                results.append(self.docs_result([reply], limit, time.time() - t0, s))
                continue
            m = self.CALL.match(s)
            if not m:
                raise ValueError("Unsupported statement. Use e.g. db.users.find({age: {$gt: 18}}).limit(20), "
                                 "show collections, use <db>, db.runCommand({...})")
            coll = db[m.group("q") or m.group("c")]
            p = JsParser(s, self.bson)
            p.i = m.end()
            method = m.group("m")
            args = p.args()
            chain = []
            while p.peek() == ".":
                p.i += 1
                name = p.ident()
                chain.append((name, p.args()))
            if p.peek() == ";":
                p.i += 1
            if p.peek():
                p.error("Unexpected text")
            results.append(self.run_method(coll, method, args, chain, limit, time.time, t0, s))
        return results

    @staticmethod
    def split(text):
        """Statements are separated by ';' or by a newline that starts a new
        top-level 'db.'/'show'/'use' line."""
        out, buf, depth, quote = [], [], 0, None
        i = 0
        while i < len(text):
            c = text[i]
            if quote:
                if c == "\\":
                    buf.append(text[i:i + 2])
                    i += 2
                    continue
                if c == quote:
                    quote = None
            elif c in "'\"":
                quote = c
            elif c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == ";" and depth == 0:
                out.append("".join(buf))
                buf = []
                i += 1
                continue
            elif c == "\n" and depth == 0 and re.match(r"\s*(db\.|show\s|use\s)", text[i + 1:]) and "".join(buf).strip():
                out.append("".join(buf))
                buf = []
                i += 1
                continue
            buf.append(c)
            i += 1
        out.append("".join(buf))
        return [s for s in (x.strip() for x in out) if s and not s.startswith("//")]

    def run_method(self, coll, method, args, chain, limit, clock, t0, stmt):
        a = lambda i, default=None: args[i] if len(args) > i else default
        if method in ("find", "aggregate"):
            if method == "find":
                cur = coll.find(a(0, {}), a(1))
            else:
                cur = coll.aggregate(a(0, []), **(a(1) or {}))
            n = limit
            for name, cargs in chain:
                if method == "find" and name == "sort":
                    spec = cargs[0]
                    cur = cur.sort(list(spec.items()) if isinstance(spec, dict) else spec)
                elif method == "find" and name == "skip":
                    cur = cur.skip(int(cargs[0]))
                elif name == "limit":
                    n = min(int(cargs[0]), limit)
                elif method == "find" and name == "projection":
                    raise ValueError("Pass the projection as the second argument of find()")
                elif name in ("toArray", "pretty"):
                    pass
                elif name in ("count", "itcount"):
                    return result_set(["count"], [[sum(1 for _ in cur)]], limit, clock() - t0, stmt)
                else:
                    raise ValueError("Unsupported cursor method: %s" % name)
            if method == "find":
                cur = cur.limit(n + 1 if n == limit else n)
            docs = []
            for d in cur:
                docs.append(d)
                if len(docs) > n:
                    break
            return self.docs_result(docs, n, clock() - t0, stmt)
        if method == "findOne":
            d = coll.find_one(a(0, {}), a(1))
            return self.docs_result([d] if d else [], limit, clock() - t0, stmt)
        if method in ("countDocuments", "count"):
            return result_set(["count"], [[coll.count_documents(a(0, {}))]], limit, clock() - t0, stmt)
        if method == "estimatedDocumentCount":
            return result_set(["count"], [[coll.estimated_document_count()]], limit, clock() - t0, stmt)
        if method == "distinct":
            return result_set([args[0]], [[v] for v in coll.distinct(args[0], a(1, {}))], limit, clock() - t0, stmt)
        if method == "insertOne":
            r = coll.insert_one(args[0])
            return message_result("Inserted _id %s" % r.inserted_id, clock() - t0, stmt, 1)
        if method == "insertMany":
            r = coll.insert_many(args[0])
            return message_result("Inserted %d document(s)" % len(r.inserted_ids), clock() - t0, stmt, len(r.inserted_ids))
        if method in ("updateOne", "updateMany", "replaceOne"):
            fn = {"updateOne": coll.update_one, "updateMany": coll.update_many, "replaceOne": coll.replace_one}[method]
            r = fn(args[0], args[1], **(a(2) or {}))
            return message_result("Matched %d, modified %d%s" % (r.matched_count, r.modified_count,
                                  ", upserted %s" % r.upserted_id if r.upserted_id else ""), clock() - t0, stmt, r.modified_count)
        if method in ("deleteOne", "deleteMany"):
            r = (coll.delete_one if method == "deleteOne" else coll.delete_many)(a(0, {}))
            return message_result("Deleted %d document(s)" % r.deleted_count, clock() - t0, stmt, r.deleted_count)
        if method == "getIndexes":
            return self.docs_result([dict(v, name=k) for k, v in coll.index_information().items()], limit, clock() - t0, stmt)
        if method == "createIndex":
            spec = args[0]
            name = coll.create_index(list(spec.items()) if isinstance(spec, dict) else spec, **(a(1) or {}))
            return message_result("Created index %s" % name, clock() - t0, stmt)
        if method == "drop":
            coll.drop()
            return message_result("Dropped %s" % coll.name, clock() - t0, stmt)
        raise ValueError("Unsupported collection method: %s" % method)


ADAPTERS = {
    "sqlite": SqliteAdapter, "mysql": MysqlAdapter, "postgresql": PostgresAdapter, "oracle": OracleAdapter,
    "clickhouse": ClickhouseAdapter, "redis": RedisAdapter, "mongodb": MongoAdapter,
}


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

class Server:
    def __init__(self):
        self.sessions = {}
        self.sessions_lock = threading.Lock()

    def open_adapter(self, cfg):
        kind = cfg.get("type")
        if kind not in ADAPTERS:
            raise ValueError("Unknown database type: %s" % kind)
        require_driver(kind)
        return ADAPTERS[kind](cfg)

    def session(self, conn_id):
        with self.sessions_lock:
            s = self.sessions.get(conn_id)
        if s:
            return s
        s = self.open_adapter(find_connection(conn_id))
        with self.sessions_lock:
            old = self.sessions.get(conn_id)
            if old:
                s.close()
                return old
            self.sessions[conn_id] = s
        return s

    def drop_session(self, conn_id):
        with self.sessions_lock:
            s = self.sessions.pop(conn_id, None)
        if s:
            try:
                s.close()
            except Exception:
                pass

    # -- commands -----------------------------------------------------------

    def cmd_hello(self, req):
        try:
            with open(STATE_FILE) as f:
                state = json.load(f)
        except (FileNotFoundError, ValueError):
            state = {}
        return {"version": 1, "settings": load_settings(), "state": state, **driver_status()}

    def cmd_save_state(self, req):
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(req.get("state") or {}, f)
        os.replace(tmp, STATE_FILE)
        return True

    def cmd_set_settings(self, req):
        settings = dict(load_settings(), **(req.get("settings") or {}))
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w") as f:
            json.dump(settings, f, indent=2)
        return settings

    def cmd_drivers(self, req):
        return driver_status()

    def cmd_install_driver(self, req):
        return install_driver(req.get("id"), req["type"], req.get("method") or "pip")

    def cmd_list_connections(self, req):
        conns = load_connections()
        with self.sessions_lock:
            live = set(self.sessions)
        return [dict(c, connected=c.get("id") in live) for c in conns]

    def cmd_save_connection(self, req):
        cfg = dict(req["connection"])
        cfg.pop("connected", None)
        conns = load_connections()
        if not cfg.get("id"):
            cfg["id"] = uuid.uuid4().hex[:12]
            conns.append(cfg)
        else:
            conns = [cfg if c.get("id") == cfg["id"] else c for c in conns]
            if not any(c.get("id") == cfg["id"] for c in conns):
                conns.append(cfg)
            self.drop_session(cfg["id"])
        store_connections(conns)
        return cfg

    def cmd_delete_connection(self, req):
        self.drop_session(req["connId"])
        store_connections([c for c in load_connections() if c.get("id") != req["connId"]])
        return True

    def cmd_test_connection(self, req):
        t0 = time.time()
        adapter = self.open_adapter(req["connection"])
        try:
            children = adapter.children([])
        finally:
            adapter.close()
        return {"elapsedMs": round((time.time() - t0) * 1000), "objects": len(children)}

    def cmd_connect(self, req):
        s = self.session(req["connId"])
        return {"defaultDatabase": s.default_database(), "dialect": s.dialect}

    def cmd_disconnect(self, req):
        self.drop_session(req["connId"])
        return True

    def cmd_children(self, req):
        s = self.session(req["connId"])
        with s.lock:
            return s.children(req.get("path") or [])

    def cmd_query(self, req):
        s = self.session(req["connId"])
        limit = max(1, min(int(req.get("limit") or 1000), 100000))
        t0 = time.time()
        with s.lock:
            try:
                results = s.query(req.get("text") or "", req.get("database") or "", limit)
            except Exception as e:
                # A dead socket: reconnect once and retry.
                if not is_connection_error(e):
                    raise
                self.drop_session(req["connId"])
                s = self.session(req["connId"])
                results = s.query(req.get("text") or "", req.get("database") or "", limit)
        return {"results": results, "elapsedMs": round((time.time() - t0) * 1000, 1)}

    def cmd_write_file(self, req):
        path = os.path.expanduser(req["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(req.get("content") or "")
        return path

    # -- dispatch -----------------------------------------------------------

    def handle(self, req):
        rid = req.get("id")
        fn = getattr(self, "cmd_" + str(req.get("cmd")), None)
        try:
            if fn is None:
                raise ValueError("Unknown command: %s" % req.get("cmd"))
            emit({"id": rid, "ok": True, "result": fn(req)})
        except Exception as e:
            err = {"id": rid, "ok": False, "error": friendly_error(e)}
            if getattr(e, "code", None) == "driver_missing":
                err["code"] = "driver_missing"
                err["type"] = e.kind
            else:
                err["trace"] = traceback.format_exc(limit=4)
            emit(err)

    def serve(self):
        add_venv_to_path()
        workers = []
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except ValueError as e:
                emit({"id": None, "ok": False, "error": "Bad request: %s" % e})
                continue
            t = threading.Thread(target=self.handle, args=(req,))
            t.start()
            workers.append(t)
            workers[:] = [w for w in workers if w.is_alive()]
        # stdin closed: let in-flight requests reply before exiting.
        for t in workers:
            t.join()


def is_connection_error(e):
    name = type(e).__name__
    msg = str(e).lower()
    return name in ("OperationalError", "InterfaceError", "ConnectionError", "AutoReconnect") and (
        "lost connection" in msg or "closed" in msg or "broken pipe" in msg or "gone away" in msg
        or "connection reset" in msg or "terminat" in msg)


def friendly_error(e):
    msg = str(e).strip() or type(e).__name__
    if isinstance(e, KeyError) and e.args:
        msg = str(e.args[0])
    return "%s: %s" % (type(e).__name__, msg) if type(e).__name__ not in ("RuntimeError", "ValueError", "KeyError") else msg


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "drivers":
        print(json.dumps(driver_status(), indent=2))
    else:
        Server().serve()
