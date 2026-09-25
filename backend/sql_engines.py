"""SQL engines: SQLite, MySQL/MariaDB, PostgreSQL, Oracle, ClickHouse.

Each adapter provides the schema tree (children), object scripts (DDL,
templates, DROP …) and the hooks of the data editor defined in core.Adapter.
"""

import datetime
import decimal
import re
import time

from core import (Adapter, KEY, folder, message_result, node, require_driver, result_set,
                  split_sql, sql_result)

TABLE_OPS = ["data", "select", "ddl", "create_index", "truncate", "drop"]
VIEW_OPS = ["data", "select", "ddl", "drop"]
CODE_OPS = ["ddl", "drop"]


def db_api_fetch(cur, sql, params=None):
    cur.execute(sql, params) if params is not None else cur.execute(sql)
    cols = [d[0] for d in cur.description] if cur.description else []
    return cols, cur.fetchall() if cols else []


# ---------------------------------------------------------------------------
# SQLite
# ---------------------------------------------------------------------------

class SqliteAdapter(Adapter):
    dialect = "sqlite"
    FOLDERS = ["tables", "views", "indexes", "triggers"]
    KINDS = {"tables": "table", "views": "view", "indexes": "index", "triggers": "trigger"}

    def __init__(self, cfg):
        super().__init__(cfg)
        import os
        import sqlite3
        path = os.path.expanduser(cfg.get("file") or cfg.get("database") or ":memory:")
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)

    def close(self):
        self.conn.close()

    def fetch(self, path, sql, params=None):
        return db_api_fetch(self.conn.cursor(), sql, params)

    def object_node(self, kind, name, table=""):
        q = self.q(name)
        if kind == "table":
            return node(name, "table", ["table", name], action="SELECT * FROM %s LIMIT 100;" % q,
                        ops=TABLE_OPS, open="data")
        if kind == "view":
            return node(name, "view", ["view", name], action="SELECT * FROM %s LIMIT 100;" % q,
                        ops=VIEW_OPS, open="data")
        return node(name, kind, [kind, name], leaf=True, detail="on " + table, ops=CODE_OPS, open="ddl")

    def children(self, path):
        if not path:
            return [folder(f, ["folder", f]) for f in self.FOLDERS]
        if path[0] == "folder":
            kind = self.KINDS[path[1]]
            _, rows = self.fetch(path, "SELECT name, tbl_name FROM sqlite_master WHERE type = ? "
                                       "AND name NOT LIKE 'sqlite_%' ORDER BY name", (kind,))
            return [self.object_node(kind, n, t) for n, t in rows]
        if path[0] in ("table", "view"):
            return [node(c["name"], "column", ["column", path[1], c["name"]], leaf=True,
                         detail=(c["type"] or "") + (" PK" if c["pk"] else "") + (" NOT NULL" if c["notnull"] else ""))
                    for c in self.columns_info(path)]
        return []

    def definition(self, name):
        _, rows = self.fetch(None, "SELECT sql FROM sqlite_master WHERE name = ?", (name,))
        if not rows or not rows[0][0]:
            raise ValueError("No definition for %s" % name)
        return rows[0][0].strip().rstrip(";") + ";"

    def object_sql(self, path, op):
        if path[0] == "folder" and op == "create":
            return sql_result(self.TEMPLATES[path[1]], title="new " + self.KINDS[path[1]])
        kind, name = path[0], path[1]
        q = self.q(name)
        if op == "ddl":
            sql = self.definition(name)
            if kind in ("view", "trigger"):
                sql = "DROP %s IF EXISTS %s;\n%s" % (kind.upper(), q, sql)
            elif kind == "table":
                sql = "-- Definition of %s (SQLite changes tables with ALTER TABLE)\n%s" % (name, sql)
            return sql_result(sql + "\n", title=name)
        if op == "drop":
            return sql_result("DROP %s %s;" % (kind.upper(), q), confirm=True)
        if op == "truncate":
            return sql_result("DELETE FROM %s;" % q, confirm=True)
        if op == "create_index":
            return sql_result("CREATE INDEX idx_%s_column ON %s (column_name);" % (name, q), title="new index")
        return super().object_sql(path, op)

    TEMPLATES = {
        "tables": "CREATE TABLE new_table (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  name TEXT NOT NULL,\n"
                  "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP\n);\n",
        "views": "CREATE VIEW new_view AS\nSELECT 1 AS example;\n",
        "indexes": "CREATE INDEX idx_table_column ON table_name (column_name);\n",
        "triggers": "CREATE TRIGGER trg_table_updated\nAFTER UPDATE ON table_name\nFOR EACH ROW\nBEGIN\n"
                    "  UPDATE table_name SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;\nEND;\n",
    }

    # -- data editor ----------------------------------------------------------
    def columns_info(self, path):
        _, rows = self.fetch(path, 'PRAGMA table_info(%s)' % self.q(path[1]))
        return [{"name": r[1], "type": r[2] or "", "pk": r[5], "notnull": bool(r[3])} for r in rows]

    def table_sql(self, path):
        return self.q(path[1])

    def key_mode(self, path, info):
        pk = [c["name"] for c in sorted((c for c in info if c["pk"]), key=lambda c: c["pk"])]
        if pk:
            return ("pk", pk)
        if "WITHOUT ROWID" in self.definition(path[1]).upper():
            return (None, "WITHOUT ROWID table without a primary key: read-only")
        return ("rowid", 'rowid AS "%s"' % KEY)

    def param(self, value, typ, params):
        params.append(value)
        return "?"

    def rowid_where(self, value, params):
        params.append(value)
        return "rowid = ?"

    def transaction(self, path, stmts):
        cur = self.conn.cursor()
        cur.execute("BEGIN")
        try:
            total = 0
            for sql, params, expect in stmts:
                cur.execute(sql, params)
                total += self.check_rowcount(cur, sql, expect)
            cur.execute("COMMIT")
            return total
        except Exception:
            cur.execute("ROLLBACK")
            raise

    def query(self, text, database, limit):
        return self.run_sql(self.conn, text, limit)


