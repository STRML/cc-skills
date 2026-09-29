#!/usr/bin/env python3
"""dash.py: create and update a live progress dashboard (index.html + state.js).

The page is a fixed renderer; everything task-specific lives in state.json,
mirrored to state.js (file:// pages cannot fetch JSON) on every write. Writes are
atomic and serialized with a lock, so the main session and subagents can update
the same dashboard. Every timestamp is the real local clock.

Dashboard dir: --dir, else $DASH_DIR, else <git toplevel>/.dashboard/<name>
(name defaults to "main"), else ./.dashboard/<name>.

  dash.py init "Title" [--short S] [--context C] [--task "Title :: detail"]... [--force]
  dash.py task add "Title" [--detail D] [--after 3,4]   dash.py task set N STATUS [--detail D] [--title T]
  dash.py dep N 3,4   (task N waits for tasks 3 and 4; "" clears)  -> the page draws serial/parallel steps
  dash.py start N    (marks N doing, any other doing task goes back to todo unless --keep)
  dash.py done N [--detail D]                      STATUS: todo doing done blocked skipped
  dash.py ask "Question?" --default "What I do meanwhile"   -> prints question id
  dash.py answer QID "Sam's answer"                dash.py inbox   (answers Sam gave on the page)
  dash.py withdraw QID   (drop a question that no longer applies)
  dash.py block "What is stuck" -> prints id       dash.py unblock BID
  dash.py ship "Deliverable" [--link URL]          dash.py log "One line of activity"
  dash.py metric "Label" VALUE [--total N] [--note T]   (max 2 shown; --rm to remove)
  dash.py status on_track|at_risk|blocked|finished   dash.py set [--title T] [--short S] [--context C] [--repo R]
  dash.py show   (prints a one-screen text summary)   dash.py path   (prints index.html path)
  dash.py serve [--port P]   (serves the page on 127.0.0.1 so Sam can answer questions on it)

Answers Sam types on the served page are printed to stderr by the next dash.py command.
"""
import argparse, fcntl, json, os, re, shutil, subprocess, sys, tempfile, zlib
from datetime import datetime

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(SKILL_DIR, "assets", "index.html")
TASK_STATES = ("todo", "doing", "done", "blocked", "skipped")
RUN_STATES = ("on_track", "at_risk", "blocked", "finished")


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def git_top():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def repo_name(d):
    """Name of the repo the dashboard sits in (the main checkout's name, also from a worktree)."""
    try:
        out = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                             capture_output=True, text=True, cwd=d, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            common = out.stdout.strip().rstrip("/")
            if os.path.basename(common) == ".git":
                common = os.path.dirname(common)
            return os.path.basename(common).removesuffix(".git")
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def github_slug(d):
    """owner/repo from the origin remote, for #N links on the page ("" when not on GitHub)."""
    try:
        out = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, cwd=d, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$", out.stdout.strip())
    return m.group(1) if m else ""


def resolve_dir(args):
    if args.dir:
        return os.path.abspath(args.dir)
    if os.environ.get("DASH_DIR"):
        return os.path.abspath(os.environ["DASH_DIR"])
    top = git_top()
    return os.path.join(top or os.getcwd(), ".dashboard", args.name)


def exclude_from_git(d):
    """Keep .dashboard/ out of `git status` without touching tracked .gitignore."""
    top = git_top()
    if not top or not os.path.abspath(d).startswith(os.path.join(top, ".dashboard")):
        return
    try:
        gd = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True, cwd=top, timeout=5).stdout.strip()
        excl = os.path.join(top if not os.path.isabs(gd) else "", gd, "info", "exclude")
        os.makedirs(os.path.dirname(excl), exist_ok=True)
        lines = open(excl).read().splitlines() if os.path.exists(excl) else []
        if "/.dashboard/" not in lines:
            with open(excl, "a") as f:
                f.write("\n/.dashboard/\n")
    except (OSError, subprocess.SubprocessError):
        pass


class State:
    def __init__(self, d):
        self.d = d
        self.path = os.path.join(d, "state.json")
        self.lock = None
        self.s = None

    def __enter__(self):
        os.makedirs(self.d, exist_ok=True)
        self.lock = open(os.path.join(self.d, ".lock"), "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        if os.path.exists(self.path):
            with open(self.path) as f:
                self.s = json.load(f)
        return self

    def save(self, touch=True):
        if touch:
            self.s["updated"] = now()
        body = json.dumps(self.s, indent=2, ensure_ascii=False)
        for name, text in (("state.json", body + "\n"), ("state.js", "window.DASH = " + body + ";\n")):
            fd, tmp = tempfile.mkstemp(dir=self.d, prefix="." + name)
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp, os.path.join(self.d, name))

    def __exit__(self, *exc):
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()


def need(st):
    if st.s is None:
        sys.exit(f"dash: no dashboard at {st.d}; run `dash.py init \"Title\"` first")
    return st.s


def task_at(s, n):
    try:
        i = int(n) - 1
        if 0 <= i < len(s["tasks"]):
            return s["tasks"][i]
    except ValueError:
        pass
    sys.exit(f"dash: no task {n} (have 1..{len(s['tasks'])})")


