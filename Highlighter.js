.pragma library

// Syntax highlighting for the query editor. toHtml() returns rich text drawn
// underneath the (transparent) editor text, so it must keep every character
// in place: tokens are only wrapped in colored spans, whitespace is preserved
// by `white-space: pre`.

var MAX_LENGTH = 200000

function wordSet(s) {
  var o = {}
  s.split(/\s+/).forEach(function(w) { if (w) o[w] = true })
  return o
}

var SQL_KEYWORDS = wordSet(
  "add after all alter analyze and any array as asc authorization before begin between body by call cascade case " +
  "cast charset check collate column comment commit concurrently constraint continue create cross current cursor " +
  "database declare default deferrable definer delete delimiter desc deterministic distinct do drop each else elsif " +
  "end engine event every except exception exec execute exists explain fetch final first for foreign format from full " +
  "function global grant group having if ilike immutable in index inner insert instead intersect into is isnull join " +
  "key language lateral leading left like limit local loop materialized merge modify natural next no not notice notnull " +
  "nulls of offset on only or order out outer over package partition perform prepare primary procedure raise " +
  "recursive references refresh rename replace restrict return returning returns revoke right rollback row rows " +
  "sample schedule schema select sequence set settings show some stable start strict table temp temporary then to " +
  "trailing transaction trigger truncate ttl type union unique update use using values view volatile when where while " +
  "window with within")

var SQL_LITERALS = wordSet("null true false unknown default current_date current_time current_timestamp localtimestamp sysdate systimestamp")

var SQL_TYPES = wordSet(
  "bigint bigserial binary bit blob bool boolean box bytea char character cidr clob date datetime datetime64 dec " +
  "decimal double enum enum8 enum16 fixedstring float float32 float64 inet int int2 int4 int8 int16 int32 int64 " +
  "int128 int256 integer interval json jsonb longblob longtext lowcardinality map mediumint mediumtext money nchar " +
  "nullable number numeric nvarchar nvarchar2 point precision raw real serial smallint smallserial string text time " +
  "timestamp timestamptz timetz tinyint tinytext tuple uint8 uint16 uint32 uint64 uint128 uint256 uuid varbinary " +
  "varchar varchar2 varying xml year zone")

var MONGO_LITERALS = wordSet("true false null undefined new")

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function span(text, color, italic, bold) {
  var style = "color:" + color + (italic ? ";font-style:italic" : "") + (bold ? ";font-weight:600" : "")
  return '<span style="' + style + '">' + esc(text) + "</span>"
}

// colors: { keyword, type, func, string, number, comment, ident, param, punct, text }
function toHtml(text, dialect, colors) {
  if (!text) return ""
  if (text.length > MAX_LENGTH) return '<div style="white-space:pre">' + esc(text) + "</div>"
  var out
  if (dialect === "redis") out = redis(text, colors)
  else if (dialect === "mongodb") out = mongo(text, colors)
  else out = sql(text, dialect, colors)
  // A trailing newline would be dropped by the rich text layout.
  return '<div style="white-space:pre">' + out + (text.slice(-1) === "\n" ? "&nbsp;" : "") + "</div>"
}

function sql(s, dialect, c) {
  var out = [], i = 0, n = s.length, m
  var word = /[A-Za-z_À-￿][\w$À-￿]*/y
  var num = /(0x[0-9a-fA-F]+|\d+\.?\d*(e[+-]?\d+)?|\.\d+(e[+-]?\d+)?)/iy
  while (i < n) {
    var ch = s[i]
    if (ch === "-" && s[i + 1] === "-" || (ch === "#" && dialect === "mysql")) {
      var e = s.indexOf("\n", i)
      e = e < 0 ? n : e
      out.push(span(s.slice(i, e), c.comment, true))
      i = e
    } else if (ch === "/" && s[i + 1] === "*") {
      var e2 = s.indexOf("*/", i + 2)
      e2 = e2 < 0 ? n : e2 + 2
      out.push(span(s.slice(i, e2), c.comment, true))
      i = e2
    } else if (ch === "'" || ch === '"' || ch === "`") {
      var j = i + 1
      while (j < n) {
        if (s[j] === ch) { if (s[j + 1] === ch) { j += 2; continue } break }
        if (s[j] === "\\" && ch !== '"' && dialect === "mysql") { j += 2; continue }
        j++
      }
      j = Math.min(n, j + 1)
      out.push(span(s.slice(i, j), ch === "'" ? c.string : c.ident))
      i = j
    } else if (ch === "$" && dialect === "postgresql" && (m = /\$[A-Za-z_]*\$/y, m.lastIndex = i, m.exec(s))) {
      var tag = s.slice(i, m.lastIndex)
      out.push(span(tag, c.punct, false, true))
      i = m.lastIndex
    } else if ((ch === "$" || ch === ":" || ch === "@") && /[\w]/.test(s[i + 1] || "") && s[i - 1] !== ":") {
      var p = /[$:@]@?\w+/y
      p.lastIndex = i
      p.exec(s)
      out.push(span(s.slice(i, p.lastIndex), c.param))
      i = p.lastIndex
    } else if (/\d/.test(ch) || (ch === "." && /\d/.test(s[i + 1] || ""))) {
      num.lastIndex = i
      num.exec(s)
      out.push(span(s.slice(i, num.lastIndex), c.number))
      i = num.lastIndex
    } else if ((word.lastIndex = i, word.exec(s))) {
      var w = s.slice(i, word.lastIndex)
      var lw = w.toLowerCase()
      var k = word.lastIndex
      while (k < n && (s[k] === " " || s[k] === "\t")) k++
      if (SQL_LITERALS[lw]) out.push(span(w, c.number))
      else if (SQL_KEYWORDS[lw]) out.push(span(w, c.keyword, false, true))
      else if (SQL_TYPES[lw]) out.push(span(w, c.type))
      else if (s[k] === "(") out.push(span(w, c.func))
      else out.push(esc(w))
      i = word.lastIndex
    } else if (/[=<>!+\-*\/%|&^~,;().\[\]]/.test(ch)) {
      out.push(span(ch, c.punct))
      i++
    } else {
      out.push(esc(ch))
      i++
    }
  }
  return out.join("")
}