# ---------------------------------------------------------------------------
# MySQL / MariaDB
# ---------------------------------------------------------------------------

class MysqlAdapter(Adapter):
    dialect = "mysql"
    quote_char = "`"
    FOLDERS = ["tables", "views", "functions", "procedures", "triggers", "events"]
    WORDS = {"table": "TABLE", "view": "VIEW", "function": "FUNCTION", "procedure": "PROCEDURE",
             "trigger": "TRIGGER", "event": "EVENT"}

    def __init__(self, cfg):
        super().__init__(cfg)
        pymysql = require_driver("mysql")
        from pymysql.constants import CLIENT
        kwargs = dict(host=cfg.get("host") or "127.0.0.1", port=int(cfg.get("port") or 3306),
                      user=cfg.get("user") or None, password=cfg.get("password") or "",
                      database=cfg.get("database") or None, autocommit=True, connect_timeout=10,
                      charset="utf8mb4", client_flag=CLIENT.FOUND_ROWS)
        if cfg.get("ssl"):
            kwargs["ssl"] = {}
        self.conn = pymysql.connect(**kwargs)

    def close(self):
        self.conn.close()

    def fetch(self, path, sql, params=None):
        self.conn.ping(reconnect=True)
        with self.conn.cursor() as cur:
            return db_api_fetch(cur, sql, params)

    def rows(self, sql, params=None):
        return self.fetch(None, sql, params)[1]

    def full(self, db, name):
        return "%s.%s" % (self.q(db), self.q(name))

    def children(self, path):
        if not path:
            return [node(r[0], "database", ["db", r[0]], database=r[0], ops=["drop"])
                    for r in self.rows("SHOW DATABASES")]
        if path[0] == "db":
            return [folder(f, ["folder", path[1], f], database=path[1]) for f in self.FOLDERS]
        if path[0] == "folder":
            return self.folder_children(path[1], path[2])
        if path[0] in ("table", "view"):
            d, t = path[1], path[2]
            out = [node(c["name"], "column", ["column", d, t, c["name"]], leaf=True, database=d,
                        detail=c["type"] + (" " + c["key"] if c["key"] else "") + ("" if c["nullable"] else " NOT NULL"))
                   for c in self.columns_info(path)]
            if path[0] == "table":
                for name, unique, cols in self.indexes(d, t):
                    out.append(node(name, "index", ["index", d, t, name], leaf=True, database=d,
                                    detail=("unique " if unique else "") + "(" + cols + ")", ops=CODE_OPS, open="ddl"))
            return out
        return []

    def folder_children(self, d, f):
        if f in ("tables", "views"):
            rows = self.rows("SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema = %s "
                             "AND table_type " + ("= 'BASE TABLE'" if f == "tables" else "= 'VIEW'") +
                             " ORDER BY table_name", (d,))
            kind = f[:-1]
            return [node(n, kind, [kind, d, n], database=d, open="data",
                         detail="~%s rows" % r if kind == "table" and r is not None else "",
                         action="SELECT * FROM %s LIMIT 100;" % self.full(d, n),
                         ops=TABLE_OPS if kind == "table" else VIEW_OPS) for n, r in rows]
        if f in ("functions", "procedures"):
            rows = self.rows("SELECT routine_name, dtd_identifier FROM information_schema.routines "
                             "WHERE routine_schema = %s AND routine_type = %s ORDER BY routine_name",
                             (d, f[:-1].upper()))
            return [node(n, f[:-1], [f[:-1], d, n], leaf=True, database=d, detail="→ " + r if r else "",
                         ops=CODE_OPS, open="ddl") for n, r in rows]
        if f == "triggers":
            rows = self.rows("SELECT trigger_name, action_timing, event_manipulation, event_object_table "
                             "FROM information_schema.triggers WHERE trigger_schema = %s ORDER BY trigger_name", (d,))
            return [node(n, "trigger", ["trigger", d, n], leaf=True, database=d,
                         detail="%s %s on %s" % (tm.lower(), ev.lower(), t), ops=CODE_OPS, open="ddl")
                    for n, tm, ev, t in rows]
        if f == "events":
            rows = self.rows("SELECT event_name, status FROM information_schema.events WHERE event_schema = %s "
                             "ORDER BY event_name", (d,))
            return [node(n, "event", ["event", d, n], leaf=True, database=d, detail=st.lower(),
                         ops=CODE_OPS, open="ddl") for n, st in rows]
        return []

    def indexes(self, d, t):
        return self.rows("SELECT index_name, MIN(non_unique) = 0, GROUP_CONCAT(column_name ORDER BY seq_in_index) "
                         "FROM information_schema.statistics WHERE table_schema = %s AND table_name = %s "
                         "GROUP BY index_name ORDER BY index_name = 'PRIMARY' DESC, index_name", (d, t))

    def object_sql(self, path, op):
        if not path and op == "create":
            return sql_result("CREATE DATABASE new_database\n  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n",
                              title="new database")
        kind = path[0]
        if kind == "db" and op == "drop":
            return sql_result("DROP DATABASE %s;" % self.q(path[1]), confirm=True)
        if kind == "folder" and op == "create":
            d = self.q(path[1])
            return sql_result(self.TEMPLATES[path[2]].replace("{db}", d), database=path[1], title="new " + path[2][:-1])
        d = path[1]
        if kind == "index":
            t, name = path[2], path[3]
            table = self.full(d, t)
            if op == "drop":
                sql = ("ALTER TABLE %s DROP PRIMARY KEY;" % table if name == "PRIMARY"
                       else "DROP INDEX %s ON %s;" % (self.q(name), table))
                return sql_result(sql, database=d, confirm=True)
            for n, unique, cols in self.indexes(d, t):
                if n == name:
                    cols = ", ".join(self.q(c) for c in cols.split(","))
                    sql = ("ALTER TABLE %s ADD PRIMARY KEY (%s);" % (table, cols) if n == "PRIMARY" else
                           "CREATE %sINDEX %s ON %s (%s);" % ("UNIQUE " if unique else "", self.q(n), table, cols))
                    return sql_result(sql + "\n", database=d, title=name)
            raise ValueError("Index not found: %s" % name)
        name = path[2]
        full = self.full(d, name)
        word = self.WORDS.get(kind)
        if op == "ddl":
            cols, rows = self.fetch(path, "SHOW CREATE %s %s" % (word, full))
            idx = next(i for i, c in enumerate(cols) if c.lower().startswith("create ") or c.lower() == "sql original statement")
            text = rows[0][idx]
            if kind == "table":
                sql = text + ";\n"
            elif kind == "view":
                sql = re.sub(r"^CREATE\s", "CREATE OR REPLACE ", text, count=1) + ";\n"
            else:
                sql = "DROP %s IF EXISTS %s;\n\nDELIMITER $$\n%s $$\nDELIMITER ;\n" % (word, full, text)
            return sql_result(sql, database=d, title=name)
        if op == "drop":
            return sql_result("DROP %s %s;" % (word, full), database=d, confirm=True)
        if op == "truncate":
            return sql_result("TRUNCATE TABLE %s;" % full, database=d, confirm=True)
        if op == "create_index":
            return sql_result("CREATE INDEX idx_%s_column ON %s (column_name);\n" % (name, full), database=d,
                              title="new index")
        return super().object_sql(path, op)

    TEMPLATES = {
        "tables": "CREATE TABLE {db}.new_table (\n  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,\n"
                  "  name VARCHAR(255) NOT NULL,\n  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP\n"
                  ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n",
        "views": "CREATE OR REPLACE VIEW {db}.new_view AS\nSELECT 1 AS example;\n",
        "functions": "DELIMITER $$\nCREATE FUNCTION {db}.new_function(a INT) RETURNS INT\nDETERMINISTIC\nBEGIN\n"
                     "  RETURN a + 1;\nEND $$\nDELIMITER ;\n",
        "procedures": "DELIMITER $$\nCREATE PROCEDURE {db}.new_procedure(IN p_id INT)\nBEGIN\n"
                      "  SELECT p_id;\nEND $$\nDELIMITER ;\n",
        "triggers": "DELIMITER $$\nCREATE TRIGGER {db}.trg_table_before_insert\nBEFORE INSERT ON {db}.table_name\n"
                    "FOR EACH ROW\nBEGIN\n  SET NEW.created_at = NOW();\nEND $$\nDELIMITER ;\n",
        "events": "CREATE EVENT {db}.new_event\nON SCHEDULE EVERY 1 DAY\nDO\n"
                  "  DELETE FROM {db}.logs WHERE created_at < NOW() - INTERVAL 30 DAY;\n",
    }

    # -- data editor ----------------------------------------------------------
    def columns_info(self, path):
        rows = self.rows("SELECT column_name, column_type, column_key, is_nullable FROM information_schema.columns "
                         "WHERE table_schema = %s AND table_name = %s ORDER BY ordinal_position", (path[1], path[2]))
        return [{"name": n, "type": t, "pk": k == "PRI", "key": k, "nullable": nl == "YES"} for n, t, k, nl in rows]

    def table_sql(self, path):
        return self.full(path[1], path[2])

    def key_mode(self, path, info):
        indexes = self.indexes(path[1], path[2])
        nullable = {c["name"]: c["nullable"] for c in info}
        for name, unique, cols in indexes:
            cols = cols.split(",")
            if name == "PRIMARY" or (unique and not any(nullable.get(c, True) for c in cols)):
                return ("pk", cols)
        return (None, "No primary key or unique NOT NULL index: read-only")

    def param(self, value, typ, params):
        params.append(value)
        return "%s"

    def default_insert(self, table, info):
        return "INSERT INTO %s () VALUES ()" % table

    def transaction(self, path, stmts):
        self.conn.ping(reconnect=True)
        self.conn.begin()
        try:
            total = 0
            with self.conn.cursor() as cur:
                for sql, params, expect in stmts:
                    cur.execute(sql, params)
                    total += self.check_rowcount(cur, sql, expect)
            self.conn.commit()
            return total
        except Exception:
            self.conn.rollback()
            raise

    def query(self, text, database, limit):
        self.conn.ping(reconnect=True)
        if database:
            self.conn.select_db(database)
        return self.run_sql(self.conn, text, limit)


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

