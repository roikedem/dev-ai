#!/usr/bin/env python3
"""
Pipeline watchdog — alerts when an autonomous-pipeline issue is stuck.

A healthy pipeline moves an assigned issue To Do -> In Progress -> Review within
a couple of 2-min dispatch cycles. If an issue sits in To Do or In Progress well
past that, the worker either never advanced it (e.g. TRIP-1 blocked on the MCP,
2026-07-17) or it is genuinely blocked waiting on Roi (e.g. ZRM-36). Either way
Roi should hear about it — once — not every dispatch.

Scope: "the worker never produced anything." If the issue already has a PR linked,
the solver *did* run and the problem is merge/reconcile — reconcile.py owns that
case and reports it, so the watchdog stays out of it (2026-07-30: it was firing on
TRIP-45/59, whose PRs are open-but-unmergeable, and on PAN-205, whose PR was closed
as superseded).

Output goes to the shared team log, not to Roi. Per-item mail to Roi is against the
standing one-briefing rule — anything Roi actually needs reaches him through the
08:30 standup, which reads the Project Manager's status.md.

Dedup: state file records the last alert per issue. A stuck issue is re-logged
only when it is newly stuck, its status changed, or RE_ALERT_HOURS have passed.
Resolved issues drop out of state silently.

Run from cron (e.g. every 15 min). --dry-run prints instead of logging/writing state.
"""
import json, os, sys, subprocess, urllib.parse, urllib.request, base64
from datetime import datetime, timezone

# --- thresholds -------------------------------------------------------------
TODO_STUCK_MIN       = 240     # To Do this long => worker never picked it up.
                               # 20m was too tight: it fired on TRIP-71 at 27m,
                               # which the pipeline picked up and shipped 25m later.
                               # 120m was still too tight: on 31.7 it flagged
                               # TRIP-76 and TRIP-77 at ~2h and both merged 70 and
                               # 95 min after the alert. On a busy day the pipeline
                               # turns a ticket around in ~3h, so anything under
                               # that is noise.
INPROGRESS_STUCK_MIN = 480     # In Progress this long => stalled or blocked.
                               # A real solver run legitimately takes hours (TRIP-42
                               # ran 40h and shipped fine), so 90m flagged healthy
                               # builds every night. 8h is past any normal build.
RE_ALERT_HOURS       = 24      # don't re-nag a still-stuck issue before this
BLOCKED_MIN          = 30      # a blocked ticket goes to the Team Manager after this.
                               # 25.10.2026: FC-1/FC-2 sat ~5h "waiting for Roi" on a
                               # repo-access problem the TM fixed in a minute, unseen
                               # because the 8h In Progress limit had not passed.
TM_ALERT_DIR = os.path.join(os.path.expanduser("~"), "projects/team/logs/supervisor-alerts")

HOME        = os.path.expanduser("~")
DEV_AI      = os.path.join(HOME, "projects/dev-ai")
DEV_CONFIG  = os.path.join(HOME, ".config/dev-ai.json")
TOKEN_FILE  = os.path.join(HOME, ".config/atlassian-api-token")
STATE_FILE  = os.path.join(HOME, ".config/pipeline-watchdog-state.json")
EMAIL       = "roikedem+claudecode@gmail.com"
BASE        = "https://intotodev.atlassian.net"
BROWSE      = BASE + "/browse/"

DRY = "--dry-run" in sys.argv


