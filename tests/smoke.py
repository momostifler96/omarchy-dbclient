#!/usr/bin/env python3
"""End-to-end smoke test against real servers in Docker.

    python3 tests/smoke.py                 # mysql postgresql redis mongodb clickhouse
    python3 tests/smoke.py oracle          # just Oracle (large image, slow first start)

Needs docker access (sudo or the docker group) and the drivers installed
(`omarchy-dbclient drivers`). Containers are named dbclient-smoke-* and
removed at the end. Uses a throwaway config dir, never your connections.
"""
import json, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "..", "backend", "dbclient.py")

SERVERS = {
    "mysql": (["-e", "MYSQL_ROOT_PASSWORD=pw", "-p", "13306:3306", "mysql:8"],
              {"host": "127.0.0.1", "port": 13306, "user": "root", "password": "pw"},
              "CREATE DATABASE IF NOT EXISTS t; CREATE TABLE IF NOT EXISTS t.a(id int primary key, s text); "
              "REPLACE INTO t.a VALUES (1,'x;y'),(2,NULL); SELECT * FROM t.a"),
    "postgresql": (["-e", "POSTGRES_PASSWORD=pw", "-p", "15432:5432", "postgres:17"],
                   {"host": "127.0.0.1", "port": 15432, "user": "postgres", "password": "pw"},
                   "CREATE TABLE IF NOT EXISTS a(id int primary key, j jsonb); "
                   "INSERT INTO a VALUES (1, '{\"k\": 1}') ON CONFLICT DO NOTHING; "
                   "DO $$ BEGIN PERFORM 1; END $$; SELECT * FROM a"),
    "redis": (["-p", "16379:6379", "redis:7"], {"host": "127.0.0.1", "port": 16379},
              "SET k v\nHSET h a 1\nGET k\nHGETALL h"),
    "mongodb": (["-p", "17017:27017", "mongo:7"], {"host": "127.0.0.1", "port": 17017, "database": "t"},
                "db.a.insertOne({x: 1, when: ISODate('2024-01-01T00:00:00Z')})\ndb.a.find({x: {$gte: 1}}).limit(5)"),
    "clickhouse": (["-e", "CLICKHOUSE_PASSWORD=pw", "-p", "18123:8123", "clickhouse/clickhouse-server:latest"],
                   {"host": "127.0.0.1", "port": 18123, "user": "default", "password": "pw"},
                   "CREATE TABLE IF NOT EXISTS a (id UInt32, s String) ENGINE = MergeTree ORDER BY id; "
                   "INSERT INTO a VALUES (1, 'x'); SELECT * FROM a"),
    "oracle": (["-e", "ORACLE_PASSWORD=pw", "-p", "11521:1521", "gvenzl/oracle-free:slim"],
               {"host": "127.0.0.1", "port": 11521, "user": "system", "password": "pw", "database": "FREEPDB1"},
               "SELECT 1 AS one, SYSDATE AS now FROM dual;\nBEGIN NULL; END;\n/"),
}


# Object opened in the data editor after the script ran: (path, column, new value)
EDIT = {
    "mysql": (["table", "t", "a"], "s", "edited"),
    "postgresql": (["table", "postgres", "public", "a"], "j", '{"k": 2}'),
    "redis": (["key", "0", "h"], "value", "2"),
    "mongodb": (["coll", "t", "a"], "x", "2"),
    "clickhouse": (["table", "default", "a"], "s", "edited"),
}


class Backend:
    def __init__(self, cfgdir):
        env = dict(os.environ, DBCLIENT_CONFIG_DIR=cfgdir, DBCLIENT_STATE_DIR=cfgdir)
        self.p = subprocess.Popen([sys.executable, BACKEND], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, env=env)
        self.n = 0

    def call(self, cmd, **kw):
        self.n += 1
        self.p.stdin.write(json.dumps(dict(kw, id=self.n, cmd=cmd)) + "\n")
        self.p.stdin.flush()
        while True:
            msg = json.loads(self.p.stdout.readline())
            if msg.get("id") == self.n and "event" not in msg:
                return msg


def main():
    kinds = sys.argv[1:] or ["mysql", "postgresql", "redis", "mongodb", "clickhouse"]
    backend = Backend(tempfile.mkdtemp(prefix="dbclient-smoke-"))
    drivers = backend.call("drivers")["result"]["drivers"]
    failed = []
    for kind in kinds:
        if not drivers[kind]["installed"]:
            print("SKIP %-11s driver missing (omarchy-dbclient drivers)" % kind)
            continue
        args, cfg, sql = SERVERS[kind]
        name = "dbclient-smoke-" + kind
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "run", "-d", "--name", name] + args, check=True, capture_output=True)
        try:
            conn = dict(cfg, id=kind, name=kind, type=kind)
            backend.call("save_connection", connection=conn)
            deadline = time.time() + (300 if kind == "oracle" else 90)
            while True:
                r = backend.call("test_connection", connection=conn)
                if r["ok"] or time.time() > deadline:
                    break
                backend.call("disconnect", connId=kind)
                time.sleep(3)
            if not r["ok"]:
                raise RuntimeError(r["error"])
            tree = backend.call("children", connId=kind, path=[])
            q = backend.call("query", connId=kind, text=sql, database="t" if kind == "mysql" else "")
            if not tree["ok"] or not q["ok"]:
                raise RuntimeError(tree.get("error") or q.get("error"))
            last = q["result"]["results"][-1]
            if kind in EDIT:
                path, col, value = EDIT[kind]
                data = backend.call("table_data", connId=kind, path=path, limit=10)
                if not data["ok"]:
                    raise RuntimeError("table_data: " + data["error"])
                d = data["result"]
                change = {"op": "update", "key": d["keys"][0], "values": {col: value}}
                applied = backend.call("apply_changes", connId=kind, path=path, changes=[change])
                if not applied["ok"]:
                    raise RuntimeError("apply_changes: " + applied["error"])
                again = backend.call("table_data", connId=kind, path=path, limit=10)["result"]
                got = again["rows"][0][again["columns"].index(col)]
                if str(got).replace(" ", "") != value.replace(" ", ""):
                    raise RuntimeError("edit not saved: %r" % got)
                if path[0] == "table":
                    ddl = backend.call("object_sql", connId=kind, path=path, op="ddl")
                    if not ddl["ok"] or "CREATE" not in ddl["result"]["sql"].upper():
                        raise RuntimeError("ddl: %s" % ddl.get("error"))
            print("OK   %-11s tree=%d nodes, %d results, last: %s %s" % (
                kind, len(tree["result"]), len(q["result"]["results"]), last["columns"], last["rows"][:2]))
        except Exception as e:
            failed.append(kind)
            print("FAIL %-11s %s" % (kind, e))
        finally:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