class PostgresAdapter(Adapter):
    dialect = "postgresql"
    FOLDERS = ["tables", "views", "matviews", "functions", "procedures", "sequences", "triggers"]
    RELKINDS = {"tables": "('r','p','f')", "views": "('v')", "matviews": "('m')", "sequences": "('S')"}

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

    def rows(self, database, sql, params=None):
        with self.get(database).cursor() as cur:
            return db_api_fetch(cur, sql, params)[1]

    def fetch(self, path, sql, params=None):
        with self.get(path[1]).cursor() as cur:
            return db_api_fetch(cur, sql, params)

    def rel(self, s, n):
        return "%s.%s" % (self.q(s), self.q(n))

    def children(self, path):
        if not path:
            rows = self.rows(None, "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname")
            return [node(r[0], "database", ["db", r[0]], database=r[0], ops=["create"]) for r in rows]
        db = path[1]
        if path[0] == "db":
            rows = self.rows(db, "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%%' "
                                 "AND nspname <> 'information_schema' ORDER BY nspname = 'public' DESC, nspname")
            return [node(r[0], "schema", ["schema", db, r[0]], database=db, ops=["drop"]) for r in rows]
        if path[0] == "schema":
            return [folder(f, ["folder", db, path[2], f], database=db) for f in self.FOLDERS]
        if path[0] == "folder":
            return self.folder_children(db, path[2], path[3])
        if path[0] in ("table", "view", "matview"):
            s, t = path[2], path[3]
            out = [node(c["name"], "column", ["column", db, s, t, c["name"]], leaf=True, database=db,
                        detail=c["type"] + (" PK" if c["pk"] else "") + (" NOT NULL" if c["notnull"] else ""))
                   for c in self.columns_info(path)]
            if path[0] != "view":
                for name, definition in self.rows(db, "SELECT indexname, indexdef FROM pg_indexes "
                                                      "WHERE schemaname = %s AND tablename = %s ORDER BY 1", (s, t)):
                    cols = definition[definition.rfind("(") + 1:].rstrip(")") if "(" in definition else ""
                    out.append(node(name, "index", ["index", db, s, name], leaf=True, database=db,
                                    detail=("unique " if " UNIQUE " in definition else "") + "(" + cols + ")",
                                    ops=CODE_OPS, open="ddl"))
            if path[0] == "table":
                out.extend(self.triggers(db, s, t))
            return out
        return []

    def triggers(self, db, s, table=None):
        sql = ("SELECT t.tgname, c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid "
               "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = %s AND NOT t.tgisinternal")
        params = [s]
        if table:
            sql += " AND c.relname = %s"
            params.append(table)
        return [node(n, "trigger", ["trigger", db, s, t, n], leaf=True, database=db, detail="on " + t,
                     ops=CODE_OPS, open="ddl") for n, t in self.rows(db, sql + " ORDER BY 1", params)]

    def folder_children(self, db, s, f):
        if f in self.RELKINDS:
            rows = self.rows(db, "SELECT c.relname, c.reltuples::bigint FROM pg_class c "
                                 "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = %s "
                                 "AND c.relkind IN " + self.RELKINDS[f] + " ORDER BY 1", (s,))
            kind = {"tables": "table", "views": "view", "matviews": "matview", "sequences": "sequence"}[f]
            out = []
            for name, tuples in rows:
                rel = self.rel(s, name)
                if kind == "sequence":
                    out.append(node(name, "sequence", ["sequence", db, s, name], leaf=True, database=db,
                                    action="SELECT * FROM %s;" % rel, ops=["select", "ddl", "drop"], open="ddl"))
                    continue
                ops = {"table": TABLE_OPS, "view": VIEW_OPS,
                       "matview": ["data", "select", "ddl", "refresh", "drop"]}[kind]
                out.append(node(name, kind, [kind, db, s, name], database=db, open="data", ops=ops,
                                detail="~%d rows" % tuples if kind == "table" and tuples and tuples > 0 else "",
                                action="SELECT * FROM %s LIMIT 100;" % rel))
            return out
        if f in ("functions", "procedures"):
            rows = self.rows(db, "SELECT p.oid::text, p.proname, pg_get_function_identity_arguments(p.oid), "
                                 "pg_get_function_result(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
                                 "LEFT JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e' "
                                 "WHERE n.nspname = %s AND p.prokind = %s AND d.objid IS NULL ORDER BY 2, 3",
                             (s, "f" if f == "functions" else "p"))
            kind = f[:-1]
            return [node("%s(%s)" % (name, args), kind, [kind, db, s, oid, name, args], leaf=True, database=db,
                         detail="→ " + res if res else "", ops=CODE_OPS, open="ddl") for oid, name, args, res in rows]
        if f == "triggers":
            return self.triggers(db, s)
        return []

    def object_sql(self, path, op):
        if not path and op == "create":
            return sql_result("CREATE DATABASE new_database;\n", title="new database")
        kind = path[0]
        if kind == "db" and op == "create":
            return sql_result("CREATE SCHEMA new_schema;\n", database=path[1], title="new schema")
        if kind == "schema" and op == "drop":
            return sql_result("DROP SCHEMA %s;" % self.q(path[2]), database=path[1], confirm=True)
        db = path[1]
        if kind == "folder" and op == "create":
            return sql_result(self.TEMPLATES[path[3]].replace("{s}", self.q(path[2])), database=db,
                              title="new " + path[3].rstrip("s"))
        s = path[2]
        if kind in ("function", "procedure"):
            oid, name, args = path[3], path[4], path[5]
            if op == "ddl":
                return sql_result(self.rows(db, "SELECT pg_get_functiondef(%s::oid)", (oid,))[0][0].strip() + ";\n",
                                  database=db, title=name)
            if op == "drop":
                return sql_result("DROP %s %s(%s);" % (kind.upper(), self.rel(s, name), args), database=db, confirm=True)
        if kind == "trigger":
            table, name = path[3], path[4]
            rel = self.rel(s, table)
            if op == "ddl":
                d = self.rows(db, "SELECT pg_get_triggerdef(oid, true) FROM pg_trigger WHERE tgrelid = %s::regclass "
                                  "AND tgname = %s", (rel, name))[0][0]
                return sql_result("DROP TRIGGER IF EXISTS %s ON %s;\n%s;\n" % (self.q(name), rel, d),
                                  database=db, title=name)
            if op == "drop":
                return sql_result("DROP TRIGGER %s ON %s;" % (self.q(name), rel), database=db, confirm=True)
        name = path[3]
        rel = self.rel(s, name)
        if kind == "index":
            if op == "ddl":
                d = self.rows(db, "SELECT indexdef FROM pg_indexes WHERE schemaname = %s AND indexname = %s", (s, name))
                return sql_result("-- Indexes cannot be altered in place: drop and recreate.\n%s;\n" % d[0][0],
                                  database=db, title=name)
            if op == "drop":
                return sql_result("DROP INDEX %s;" % rel, database=db, confirm=True)
        if op == "ddl":
            if kind == "table":
                return sql_result(self.table_ddl(db, s, name), database=db, title=name)
            if kind in ("view", "matview"):
                body = self.rows(db, "SELECT pg_get_viewdef(%s::regclass, true)", (rel,))[0][0].strip()
                if kind == "view":
                    sql = "CREATE OR REPLACE VIEW %s AS\n%s\n" % (rel, body)
                else:
                    sql = ("-- A materialized view is changed by dropping and recreating it.\n"
                           "-- DROP MATERIALIZED VIEW %s;\nCREATE MATERIALIZED VIEW %s AS\n%s\n" % (rel, rel, body))
                return sql_result(sql, database=db, title=name)
            if kind == "sequence":
                r = self.rows(db, "SELECT data_type::text, start_value, min_value, max_value, increment_by, cycle, "
                                  "cache_size, last_value FROM pg_sequences WHERE schemaname = %s AND sequencename = %s",
                              (s, name))[0]
                sql = ("CREATE SEQUENCE %s\n  AS %s\n  INCREMENT BY %s\n  MINVALUE %s\n  MAXVALUE %s\n  START WITH %s\n"
                       "  CACHE %s\n  %sCYCLE;\n\n-- Current value: %s\n-- SELECT setval('%s', %s);\n"
                       % (rel, r[0], r[4], r[2], r[3], r[1], r[6], "" if r[5] else "NO ", r[7], rel, r[7] or r[1]))
                return sql_result(sql, database=db, title=name)
        if op == "drop":
            word = {"table": "TABLE", "view": "VIEW", "matview": "MATERIALIZED VIEW", "sequence": "SEQUENCE"}[kind]
            return sql_result("DROP %s %s;" % (word, rel), database=db, confirm=True)
        if op == "truncate":
            return sql_result("TRUNCATE TABLE %s;" % rel, database=db, confirm=True)
        if op == "refresh":
            return sql_result("REFRESH MATERIALIZED VIEW %s;" % rel, database=db, confirm=True)
        if op == "create_index":
            return sql_result("CREATE INDEX idx_%s_column ON %s (column_name);\n" % (name, rel), database=db,
                              title="new index")
        return super().object_sql(path, op)

    def table_ddl(self, db, s, t):
        rel = self.rel(s, t)
        lines = []
        for name, typ, notnull, default, identity, generated in self.rows(
                db, "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, "
                    "pg_get_expr(ad.adbin, ad.adrelid), a.attidentity::text, a.attgenerated::text FROM pg_attribute a "
                    "LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum "
                    "WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum", (rel,)):
            line = "  %s %s" % (self.q(name), typ)
            if identity:
                line += " GENERATED %s AS IDENTITY" % ("ALWAYS" if identity == "a" else "BY DEFAULT")
            elif generated:
                line += " GENERATED ALWAYS AS (%s) STORED" % default
            elif default is not None:
                line += " DEFAULT " + default
            if notnull:
                line += " NOT NULL"
            lines.append(line)
        for name, definition in self.rows(db, "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint "
                                              "WHERE conrelid = %s::regclass ORDER BY contype <> 'p', conname", (rel,)):
            lines.append("  CONSTRAINT %s %s" % (self.q(name), definition))
        sql = "-- Definition of %s (change it with ALTER TABLE)\nCREATE TABLE %s (\n%s\n);\n" % (rel, rel, ",\n".join(lines))
        for (d,) in self.rows(db, "SELECT indexdef FROM pg_indexes WHERE schemaname = %s AND tablename = %s AND indexname "
                                  "NOT IN (SELECT conname FROM pg_constraint WHERE conrelid = %s::regclass)", (s, t, rel)):
            sql += "%s;\n" % d
        for (d,) in self.rows(db, "SELECT pg_get_triggerdef(oid, true) FROM pg_trigger "
                                  "WHERE tgrelid = %s::regclass AND NOT tgisinternal", (rel,)):
            sql += "%s;\n" % d
        return sql

    TEMPLATES = {
        "tables": "CREATE TABLE {s}.new_table (\n  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n"
                  "  name text NOT NULL,\n  created_at timestamptz NOT NULL DEFAULT now()\n);\n",
        "views": "CREATE OR REPLACE VIEW {s}.new_view AS\nSELECT 1 AS example;\n",
        "matviews": "CREATE MATERIALIZED VIEW {s}.new_matview AS\nSELECT 1 AS example\nWITH DATA;\n",
        "functions": "CREATE OR REPLACE FUNCTION {s}.new_function(a integer)\nRETURNS integer\nLANGUAGE plpgsql\nAS $$\n"
                     "BEGIN\n  RETURN a + 1;\nEND;\n$$;\n",
        "procedures": "CREATE OR REPLACE PROCEDURE {s}.new_procedure(p_id integer)\nLANGUAGE plpgsql\nAS $$\nBEGIN\n"
                      "  RAISE NOTICE 'id = %', p_id;\nEND;\n$$;\n\n-- CALL {s}.new_procedure(1);\n",
        "sequences": "CREATE SEQUENCE {s}.new_sequence\n  START WITH 1\n  INCREMENT BY 1;\n",
        "triggers": "CREATE OR REPLACE FUNCTION {s}.set_updated_at()\nRETURNS trigger\nLANGUAGE plpgsql\nAS $$\n"
                    "BEGIN\n  NEW.updated_at := now();\n  RETURN NEW;\nEND;\n$$;\n\n"
                    "CREATE TRIGGER trg_set_updated_at\nBEFORE UPDATE ON {s}.table_name\n"
                    "FOR EACH ROW EXECUTE FUNCTION {s}.set_updated_at();\n",
    }

    # -- data editor ----------------------------------------------------------
    def columns_info(self, path):
        rows = self.rows(path[1], "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, "
                                  "EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary "
                                  "AND a.attnum = ANY(i.indkey)) FROM pg_attribute a "
                                  "WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped "
                                  "ORDER BY a.attnum", (self.rel(path[2], path[3]),))
        return [{"name": n, "type": t, "notnull": nn, "pk": pk} for n, t, nn, pk in rows]

    def table_sql(self, path):
        return self.rel(path[2], path[3])

    def key_mode(self, path, info):
        pk = [c["name"] for c in info if c["pk"]]
        return ("pk", pk) if pk else ("rowid", 'ctid::text AS "%s"' % KEY)

    def param(self, value, typ, params):
        params.append(value)
        return "%s::" + typ if typ else "%s"

    def rowid_where(self, value, params):
        params.append(value)
        return "ctid = %s::tid"

    def transaction(self, path, stmts):
        conn = self.get(path[1])
        total = 0
        with conn.transaction():
            with conn.cursor() as cur:
                for sql, params, expect in stmts:
                    cur.execute(sql, params)
                    total += self.check_rowcount(cur, sql, expect)
        return total

    def query(self, text, database, limit):
        return self.run_sql(self.get(database), text, limit)