def parse_task(spec):
    title, _, detail = spec.partition("::")
    return {"title": title.strip(), "detail": detail.strip(), "status": "todo"}


def parse_after(s, spec, n):
    """'3,4' -> [3, 4]; every number must name another existing task."""
    out = []
    for part in filter(None, (p.strip() for p in spec.replace(" ", ",").split(","))):
        if not part.isdigit() or not 1 <= int(part) <= len(s["tasks"]) or int(part) == n:
            sys.exit(f"dash: bad dependency {part!r} for task {n}")
        out.append(int(part))
    out = sorted(set(out))
    # Reject a cycle: walking the dependencies from the new ones must never reach task n.
    stack, seen = list(out), set()
    while stack:
        j = stack.pop()
        if j == n:
            sys.exit(f"dash: dependency cycle: task {n} would wait on itself")
        if j not in seen:
            seen.add(j)
            stack.extend(s["tasks"][j - 1].get("after", []) if j <= len(s["tasks"]) else [])
    return out


def next_id(items, prefix):
    nums = [int(i["id"][len(prefix):]) for i in items if str(i.get("id", "")).startswith(prefix) and i["id"][len(prefix):].isdigit()]
    return f"{prefix}{max(nums, default=0) + 1}"


def main():
    p = argparse.ArgumentParser(prog="dash.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dir")
    p.add_argument("--name", default="main")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("init"); a.add_argument("title"); a.add_argument("--short"); a.add_argument("--context", default="")
    a.add_argument("--task", action="append", default=[]); a.add_argument("--force", action="store_true")
    t = sub.add_parser("task"); ts = t.add_subparsers(dest="op", required=True)
    x = ts.add_parser("add"); x.add_argument("title"); x.add_argument("--detail", default=""); x.add_argument("--after", default="")
    x = sub.add_parser("dep"); x.add_argument("n"); x.add_argument("after")
    x = ts.add_parser("set"); x.add_argument("n"); x.add_argument("status", choices=TASK_STATES)
    x.add_argument("--detail"); x.add_argument("--title")
    x = sub.add_parser("start"); x.add_argument("n"); x.add_argument("--keep", action="store_true")
    x = sub.add_parser("done"); x.add_argument("n"); x.add_argument("--detail")
    x = sub.add_parser("ask"); x.add_argument("q"); x.add_argument("--default", required=True)
    x = sub.add_parser("answer"); x.add_argument("qid"); x.add_argument("answer")
    x = sub.add_parser("withdraw"); x.add_argument("qid")
    x = sub.add_parser("block"); x.add_argument("text")
    x = sub.add_parser("unblock"); x.add_argument("bid")
    x = sub.add_parser("ship"); x.add_argument("text"); x.add_argument("--link")
    x = sub.add_parser("log"); x.add_argument("text")
    x = sub.add_parser("metric"); x.add_argument("label"); x.add_argument("value", nargs="?")
    x.add_argument("--total"); x.add_argument("--note"); x.add_argument("--rm", action="store_true")
    x = sub.add_parser("status"); x.add_argument("value", choices=RUN_STATES)
    x = sub.add_parser("set"); x.add_argument("--title"); x.add_argument("--short"); x.add_argument("--context"); x.add_argument("--repo"); x.add_argument("--github", help="owner/repo for #N links")
    sub.add_parser("show"); sub.add_parser("path"); sub.add_parser("inbox")
    x = sub.add_parser("serve"); x.add_argument("--port", type=int)
    args = p.parse_args()

    d = resolve_dir(args)
    html = os.path.join(d, "index.html")
    if args.cmd == "path":
        print(html); return
    if args.cmd == "serve":
        if not os.path.exists(os.path.join(d, "state.json")):
            sys.exit(f"dash: no dashboard at {d}")
        shutil.copyfile(TEMPLATE, html)
        serve(d, args.port or default_port(d)); return

    with State(d) as st:
        if args.cmd == "init":
            if st.s is not None and not args.force:
                sys.exit(f"dash: {st.d} already has a dashboard (use --force to replace)")
            st.s = {"title": args.title, "short": args.short or args.title[:40], "context": args.context,
                    "status": "on_track", "started": now(), "tasks": [parse_task(x) for x in args.task],
                    "questions": [], "blockers": [], "deliverables": [], "metrics": [], "log": [],
                    "repo": repo_name(d), "github": github_slug(d)}
            shutil.copyfile(TEMPLATE, html)
            exclude_from_git(d)
            st.save()
            print(html); return

        s = need(st)
        if "repo" not in s:
            s["repo"] = repo_name(d)
        if "github" not in s:
            s["github"] = github_slug(d)
        if not os.path.exists(html) or os.path.getmtime(html) < os.path.getmtime(TEMPLATE):
            shutil.copyfile(TEMPLATE, html)  # pick up renderer fixes
        out = None
        c = args.cmd
        if c == "task" and args.op == "add":
            s["tasks"].append({"title": args.title, "detail": args.detail, "status": "todo"}); out = str(len(s["tasks"]))
            if args.after: s["tasks"][-1]["after"] = parse_after(s, args.after, len(s["tasks"]))
        elif c == "dep":
            task_at(s, args.n)["after"] = parse_after(s, args.after, int(args.n))
        elif c == "task":
            tk = task_at(s, args.n); tk["status"] = args.status
            if args.detail is not None: tk["detail"] = args.detail
            if args.title: tk["title"] = args.title
        elif c == "start":
            tk = task_at(s, args.n)
            if not args.keep:
                for o in s["tasks"]:
                    if o is not tk and o["status"] == "doing": o["status"] = "todo"
            tk["status"] = "doing"
        elif c == "done":
            tk = task_at(s, args.n); tk["status"] = "done"
            if args.detail is not None: tk["detail"] = args.detail
        elif c == "ask":
            out = next_id(s["questions"], "q")
            s["questions"].append({"id": out, "q": args.q, "default": args.default, "status": "default", "at": now()})
        elif c == "answer":
            q = next((q for q in s["questions"] if q["id"] == args.qid), None) or sys.exit(f"dash: no question {args.qid}")
            q.update(status="answered", answer=args.answer, answered_at=now(), unread=False)
        elif c == "withdraw":
            before = len(s["questions"])
            s["questions"] = [q for q in s["questions"] if q["id"] != args.qid]
            if len(s["questions"]) == before: sys.exit(f"dash: no question {args.qid}")
        elif c == "inbox":
            if report_inbox(s):
                st.save(touch=False)
            else:
                print("no new answers")
            return
        elif c == "block":
            out = next_id(s["blockers"], "b")
            s["blockers"].append({"id": out, "text": args.text, "at": now()})
            if s["status"] == "on_track": s["status"] = "at_risk"
        elif c == "unblock":
            b = next((b for b in s["blockers"] if b["id"] == args.bid), None) or sys.exit(f"dash: no blocker {args.bid}")
            b["cleared"] = now()
            if not [b for b in s["blockers"] if not b.get("cleared")] and s["status"] in ("at_risk", "blocked"):
                s["status"] = "on_track"
        elif c == "ship":
            s["deliverables"].append({"text": args.text, "link": args.link, "at": now()})
        elif c == "log":
            s["log"] = (s["log"] + [{"text": args.text, "at": now()}])[-50:]
        elif c == "metric":
            s["metrics"] = [m for m in s["metrics"] if m["label"] != args.label]
            if not args.rm:
                if args.value is None: sys.exit("dash: metric needs VALUE (or --rm)")
                s["metrics"].append({"label": args.label, "value": args.value, "total": args.total, "note": args.note})
        elif c == "status":
            s["status"] = args.value
        elif c == "set":
            for k in ("title", "short", "context", "repo", "github"):
                if getattr(args, k) is not None: s[k] = getattr(args, k)
        elif c == "show":
            report_inbox(s)
            done = sum(t["status"] in ("done", "skipped") for t in s["tasks"])
            print(f"{s['title']}  [{s['status']}]  {done}/{len(s['tasks'])} done  updated {s.get('updated','')}")
            glyph = {"done": "✓", "doing": "◐", "todo": "○", "blocked": "⏸", "skipped": "-"}
            for i, tk in enumerate(s["tasks"], 1):
                print(f"  {glyph[tk['status']]} {i:>2}  {tk['title']}")
            for q in s["questions"]:
                if q["status"] != "answered": print(f"  ⚠ {q['id']}  {q['q']}  (default: {q['default']})")
            for b in s["blockers"]:
                if not b.get("cleared"): print(f"  ✗ {b['id']}  {b['text']}")
            print(html)
            st.save(touch=False); return
        report_inbox(s)
        st.save()
        print(out or "ok")


