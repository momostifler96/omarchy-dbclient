#!/usr/bin/env python3
"""Backend for the Omarchy DB client plugin.

Speaks JSON lines on stdin/stdout. Every request is {"id", "cmd", ...} and
gets exactly one {"id", "ok", "result"|"error"} reply; long-running commands
may also emit {"event", ...} lines in between (install logs, driver changes).

Drivers are plain Python packages, imported from the system site-packages
(pacman) or from a private venv (pip). Nothing is installed without an
explicit "install_driver" request, which the UI sends only after the user
confirmed.
"""

import json
import os
import sys
import threading
import time
import traceback
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from core import (CONFIG_DIR, SETTINGS_FILE, STATE_FILE, add_venv_to_path, driver_status, emit,  # noqa: E402
                  find_connection, install_driver, load_connections, load_settings, require_driver,
                  store_connections)
from nosql_engines import MongoAdapter, RedisAdapter  # noqa: E402
from sql_engines import (ClickhouseAdapter, MysqlAdapter, OracleAdapter, PostgresAdapter,  # noqa: E402
                         SqliteAdapter)

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

    def cmd_object_sql(self, req):
        s = self.session(req["connId"])
        with s.lock:
            return s.object_sql(req.get("path") or [], req["op"])

    def cmd_table_data(self, req):
        s = self.session(req["connId"])
        limit = max(1, min(int(req.get("limit") or 200), 10000))
        with s.lock:
            return s.table_data(req["path"], req.get("where") or "", req.get("order") or "",
                                bool(req.get("desc")), int(req.get("offset") or 0), limit)

    def cmd_apply_changes(self, req):
        s = self.session(req["connId"])
        with s.lock:
            return s.apply_changes(req["path"], req.get("changes") or [])

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