# ---------------------------------------------------------------------------
# Oracle
# ---------------------------------------------------------------------------

class OracleAdapter(Adapter):
    dialect = "oracle"
    FOLDERS = ["tables", "views", "matviews", "functions", "procedures", "packages", "sequences", "triggers"]
    TYPES = {"tables": "TABLE", "views": "VIEW", "matviews": "MATERIALIZED VIEW", "functions": "FUNCTION",
             "procedures": "PROCEDURE", "packages": "PACKAGE", "sequences": "SEQUENCE", "triggers": "TRIGGER"}
    KINDS = {"tables": "table", "views": "view", "matviews": "matview", "functions": "function",
             "procedures": "procedure", "packages": "package", "sequences": "sequence", "triggers": "trigger"}
    WORDS = {"table": "TABLE", "view": "VIEW", "matview": "MATERIALIZED VIEW", "function": "FUNCTION",
             "procedure": "PROCEDURE", "package": "PACKAGE", "sequence": "SEQUENCE", "trigger": "TRIGGER",
             "index": "INDEX"}
    PLSQL = ("function", "procedure", "package", "trigger")

    def __init__(self, cfg):
        super().__init__(cfg)
        oracledb = require_driver("oracle")
        oracledb.defaults.fetch_lobs = False
        dsn = cfg.get("dsn") or "%s:%s/%s" % (cfg.get("host") or "127.0.0.1", cfg.get("port") or 1521,
                                              cfg.get("database") or "FREEPDB1")
        self.conn = oracledb.connect(user=cfg.get("user"), password=cfg.get("password"), dsn=dsn,
                                     tcp_connect_timeout=10)
        self.conn.autocommit = True

    def close(self):
        self.conn.close()

    def fetch(self, path, sql, params=None):
        with self.conn.cursor() as cur:
            return db_api_fetch(cur, sql, params)

    def rows(self, sql, params=None):
        return self.fetch(None, sql, params or {})[1]

    def full(self, owner, name):
        return "%s.%s" % (self.q(owner), self.q(name))

    def children(self, path):
        if not path:
            me = (self.cfg.get("user") or "").upper()
            owners = [r[0] for r in self.rows("SELECT DISTINCT owner FROM all_objects "
                                              "WHERE object_type IN ('TABLE','VIEW') ORDER BY owner")]
            owners.sort(key=lambda o: (o != me, o))
            return [node(o, "schema", ["schema", o]) for o in owners]
        if path[0] == "schema":
            return [folder(f, ["folder", path[1], f]) for f in self.FOLDERS]
        if path[0] == "folder":
            o, f = path[1], path[2]
            kind = self.KINDS[f]
            rows = self.rows("SELECT object_name, status FROM all_objects WHERE owner = :o AND object_type = :t "
                             "AND object_name NOT LIKE 'BIN$%' ORDER BY object_name", {"o": o, "t": self.TYPES[f]})
            out = []
            for name, status in rows:
                full = self.full(o, name)
                detail = "invalid" if status != "VALID" else ""
                if kind == "table":
                    out.append(node(name, kind, [kind, o, name], open="data", ops=TABLE_OPS, detail=detail,
                                    action="SELECT * FROM %s FETCH FIRST 100 ROWS ONLY" % full))
                elif kind in ("view", "matview"):
                    ops = VIEW_OPS if kind == "view" else ["data", "select", "ddl", "refresh", "drop"]
                    out.append(node(name, kind, [kind, o, name], open="data", ops=ops, detail=detail,
                                    action="SELECT * FROM %s FETCH FIRST 100 ROWS ONLY" % full))
                elif kind == "sequence":
                    out.append(node(name, kind, [kind, o, name], leaf=True, open="ddl", ops=["select", "ddl", "drop"],
                                    action="SELECT * FROM all_sequences WHERE sequence_owner = '%s' "
                                           "AND sequence_name = '%s'" % (o.replace("'", "''"), name.replace("'", "''"))))
                else:
                    out.append(node(name, kind, [kind, o, name], leaf=True, open="ddl", ops=CODE_OPS, detail=detail))
            return out
        if path[0] in ("table", "view", "matview"):
            o, t = path[1], path[2]
            out = [node(c["name"], "column", ["column", o, t, c["name"]], leaf=True, detail=c["detail"])
                   for c in self.columns_info(path)]
            if path[0] == "table":
                for name, uniq in self.rows("SELECT index_name, uniqueness FROM all_indexes WHERE owner = :o "
                                            "AND table_name = :t ORDER BY index_name", {"o": o, "t": t}):
                    out.append(node(name, "index", ["index", o, name, t], leaf=True, ops=CODE_OPS, open="ddl",
                                    detail=uniq.lower()))
            return out
        return []

    def ddl(self, kind, owner, name):
        try:
            text = self.rows("SELECT DBMS_METADATA.GET_DDL(:t, :n, :o) FROM dual",
                             {"t": self.WORDS[kind].replace(" ", "_"), "n": name, "o": owner})[0][0]
        except Exception:
            text = self.fallback_ddl(kind, owner, name)
        text = str(text).strip()
        if kind in self.PLSQL:
            # Each PL/SQL unit (package spec/body, trigger) must end with a '/' line.
            text = re.sub(r"\n\s*(?=(CREATE OR REPLACE|ALTER TRIGGER))", "\n/\n", text).rstrip()
            return text + "\n/\n"
        return text + ";\n"

    def fallback_ddl(self, kind, owner, name):
        if kind in self.PLSQL:
            units = []
            types = ["PACKAGE", "PACKAGE BODY"] if kind == "package" else [self.WORDS[kind]]
            for t in types:
                lines = self.rows("SELECT text FROM all_source WHERE owner = :o AND name = :n AND type = :t "
                                  "ORDER BY line", {"o": owner, "n": name, "t": t})
                if lines:
                    units.append("CREATE OR REPLACE " + "".join(r[0] for r in lines).strip())
            if units:
                return "\n/\n".join(units)
        if kind == "view":
            rows = self.rows("SELECT text FROM all_views WHERE owner = :o AND view_name = :n", {"o": owner, "n": name})
            if rows:
                return "CREATE OR REPLACE VIEW %s AS\n%s" % (self.full(owner, name), rows[0][0])
        raise ValueError("Cannot read the definition of %s.%s (DBMS_METADATA not allowed)" % (owner, name))

    def object_sql(self, path, op):
        kind = path[0]
        if kind == "folder" and op == "create":
            return sql_result(self.TEMPLATES[path[2]].replace("{o}", self.q(path[1])), title="new " + self.KINDS[path[2]])
        o, name = path[1], path[2]
        full = self.full(o, name)
        if op == "ddl":
            return sql_result(self.ddl(kind, o, name), title=name)
        if op == "drop":
            return sql_result("DROP %s %s" % (self.WORDS[kind], full), confirm=True)
        if op == "truncate":
            return sql_result("TRUNCATE TABLE %s" % full, confirm=True)
        if op == "refresh":
            return sql_result("BEGIN\n  DBMS_MVIEW.REFRESH('%s.%s');\nEND;\n/" % (o, name), confirm=True)
        if op == "create_index":
            return sql_result("CREATE INDEX %s ON %s (column_name)" % (self.q("IDX_" + name[:24]), full), title="new index")
        return super().object_sql(path, op)

    TEMPLATES = {
        "tables": "CREATE TABLE {o}.NEW_TABLE (\n  ID NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n"
                  "  NAME VARCHAR2(255) NOT NULL,\n  CREATED_AT TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL\n);\n",
        "views": "CREATE OR REPLACE VIEW {o}.NEW_VIEW AS\nSELECT 1 AS EXAMPLE FROM dual;\n",
        "matviews": "CREATE MATERIALIZED VIEW {o}.NEW_MVIEW\nREFRESH COMPLETE ON DEMAND AS\nSELECT 1 AS EXAMPLE FROM dual;\n",
        "functions": "CREATE OR REPLACE FUNCTION {o}.NEW_FUNCTION(p_a IN NUMBER) RETURN NUMBER IS\nBEGIN\n"
                     "  RETURN p_a + 1;\nEND;\n/\n",
        "procedures": "CREATE OR REPLACE PROCEDURE {o}.NEW_PROCEDURE(p_id IN NUMBER) IS\nBEGIN\n"
                      "  DBMS_OUTPUT.PUT_LINE('id = ' || p_id);\nEND;\n/\n",
        "packages": "CREATE OR REPLACE PACKAGE {o}.NEW_PACKAGE AS\n  FUNCTION hello RETURN VARCHAR2;\nEND;\n/\n\n"
                    "CREATE OR REPLACE PACKAGE BODY {o}.NEW_PACKAGE AS\n  FUNCTION hello RETURN VARCHAR2 IS\n"
                    "  BEGIN\n    RETURN 'hello';\n  END;\nEND;\n/\n",
        "sequences": "CREATE SEQUENCE {o}.NEW_SEQUENCE START WITH 1 INCREMENT BY 1 NOCACHE;\n",
        "triggers": "CREATE OR REPLACE TRIGGER {o}.TRG_TABLE_BIU\nBEFORE INSERT OR UPDATE ON {o}.TABLE_NAME\n"
                    "FOR EACH ROW\nBEGIN\n  :NEW.UPDATED_AT := SYSTIMESTAMP;\nEND;\n/\n",
    }

    # -- data editor ----------------------------------------------------------
    def columns_info(self, path):
        rows = self.rows("SELECT column_name, data_type, data_length, nullable FROM all_tab_columns "
                         "WHERE owner = :o AND table_name = :t ORDER BY column_id", {"o": path[1], "t": path[2]})
        return [{"name": n, "type": t, "pk": False,
                 "detail": "%s(%s)%s" % (t, ln, " NOT NULL" if nl == "N" else "")} for n, t, ln, nl in rows]

    def table_sql(self, path):
        return self.full(path[1], path[2])

    def from_sql(self, path):
        return self.full(path[1], path[2]) + " t"

    def key_mode(self, path, info):
        return ("rowid", 'ROWIDTOCHAR(t.ROWID) AS "%s"' % KEY)

    def paginate(self, sql, offset, count):
        return "%s OFFSET %d ROWS FETCH NEXT %d ROWS ONLY" % (sql, offset, count)

    def param(self, value, typ, params):
        if isinstance(value, str):
            t = (typ or "").upper()
            try:
                if t.startswith("DATE") or t.startswith("TIMESTAMP"):
                    value = datetime.datetime.fromisoformat(value)
                elif t in ("NUMBER", "FLOAT", "INTEGER", "BINARY_FLOAT", "BINARY_DOUBLE"):
                    value = decimal.Decimal(value)
            except (ValueError, decimal.InvalidOperation):
                pass
        params.append(value)
        return ":%d" % len(params)

    def rowid_where(self, value, params):
        params.append(value)
        return "ROWID = CHARTOROWID(:%d)" % len(params)

    def default_insert(self, table, info):
        return "INSERT INTO %s (%s) VALUES (DEFAULT)" % (table, self.q(info[0]["name"]))

    def transaction(self, path, stmts):
        self.conn.autocommit = False
        try:
            total = 0
            with self.conn.cursor() as cur:
                for sql, params, expect in stmts:
                    cur.execute(sql, params)
                    total += self.check_rowcount(cur, sql, expect)
            self.conn.commit()
            return total
        except Exception:
            self.conn.rollback()
            raise
        finally:
            self.conn.autocommit = True

    def query(self, text, database, limit):
        results = []
        for stmt in split_sql(text, "oracle"):
            s = stmt.strip()
            # SQL statements must not end with ';', PL/SQL blocks must.
            if not re.match(r"(?is)^(begin|declare|create\s+(or\s+replace\s+)?((non)?editionable\s+)?"
                            r"(procedure|function|package|trigger|type))\b", s):
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