def report_inbox(s):
    """Print answers Sam gave on the page since the last command (stderr, so >/dev/null keeps them)."""
    new = [q for q in s["questions"] if q.get("unread")]
    for q in new:
        print(f"ANSWER FROM SAM {q['id']}: {q['q']}\n  -> {q['answer']}", file=sys.stderr)
        q["unread"] = False
    return bool(new)


def default_port(d):
    return 8700 + zlib.crc32(d.encode()) % 200


def serve(d, port):
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=d, **kw)

        def log_message(self, *a):
            pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def do_POST(self):
            # The custom header forces a CORS preflight this server never grants,
            # so no other site open in the browser can post answers.
            if self.path != "/api/answer" or self.headers.get("X-Dash") != "1":
                self.send_error(403); return
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                qid, answer = str(body["id"]), str(body["answer"]).strip()
            except (ValueError, KeyError):
                self.send_error(400); return
            if not answer:
                self.send_error(400); return
            with State(d) as st:
                q = next((q for q in (st.s or {}).get("questions", []) if q["id"] == qid), None)
                if q is None:
                    self.send_error(404); return
                q.update(status="answered", answer=answer, answered_at=now(), unread=True, via="dashboard")
                st.s["log"] = (st.s["log"] + [{"text": f"Sam answered {qid} on the dashboard", "at": now()}])[-50:]
                st.save()
            self.send_response(204); self.end_headers()

    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"serving {d} at http://127.0.0.1:{port}/", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
