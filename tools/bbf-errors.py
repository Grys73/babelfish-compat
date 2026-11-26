#!/usr/bin/env python3
"""Collect and report T-SQL errors from the Babelfish container log.

  bbf-errors collect               append new ERROR events from `docker logs` to the store
  bbf-errors report [options]      group the stored events into a list of distinct problems

The container log is lost when the container is recreated (new image), so `collect` runs
from a timer and keeps every event in STORE (JSON lines). Each event is one ERROR with the
QUERY/STATEMENT/CONTEXT/DETAIL lines PostgreSQL writes after it for the same backend.
Needs log_line_prefix = '%m [%p] %u@%d app=%a ' for the user and app columns (older lines
are kept without them). Passwords in statements are masked before they are stored.
"""
import argparse, hashlib, json, os, re, subprocess, sys
from collections import OrderedDict
from datetime import datetime, timedelta, timezone

CONTAINER = os.environ.get("BBF_CONTAINER", "bbf")
STORE = os.environ.get("BBF_ERRORS_STORE", "/var/lib/bbf-errors/events.jsonl")
OVERLAP = timedelta(seconds=90)  # re-read this much before the last event; duplicates are dropped

REC = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) UTC \[(\d+)\] (?:(\S*)@(\S*) app=(\S*) )?"
                 r"([A-Z]+):  (.*)$")
ATTACH = {"QUERY", "STATEMENT", "CONTEXT", "DETAIL", "HINT", "LOCATION"}
PROC = re.compile(r"PL/tsql function (\S+?)(?:\(\))? line (\d+)")
SECRET = re.compile(r"(PASSWORD\s*=?\s*N?)'(?:[^']|'')*'", re.I)
# psql sessions of the admins and the probes run while testing; --all keeps them
NOISE_USERS = {"postgres", ""}
NOISE_APPS = re.compile(r"^(psql|verify\d*|strict-verify|lang-probe|logprobe\d*|probe\d*)$")


def mask(s):
    return SECRET.sub(r"\1'***'", s) if s else s


def parse(lines):
    """Yield events from PostgreSQL log lines (records may continue on tab-indented lines)."""
    open_ev = {}  # pid -> event still taking QUERY/CONTEXT lines
    last = None   # record the continuation lines belong to

    def close(pid):
        ev = open_ev.pop(pid, None)
        if ev:
            for k in ("query", "statement", "context", "detail"):
                ev[k] = mask(ev.get(k))
            ev["key"] = hashlib.sha1(f"{ev['ts']}|{ev['pid']}|{ev['error']}".encode()).hexdigest()[:16]
            return ev

    for raw in lines:
        line = raw.rstrip("\n")
        m = REC.match(line)
        if not m:
            if last is not None and line.startswith("\t"):
                last["text"] += "\n" + line[1:]
                ev = open_ev.get(last["pid"])
                if ev is not None and last["field"]:
                    ev[last["field"]] = (ev.get(last["field"]) or "") + "\n" + line[1:]
            continue
        ts, pid, user, db, app, level, text = m.groups()
        if level == "ERROR" or level not in ATTACH:
            done = close(pid)
            if done:
                yield done
        field = None
        if level == "ERROR":
            open_ev[pid] = {"ts": ts, "pid": int(pid), "user": user, "db": db, "app": app, "error": text}
            field = "error"
        elif level in ATTACH and pid in open_ev:
            field = level.lower()
            ev = open_ev[pid]
            ev[field] = (ev[field] + "\n" + text) if ev.get(field) else text
        last = {"pid": pid, "field": field, "text": text}
    for pid in list(open_ev):
        yield close(pid)


def read_store():
    if not os.path.exists(STORE):
        return []
    with open(STORE, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def cmd_collect(_):
    events = read_store()
    args = ["docker", "logs", CONTAINER]
    seen = set()
    if events:
        last = max(datetime.strptime(e["ts"], "%Y-%m-%d %H:%M:%S.%f") for e in events)
        since = (last - OVERLAP).replace(tzinfo=timezone.utc)
        args[2:2] = ["--since", since.strftime("%Y-%m-%dT%H:%M:%SZ")]
        floor = since.strftime("%Y-%m-%d %H:%M:%S")
        seen = {e["key"] for e in events if e["ts"] >= floor}
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         encoding="utf-8", errors="replace")
    new = [e for e in parse(p.stdout) if e["key"] not in seen]
    if p.wait() != 0:
        sys.exit(f"bbf-errors: docker logs {CONTAINER} failed ({p.returncode})")
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    with open(STORE, "a", encoding="utf-8") as f:
        for e in new:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    os.chmod(STORE, 0o600)
    print(f"bbf-errors: {len(new)} new events, {len(events) + len(new)} stored")


