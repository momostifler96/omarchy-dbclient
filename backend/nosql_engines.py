"""NoSQL engines: Redis / Valkey and MongoDB."""

import datetime
import json
import re
import shlex
import time
import uuid

from core import Adapter, message_result, node, require_driver, result_set, sql_result, to_jsonable


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
                             detail="%d keys" % self.get(db).dbsize(), database=str(db), ops=["create"])]
            try:
                count = int(client.config_get("databases").get("databases", 16))
            except Exception:
                count = 16
            out = []
            for i in range(count):
                info = keyspace.get("db%d" % i)
                if info or i == 0 or i == int(self.cfg.get("database") or 0):
                    keys = info.get("keys", 0) if isinstance(info, dict) else 0
                    out.append(node("db%d" % i, "database", ["db", str(i)], detail="%d keys" % keys, database=str(i),
                                    ops=["create"]))
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
                                database=path[1], ops=["data", "select", "drop"], open="data"))
            if len(keys) >= 1000:
                out.append(node("… first 1000 keys (use SCAN to see more)", "info", ["info"], leaf=True))
            return out
        return []

    def object_sql(self, path, op):
        if path[0] == "db" and op == "create":
            return sql_result('SET new:key "value"\nHSET new:hash field "value"\nRPUSH new:list "a" "b"\n'
                              'SADD new:set "a"\nZADD new:zset 1 "a"\nEXPIRE new:key 3600\n',
                              database=path[1], title="new key")
        if path[0] == "key" and op == "drop":
            return sql_result("DEL " + self.quote(path[2]), database=path[1], confirm=True)
        return super().object_sql(path, op)

    # -- data editor: one grid per key, shaped by its type -------------------
    SHAPES = {"string": ["value"], "hash": ["field", "value"], "list": ["index", "value"],
              "set": ["member"], "zset": ["member", "score"], "stream": ["id", "fields"]}

    def key_type(self, client, key):
        t = client.type(key)
        return t.decode() if isinstance(t, bytes) else str(t)

    def table_data(self, path, where, order, desc, offset, limit):
        t0 = time.time()
        start = offset = int(offset or 0)
        db, key = path[1], path[2]
        client = self.get(db)
        t = self.key_type(client, key)
        if t == "none":
            raise ValueError("Key %s does not exist anymore" % key)
        dec = lambda v: v.decode("utf-8", "replace") if isinstance(v, bytes) else v
        pattern = where.strip() if where and where.strip() else None
        keys = []
        if t == "string":
            rows = [[dec(client.get(key))]]
            keys = [{}]
        elif t == "hash":
            items = []
            for f, v in client.hscan_iter(key, match=pattern, count=500):
                items.append((dec(f), dec(v)))
                if len(items) > offset + limit:
                    break
            items.sort()
            rows = [list(i) for i in items]
            keys = [{"field": f} for f, _ in items]
        elif t == "list":
            vals = client.lrange(key, offset, offset + limit)
            rows = [[offset + i, dec(v)] for i, v in enumerate(vals)]
            keys = [{"index": offset + i} for i in range(len(vals))]
            offset = 0
        elif t == "set":
            items = sorted(dec(m) for m in client.sscan_iter(key, match=pattern, count=500))
            rows = [[m] for m in items]
            keys = [{"member": m} for m in items]
        elif t == "zset":
            items = client.zrange(key, offset, offset + limit, withscores=True)
            rows = [[dec(m), s] for m, s in items]
            keys = [{"member": dec(m)} for m, _ in items]
            offset = 0
        else:
            items = client.xrange(key, count=offset + limit + 1)
            rows = [[dec(i), {dec(k): dec(v) for k, v in f.items()}] for i, f in items]
            keys = [{} for _ in rows]
        rows, keys = rows[offset:], keys[offset:]
        cols = self.SHAPES[t]
        res = result_set(cols, rows, limit, time.time() - t0, "%s (%s)" % (key, t))
        editable = t != "stream"
        ttl = client.ttl(key)
        res.update({
            "keys": keys[:limit], "types": [t] * len(cols), "editable": editable,
            "colEditable": [editable and c != "index" for c in cols],
            "readonlyReason": "" if editable else "Streams are append-only",
            "keyColumns": [], "hasMore": len(rows) > limit, "offset": start,
            "message": "TTL %ss" % ttl if ttl and ttl > 0 else "",
        })
        return res

    def apply_changes(self, path, changes):
        db, key = path[1], path[2]
        client = self.get(db)
        t = self.key_type(client, key)
        pipe = client.pipeline(transaction=True)
        doomed = "\x00dbclient-deleted\x00"
        list_deletes = 0
        for ch in changes:
            op, k, v = ch.get("op"), ch.get("key") or {}, ch.get("values") or {}
            if t == "string" or (t == "none" and op == "insert"):
                if "value" in v:
                    pipe.set(key, v["value"] or "", keepttl=True)
                elif op == "delete":
                    pipe.delete(key)
            elif t == "hash":
                if op == "delete":
                    pipe.hdel(key, k["field"])
                elif op == "insert":
                    pipe.hset(key, v.get("field") or "", v.get("value") or "")
                else:
                    field = v.get("field", k["field"])
                    if field != k["field"]:
                        value = v["value"] if "value" in v else client.hget(key, k["field"])
                        pipe.hdel(key, k["field"])
                        pipe.hset(key, field, value or "")
                    else:
                        pipe.hset(key, field, v.get("value") or "")
            elif t == "list":
                if op == "delete":
                    pipe.lset(key, int(k["index"]), doomed)
                    list_deletes += 1
                elif op == "insert":
                    pipe.rpush(key, v.get("value") or "")
                elif "value" in v:
                    pipe.lset(key, int(k["index"]), v["value"] or "")
            elif t == "set":
                if op in ("delete", "update"):
                    pipe.srem(key, k["member"])
                if op in ("insert", "update"):
                    pipe.sadd(key, v.get("member", k.get("member")) or "")
            elif t == "zset":
                if op == "delete":
                    pipe.zrem(key, k["member"])
                else:
                    member = v.get("member", k.get("member")) or ""
                    score = v.get("score")
                    if score is None and op == "update":
                        score = client.zscore(key, k["member"])
                    if op == "update" and member != k["member"]:
                        pipe.zrem(key, k["member"])
                    pipe.zadd(key, {member: float(score or 0)})
            else:
                raise ValueError("Keys of type %s cannot be edited" % t)
        if list_deletes:
            pipe.lrem(key, 0, doomed)
        pipe.execute()
        return {"applied": len(changes), "affected": len(changes)}

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
            return [node(n, "database", ["db", n], database=n, ops=["create", "drop"])
                    for n in sorted(self.client.list_database_names())]
        if path[0] == "db":
            infos = sorted(self.client[path[1]].list_collections(), key=lambda c: c["name"])
            out = []
            for c in infos:
                n = c["name"]
                view = c.get("type") == "view"
                out.append(node(n, "view" if view else "collection", ["coll", path[1], n], database=path[1],
                                detail="view on " + c.get("options", {}).get("viewOn", "") if view else "",
                                action="db.getCollection(%s).find({}).limit(100)" % json.dumps(n), open="data",
                                ops=["data", "select", "ddl", "drop"] if view
                                else ["data", "select", "ddl", "create_index", "drop"]))
            return out
        if path[0] == "coll":
            coll = self.client[path[1]][path[2]]
            out = []
            for name, spec in coll.index_information().items():
                keys = ", ".join("%s:%s" % (k, v) for k, v in spec.get("key", []))
                out.append(node(name, "index", ["index", path[1], path[2], name], leaf=True, detail=keys,
                                database=path[1], ops=["drop"] if name != "_id_" else []))
            return out
        return []

    def coll_ref(self, name):
        return "db.getCollection(%s)" % json.dumps(name)

    def object_sql(self, path, op):
        from bson import json_util
        kind = path[0]
        if kind == "db":
            if op == "create":
                return sql_result('db.createCollection("new_collection")\n\n'
                                  '// View:\n// db.createView("new_view", "source_collection", [{$match: {}}])\n',
                                  database=path[1], title="new collection")
            if op == "drop":
                return sql_result("db.dropDatabase()", database=path[1], confirm=True)
        if kind == "index" and op == "drop":
            return sql_result("%s.dropIndex(%s)" % (self.coll_ref(path[2]), json.dumps(path[3])),
                              database=path[1], confirm=True)
        if kind == "coll":
            d, name = path[1], path[2]
            ref = self.coll_ref(name)
            if op == "drop":
                return sql_result("%s.drop()" % ref, database=d, confirm=True)
            if op == "create_index":
                return sql_result('%s.createIndex({field: 1}, {name: "field_1", unique: false})\n' % ref,
                                  database=d, title="new index")
            if op == "ddl":
                info = next(iter(self.client[d].list_collections(filter={"name": name})), None)
                if info is None:
                    raise ValueError("Collection %s not found" % name)
                opts = info.get("options", {})
                dump = lambda v: json_util.dumps(v, json_options=json_util.RELAXED_JSON_OPTIONS)
                if info.get("type") == "view":
                    sql = "db.createView(%s, %s, %s)\n" % (json.dumps(name), json.dumps(opts.get("viewOn", "")),
                                                            dump(opts.get("pipeline", [])))
                else:
                    sql = "db.createCollection(%s%s)\n" % (json.dumps(name), ", " + dump(opts) if opts else "")
                    for iname, spec in self.client[d][name].index_information().items():
                        if iname == "_id_":
                            continue
                        extra = {k: v for k, v in spec.items() if k not in ("key", "v", "ns")}
                        extra["name"] = iname
                        sql += "%s.createIndex(%s, %s)\n" % (ref, dump(dict(spec["key"])), dump(extra))
                return sql_result("// Definition of %s\n%s" % (name, sql), database=d, title=name)
        return super().object_sql(path, op)

    def parse_value(self, text):
        """Edited cells accept mongosh literals (numbers, true, {…}, ObjectId(…));
        anything that does not parse is stored as a string."""
        if text is None:
            return None
        try:
            p = JsParser(str(text), self.bson)
            value = p.value()
            if p.peek() == "":
                return value
        except Exception:
            pass
        return str(text)

    def table_data(self, path, where, order, desc, offset, limit):
        from bson import json_util
        t0 = time.time()
        coll = self.client[path[1]][path[2]]
        filt = self.parse_value(where) if where and where.strip() else {}
        if not isinstance(filt, dict):
            raise ValueError("The filter must be an object, e.g. {age: {$gt: 18}}")
        cur = coll.find(filt).skip(int(offset or 0)).limit(limit + 1)
        if order:
            cur = cur.sort(order, -1 if desc else 1)
        docs = list(cur)
        res = self.docs_result(docs[:limit], limit, time.time() - t0, "")
        view = any(c.get("type") == "view" for c in self.client[path[1]].list_collections(filter={"name": path[2]}))
        editable = not view
        res.update({
            "keys": [{"_id": json_util.dumps(d.get("_id"))} for d in docs[:limit]],
            "types": [""] * len(res["columns"]),
            "colEditable": [editable and c != "_id" for c in res["columns"]],
            "editable": editable, "readonlyReason": "" if editable else "Views are read-only",
            "keyColumns": ["_id"], "hasMore": len(docs) > limit, "offset": int(offset or 0),
        })
        return res

    def apply_changes(self, path, changes):
        from bson import json_util
        coll = self.client[path[1]][path[2]]
        done = 0
        for ch in changes:
            op = ch.get("op")
            values = {k: self.parse_value(v) for k, v in (ch.get("values") or {}).items()}
            if op == "insert":
                coll.insert_one(values)
            else:
                key = {"_id": json_util.loads(ch["key"]["_id"])}
                if op == "update":
                    r = coll.update_one(key, {"$set": values})
                    if r.matched_count == 0:
                        raise RuntimeError("Document %s not found (deleted meanwhile?)" % ch["key"]["_id"])
                elif op == "delete":
                    coll.delete_one(key)
            done += 1
        return {"applied": done, "affected": done}

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
            m = re.match(r"\s*db\s*\.\s*(createCollection|createView|dropDatabase)\s*(?=\()", s)
            if m:
                p = JsParser(s, self.bson)
                p.i = m.end()
                a = p.args()
                if m.group(1) == "createCollection":
                    db.create_collection(a[0], **(a[1] if len(a) > 1 else {}))
                    msg = "Created collection %s" % a[0]
                elif m.group(1) == "createView":
                    db.create_collection(a[0], viewOn=a[1], pipeline=a[2] if len(a) > 2 else [])
                    msg = "Created view %s" % a[0]
                else:
                    self.client.drop_database(db.name)
                    msg = "Dropped database %s" % db.name
                results.append(message_result(msg, time.time() - t0, s))
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
        if method == "dropIndex":
            coll.drop_index(args[0] if isinstance(args[0], str) else list(args[0].items()))
            return message_result("Dropped index %s" % args[0], clock() - t0, stmt)
        if method == "drop":
            coll.drop()
            return message_result("Dropped %s" % coll.name, clock() - t0, stmt)
        raise ValueError("Unsupported collection method: %s" % method)