def api(path):
    token = open(TOKEN_FILE).read().strip()
    auth = base64.b64encode(f"{EMAIL}:{token}".encode()).decode()
    req = urllib.request.Request(BASE + "/rest/api/3" + path,
                                 headers={"Authorization": "Basic " + auth,
                                          "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def parse_ts(s):
    # "2026-07-17T10:45:12.123+0300"
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z")


def minutes_since(ts):
    return (datetime.now(timezone.utc) - parse_ts(ts)).total_seconds() / 60.0


def enabled_projects():
    cfg = json.load(open(DEV_CONFIG))
    out = []
    for p in cfg.get("projects", []):
        if not p.get("enabled"):
            continue
        jp = os.path.join(p["dir"], ".jira-process.json")
        if os.path.exists(jp):
            out.append(json.load(open(jp)).get("jira_project_key"))
    return [k for k in out if k]


def has_pr(key):
    """True if the issue has a pull-request remote link.

    The solver attaches the PR link when it opens one. A PR — open, merged or
    closed — means the worker ran and produced something, so whatever is wrong is
    a merge or reconcile problem, not a pickup problem. reconcile.py reports those.
    On a lookup error assume a PR exists: staying quiet beats a false alert.
    """
    try:
        links = api(f"/issue/{key}/remotelink")
    except Exception as e:
        print(f"watchdog: remotelink lookup failed for {key}: {e}", file=sys.stderr)
        return True
    for l in links:
        url = (l.get("object") or {}).get("url", "")
        if "/pull/" in url:
            return True
    return False


def find_stuck():
    self_id = api("/myself")["accountId"]
    stuck = []
    for key in enabled_projects():
        jql = (f'project={key} AND assignee="{self_id}" '
               f'AND status in ("To Do","In Progress") ORDER BY updated DESC')
        q = urllib.parse.quote(jql)
        try:
            res = api(f"/search/jql?jql={q}&maxResults=50"
                      "&fields=summary,status,statuscategorychangedate")
        except Exception as e:
            print(f"watchdog: query failed for {key}: {e}", file=sys.stderr)
            continue
        for it in res.get("issues", []):
            f = it["fields"]
            status = f["status"]["name"]
            age = minutes_since(f["statuscategorychangedate"])
            limit = TODO_STUCK_MIN if status == "To Do" else INPROGRESS_STUCK_MIN
            if age < limit:
                continue
            if has_pr(it["key"]):
                continue
            cause = ("queued but the worker never moved it to In Progress"
                     if status == "To Do"
                     else "claimed but never reached Review — blocked or erroring")
            stuck.append({"key": it["key"], "status": status,
                          "summary": f.get("summary", ""),
                          "age_min": round(age), "cause": cause})
    return stuck


def adf_text(node):
    if isinstance(node, dict):
        if node.get("type") == "text":
            return node.get("text", "")
        if node.get("type") == "mention":
            return (node.get("attrs") or {}).get("text", "") + " "
        return "".join(adf_text(c) for c in node.get("content", []) or [])
    if isinstance(node, list):
        return "".join(adf_text(c) for c in node)
    return node if isinstance(node, str) else ""


def find_blocked():
    """Agent tickets waiting on someone: labelled `blocked` (PROCESS-TASK 3b), or —
    for an agent that forgot the label — whose newest comment is the agent's own,
    mentions Roi, and is older than BLOCKED_MIN with no PR attached."""
    self_id = api("/myself")["accountId"]
    out = []
    for key in enabled_projects():
        jql = (f'project={key} AND assignee="{self_id}" '
               f'AND status in ("To Do","In Progress")')
        try:
            res = api(f"/search/jql?jql={urllib.parse.quote(jql)}&maxResults=50"
                      "&fields=summary,status,labels,comment")
        except Exception as e:
            print(f"watchdog: blocked query failed for {key}: {e}", file=sys.stderr)
            continue
        for it in res.get("issues", []):
            f = it["fields"]
            comments = (f.get("comment") or {}).get("comments", [])
            last = comments[-1] if comments else None
            labelled = "blocked" in (f.get("labels") or [])
            asked = (last and last["author"]["accountId"] == self_id
                     and "@Roi" in adf_text(last.get("body")))
            if not (labelled or asked):
                continue
            if last and minutes_since(last["created"]) < BLOCKED_MIN:
                continue
            if not labelled and has_pr(it["key"]):
                continue
            why = adf_text(last.get("body"))[:500] if last else "(no comment)"
            out.append({"key": it["key"], "status": f["status"]["name"],
                        "summary": f.get("summary", ""), "labelled": labelled,
                        "why": why, "since": last["created"] if last else ""})
    return out


def alert_tm_blocked(items, state):
    """Hand newly blocked tickets to the Team Manager (same drop dir the Supervisor
    uses; supervisor-alerts.sh runs a headless TM on it). Once per ticket per block."""
    new = {}
    for i in items:
        sk = "blocked:" + i["key"]
        if state.get(sk) == i["since"]:
            continue
        state[sk] = i["since"]
        new[sk] = (f'{i["key"]} ({i["status"]}, "{i["summary"]}") is blocked'
                   f'{" [label]" if i["labelled"] else " [agent asked Roi, no label]"}'
                   f' — {BROWSE}{i["key"]} — agent wrote: {i["why"]}')
    if not new or DRY:
        if new:
            print("=== DRY RUN blocked ===\n" + json.dumps(new, indent=2, ensure_ascii=False))
        return
    os.makedirs(TM_ALERT_DIR, exist_ok=True)
    name = datetime.now().strftime("%Y-%m-%dT%H-%M-%S") + "-blocked.json"
    tmp = os.path.join(TM_ALERT_DIR, "." + name)
    json.dump({"source": "pipeline-watchdog", "new": new}, open(tmp, "w"),
              indent=2, ensure_ascii=False)
    os.rename(tmp, os.path.join(TM_ALERT_DIR, name))
    print("watchdog: blocked → Team Manager:", ", ".join(new))


def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {}


def human_age(m):
    h, m = divmod(int(m), 60)
    return f"{h}h {m}m" if h else f"{m}m"


def build_log_line(items):
    """One greppable line for the shared team log — one browse URL per issue."""
    return (f"pipeline watchdog: {len(items)} issue(s) picked up by nobody "
            f"(To Do >{TODO_STUCK_MIN}m or In Progress >{INPROGRESS_STUCK_MIN}m, "
            f"no PR attached) — " +
            ", ".join(f'{i["key"]} {i["status"]} {human_age(i["age_min"])} '
                      f'{BROWSE}{i["key"]}'
                      for i in items))


def main():
    stuck = find_stuck()
    state = load_state()
    blocked_state = state.pop("_blocked", {})
    blocked = find_blocked()
    alert_tm_blocked(blocked, blocked_state)
    live = {"blocked:" + b["key"] for b in blocked}
    blocked_state = {k: v for k, v in blocked_state.items() if k in live}
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()

    to_alert, new_state = [], {}
    for i in stuck:
        key = i["key"]
        prev = state.get(key)
        due = True
        if prev:
            same_status = prev.get("status") == i["status"]
            fresh = (now - parse_ts(prev["last_alert"])).total_seconds() < RE_ALERT_HOURS * 3600
            if same_status and fresh:
                due = False
        if due:
            to_alert.append(i)
            new_state[key] = {"last_alert": now_iso, "status": i["status"]}
        else:
            new_state[key] = prev  # carry forward, keeps old last_alert

    if not to_alert:
        print(f"watchdog: {len(stuck)} stuck, 0 new/due — nothing to log")
        if not DRY:
            new_state["_blocked"] = blocked_state
            json.dump(new_state, open(STATE_FILE, "w"), indent=2)
        return

    line = build_log_line(to_alert)

    if DRY:
        print("=== DRY RUN ===\n" + line)
        return

    subprocess.run([os.path.join(HOME, "projects/team/scripts/log.sh"),
                    "Project Manager", "WARN", line], check=False)
    new_state["_blocked"] = blocked_state
    json.dump(new_state, open(STATE_FILE, "w"), indent=2)
    print("watchdog: logged", ", ".join(i["key"] for i in to_alert))


if __name__ == "__main__":
    main()