def shape(s):
    """Statement or message with literals and numbers taken out, so repeats group together."""
    if not s:
        return ""
    s = re.sub(r"N?'(?:[^']|'')*'", "'…'", s)
    s = re.sub(r"\"[^\"]*\"", "\"…\"", s) if s.startswith(("relation", "column", "table", "procedure", "function")) else s
    s = re.sub(r"\b\d+(\.\d+)?\b", "N", s)
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"\s+", " ", s).strip()


def category(err):
    e = err.lower()
    if "not currently supported" in e or "not supported" in e:
        return "unsupported"
    if "does not exist" in e:
        return "missing object"
    if "syntax error" in e:
        return "syntax"
    if "permission" in e:
        return "permission"
    if "out of range" in e or "invalid input" in e or "conversion" in e:
        return "data/conversion"
    return "other"


def cmd_report(a):
    events = read_store()
    if a.since:
        events = [e for e in events if e["ts"] >= a.since]
    if not a.all:
        events = [e for e in events if (e.get("user") or "") not in NOISE_USERS and not NOISE_APPS.match(e.get("app") or "")
                  or e.get("user") is None and not a.no_old]
    if a.user:
        events = [e for e in events if re.search(a.user, e.get("user") or "", re.I)]
    if a.app:
        events = [e for e in events if re.search(a.app, e.get("app") or "", re.I)]
    if a.exclude_app:
        events = [e for e in events if not re.search(a.exclude_app, e.get("app") or "", re.I)]
    groups = OrderedDict()
    for e in sorted(events, key=lambda e: e["ts"]):
        proc = PROC.search(e.get("context") or "")
        where = f"{proc.group(1)}:{proc.group(2)}" if proc and proc.group(1) != "inline_code_block" else ""
        k = (shape(re.sub(r" at character \d+", "", e["error"])), shape(e.get("query") or e.get("statement")), where)
        g = groups.setdefault(k, {"n": 0, "first": e["ts"], "users": set(), "apps": set(), "sample": e, "where": where})
        g["n"] += 1
        g["last"] = e["ts"]
        g["users"].add(e.get("user") or "?")
        g["apps"].add(e.get("app") or "?")
    rows = sorted(groups.values(), key=lambda g: (category(g["sample"]["error"]), -g["n"]))
    if a.json:
        print(json.dumps([{"category": category(g["sample"]["error"]), "count": g["n"], "first": g["first"], "last": g["last"],
                           "users": sorted(g["users"]), "apps": sorted(g["apps"]), "where": g["where"],
                           "error": g["sample"]["error"], "query": g["sample"].get("query") or g["sample"].get("statement"),
                           "detail": g["sample"].get("detail")} for g in rows], ensure_ascii=False, indent=1))
        return
    print(f"# Babelfish errors: {len(rows)} distinct, {sum(g['n'] for g in rows)} events"
          + (f" since {a.since}" if a.since else "") + "\n")
    cat = None
    for g in rows:
        c = category(g["sample"]["error"])
        if c != cat:
            cat = c
            print(f"\n## {c}\n")
        e = g["sample"]
        q = (e.get("query") or e.get("statement") or "(statement not logged)").strip()
        if len(q) > a.width:
            q = q[:a.width] + " …"
        print(f"- **{e['error'][:300]}** × {g['n']}  ({g['first'][:16]} … {g['last'][:16]})")
        print(f"  users: {', '.join(sorted(g['users']))}; apps: {', '.join(sorted(g['apps']))}"
              + (f"; in {g['where']}" if g["where"] else ""))
        print("  ```sql\n  " + q.replace("\n", "\n  ") + "\n  ```")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("collect", help="append new events from the container log")
    r = sub.add_parser("report", help="distinct problems, grouped by category")
    r.add_argument("--since", help="'YYYY-MM-DD[ HH:MM]' (UTC)")
    r.add_argument("--user", help="regex on the login, e.g. stricttest")
    r.add_argument("--app", help="regex on the application name")
    r.add_argument("--exclude-app", help="regex of application names to leave out")
    r.add_argument("--all", action="store_true", help="keep postgres/psql and test-probe sessions")
    r.add_argument("--no-old", action="store_true", help="leave out lines logged before the user/app prefix")
    r.add_argument("--json", action="store_true")
    r.add_argument("--width", type=int, default=600, help="cut statements longer than this")
    a = ap.parse_args()
    {"collect": cmd_collect, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