# ---------------------------------------------------------------------------
# ClickHouse
# ---------------------------------------------------------------------------

class ClickhouseAdapter(Adapter):
    dialect = "clickhouse"
    quote_char = "`"
    READ = ("SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXISTS", "EXPLAIN", "CHECK")
    FOLDERS = ["tables", "views", "dictionaries"]
    VIEW_ENGINES = "('View','MaterializedView','LiveView','WindowView')"

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

    def q(self, name):
        return "`%s`" % str(name).replace("\\", "\\\\").replace("`", "\\`")

    def fetch(self, path, sql, params=None):
        r = self.client.query(sql, parameters=params)
        return list(r.column_names), list(r.result_rows)

    def rows(self, sql, params=None):
        return self.fetch(None, sql, params)[1]

    def full(self, d, n):
        return "%s.%s" % (self.q(d), self.q(n))

    def children(self, path):
        if not path:
            return [node(r[0], "database", ["db", r[0]], database=r[0], ops=["drop"])
                    for r in self.rows("SELECT name FROM system.databases ORDER BY name")]
        if path[0] == "db":
            return [folder(f, ["folder", path[1], f], database=path[1]) for f in self.FOLDERS]
        if path[0] == "folder":
            d, f = path[1], path[2]
            cond = {"tables": "engine NOT IN %s AND engine != 'Dictionary'" % self.VIEW_ENGINES,
                    "views": "engine IN %s" % self.VIEW_ENGINES,
                    "dictionaries": "engine = 'Dictionary'"}[f]
            rows = self.rows("SELECT name, engine, total_rows FROM system.tables WHERE database = {d:String} AND "
                             + cond + " ORDER BY name", {"d": d})
            out = []
            for name, engine, total in rows:
                action = "SELECT * FROM %s LIMIT 100;" % self.full(d, name)
                if f == "tables":
                    out.append(node(name, "table", ["table", d, name], database=d, open="data", ops=TABLE_OPS,
                                    action=action, detail=engine + (" · %s rows" % total if total is not None else "")))
                elif f == "views":
                    out.append(node(name, "view", ["view", d, name], database=d, open="data", ops=VIEW_OPS,
                                    action=action, detail=engine))
                else:
                    out.append(node(name, "dictionary", ["dictionary", d, name], leaf=True, database=d,
                                    ops=["select", "ddl", "drop"], open="ddl", action=action))
            return out
        if path[0] in ("table", "view"):
            return [node(c["name"], "column", ["column", path[1], path[2], c["name"]], leaf=True, database=path[1],
                         detail=c["type"] + (" PK" if c["pk"] else "")) for c in self.columns_info(path)]
        return []

    def object_sql(self, path, op):
        if not path and op == "create":
            return sql_result("CREATE DATABASE new_database;\n", title="new database")
        kind = path[0]
        if kind == "db" and op == "drop":
            return sql_result("DROP DATABASE %s;" % self.q(path[1]), confirm=True)
        if kind == "folder" and op == "create":
            return sql_result(self.TEMPLATES[path[2]].replace("{db}", self.q(path[1])), database=path[1],
                              title="new " + path[2].rstrip("s"))
        d, name = path[1], path[2]
        full = self.full(d, name)
        word = {"table": "TABLE", "view": "VIEW", "dictionary": "DICTIONARY"}[kind]
        if op == "ddl":
            text = self.rows("SELECT create_table_query FROM system.tables WHERE database = {d:String} "
                             "AND name = {n:String}", {"d": d, "n": name})[0][0]
            if kind == "view":
                text = re.sub(r"^CREATE VIEW", "CREATE OR REPLACE VIEW", text)
            return sql_result(text + ";\n", database=d, title=name)
        if op == "drop":
            return sql_result("DROP %s %s;" % (word, full), database=d, confirm=True)
        if op == "truncate":
            return sql_result("TRUNCATE TABLE %s;" % full, database=d, confirm=True)
        if op == "create_index":
            return sql_result("ALTER TABLE %s ADD INDEX idx_column column_name TYPE minmax GRANULARITY 1;\n" % full,
                              database=d, title="new index")
        return super().object_sql(path, op)

    TEMPLATES = {
        "tables": "CREATE TABLE {db}.new_table\n(\n  id UInt64,\n  name String,\n  created_at DateTime DEFAULT now()\n)\n"
                  "ENGINE = MergeTree\nORDER BY id;\n",
        "views": "CREATE VIEW {db}.new_view AS\nSELECT 1 AS example;\n\n"
                 "-- Materialized view:\n-- CREATE MATERIALIZED VIEW {db}.new_mv TO {db}.target_table AS\n"
                 "-- SELECT … FROM {db}.source_table;\n",
        "dictionaries": "CREATE DICTIONARY {db}.new_dictionary\n(\n  id UInt64,\n  name String\n)\nPRIMARY KEY id\n"
                        "SOURCE(CLICKHOUSE(TABLE 'source_table' DB 'default'))\nLAYOUT(HASHED())\nLIFETIME(MIN 300 MAX 600);\n",
    }

    # -- data editor (mutations: not transactional) ---------------------------
    def columns_info(self, path):
        rows = self.rows("SELECT name, type, is_in_primary_key, is_in_sorting_key FROM system.columns "
                         "WHERE database = {d:String} AND table = {t:String} ORDER BY position",
                         {"d": path[1], "t": path[2]})
        return [{"name": n, "type": t, "pk": bool(p), "sort": bool(s)} for n, t, p, s in rows]

    def table_sql(self, path):
        return self.full(path[1], path[2])

    def key_mode(self, path, info):
        key = [c["name"] for c in info if c["pk"]] or [c["name"] for c in info if c["sort"]]
        return ("pk", key) if key else (None, "Table without a primary or sorting key: read-only")

    def new_params(self):
        return {}

    def param(self, value, typ, params):
        if value is None:
            return "NULL"
        if isinstance(value, str) and re.match(r"\d{4}-\d\d-\d\dT\d", value) and "Date" in (typ or ""):
            value = value.replace("T", " ", 1)  # ISO 'T' is rejected by CAST(… AS DateTime)
        name = "p%d" % len(params)
        params[name] = value
        return "CAST(%%(%s)s AS %s)" % (name, typ) if typ else "%%(%s)s" % name

    def update_stmt(self, table, sets, where):
        return "ALTER TABLE %s UPDATE %s WHERE %s" % (table, sets, where)

    def default_insert(self, table, info):
        raise ValueError("ClickHouse needs at least one value to insert a row")

    def transaction(self, path, stmts):
        for sql, params, expect in stmts:
            self.client.command(sql, parameters=params or None, settings={"mutations_sync": 1})
        return len(stmts)

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