function redis(s, c) {
  return s.split("\n").map(function(line) {
    if (/^\s*(#|\/\/)/.test(line)) return span(line, c.comment, true)
    var out = [], i = 0, first = true
    while (i < line.length) {
      var ch = line[i]
      if (ch === " " || ch === "\t") { out.push(ch); i++; continue }
      var j = i
      if (ch === '"' || ch === "'") {
        j++
        while (j < line.length && line[j] !== ch) j += line[j] === "\\" ? 2 : 1
        j = Math.min(line.length, j + 1)
        out.push(span(line.slice(i, j), c.string))
      } else {
        while (j < line.length && line[j] !== " " && line[j] !== "\t") j++
        var tok = line.slice(i, j)
        if (first) out.push(span(tok, c.keyword, false, true))
        else if (/^-?\d+(\.\d+)?$/.test(tok)) out.push(span(tok, c.number))
        else if (/^[A-Z]{2,}$/.test(tok)) out.push(span(tok, c.type))
        else out.push(esc(tok))
      }
      first = false
      i = j
    }
    return out.join("")
  }).join("\n")
}

function mongo(s, c) {
  var out = [], i = 0, n = s.length
  var ident = /[A-Za-z_$][\w$]*/y
  while (i < n) {
    var ch = s[i]
    if (ch === "/" && s[i + 1] === "/") {
      var e = s.indexOf("\n", i)
      e = e < 0 ? n : e
      out.push(span(s.slice(i, e), c.comment, true))
      i = e
    } else if (ch === "/" && s[i + 1] === "*") {
      var e2 = s.indexOf("*/", i + 2)
      e2 = e2 < 0 ? n : e2 + 2
      out.push(span(s.slice(i, e2), c.comment, true))
      i = e2
    } else if (ch === '"' || ch === "'") {
      var j = i + 1
      while (j < n && s[j] !== ch && s[j] !== "\n") j += s[j] === "\\" ? 2 : 1
      j = Math.min(n, j + 1)
      var k = j
      while (k < n && (s[k] === " " || s[k] === "\t")) k++
      out.push(span(s.slice(i, j), s[k] === ":" ? c.ident : c.string))
      i = j
    } else if (/\d/.test(ch) || (ch === "-" && /\d/.test(s[i + 1] || "") && /[\s,:\[(]/.test(s[i - 1] || " "))) {
      var m = /-?\d+\.?\d*(e[+-]?\d+)?/iy
      m.lastIndex = i
      m.exec(s)
      out.push(span(s.slice(i, m.lastIndex), c.number))
      i = m.lastIndex
    } else if ((ident.lastIndex = i, ident.exec(s))) {
      var w = s.slice(i, ident.lastIndex)
      var k2 = ident.lastIndex
      while (k2 < n && (s[k2] === " " || s[k2] === "\t")) k2++
      if (w[0] === "$") out.push(span(w, c.keyword, false, true))
      else if (MONGO_LITERALS[w]) out.push(span(w, c.number))
      else if (s[k2] === ":") out.push(span(w, c.ident))
      else if (s[k2] === "(") out.push(span(w, c.func))
      else if (w === "db" || w === "show" || w === "use") out.push(span(w, c.keyword, false, true))
      else out.push(esc(w))
      i = ident.lastIndex
    } else if (/[{}\[\](),.:;]/.test(ch)) {
      out.push(span(ch, c.punct))
      i++
    } else {
      out.push(esc(ch))
      i++
    }
  }
  return out.join("")
}
