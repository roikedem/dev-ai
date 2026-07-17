#!/usr/bin/env python3
"""
Pipeline watchdog — alerts when an autonomous-pipeline issue is stuck.

A healthy pipeline moves an assigned issue To Do -> In Progress -> Review within
a couple of 2-min dispatch cycles. If an issue sits in To Do or In Progress well
past that, the worker either never advanced it (e.g. TRIP-1 blocked on the MCP,
2026-07-17) or it is genuinely blocked waiting on Roi (e.g. ZRM-36). Either way
Roi should hear about it — once — not every dispatch.

Dedup: state file records the last alert per issue. A stuck issue is (re-)alerted
only when it is newly stuck, its status changed, or RE_ALERT_HOURS have passed.
Resolved issues drop out of state silently. All currently-stuck issues go in ONE
email, so the run never sends more than one message regardless of how often it runs.

Run from cron (e.g. every 15 min). --dry-run prints instead of emailing/writing state.
"""
import json, os, sys, subprocess, urllib.parse, urllib.request, base64
from datetime import datetime, timezone

# --- thresholds -------------------------------------------------------------
TODO_STUCK_MIN       = 20      # To Do this long => worker never picked it up
INPROGRESS_STUCK_MIN = 90      # In Progress this long => stalled or blocked
RE_ALERT_HOURS       = 24      # don't re-nag a still-stuck issue before this

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
            cause = ("queued but the worker never moved it to In Progress"
                     if status == "To Do"
                     else "claimed but never reached Review — blocked or erroring")
            stuck.append({"key": it["key"], "status": status,
                          "summary": f.get("summary", ""),
                          "age_min": round(age), "cause": cause})
    return stuck


def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {}


def human_age(m):
    h, m = divmod(int(m), 60)
    return f"{h}h {m}m" if h else f"{m}m"


def build_email(items):
    rows = ""
    for i in items:
        rows += (
            f'<tr>'
            f'<td style="padding:4px 10px;"><a href="{BROWSE}{i["key"]}">{i["key"]}</a></td>'
            f'<td style="padding:4px 10px;">{i["status"]}</td>'
            f'<td style="padding:4px 10px;">{human_age(i["age_min"])}</td>'
            f'<td style="padding:4px 10px;">{i["summary"]}</td>'
            f'<td style="padding:4px 10px;color:#666;">{i["cause"]}</td>'
            f'</tr>')
    return (
        f'<p>The autonomous pipeline has {len(items)} stuck issue(s) '
        f'(To Do &gt; {TODO_STUCK_MIN}m or In Progress &gt; {INPROGRESS_STUCK_MIN}m):</p>'
        f'<table style="border-collapse:collapse;font-family:sans-serif;font-size:14px;">'
        f'<tr style="background:#f0f0f0;text-align:left;">'
        f'<th style="padding:4px 10px;">Issue</th><th style="padding:4px 10px;">Status</th>'
        f'<th style="padding:4px 10px;">Stuck for</th><th style="padding:4px 10px;">Summary</th>'
        f'<th style="padding:4px 10px;">Likely cause</th></tr>{rows}</table>'
        f'<p style="color:#888;font-size:12px;">Re-alerts at most once per {RE_ALERT_HOURS}h per issue.</p>')


def main():
    stuck = find_stuck()
    state = load_state()
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
        print(f"watchdog: {len(stuck)} stuck, 0 new/due — no alert")
        if not DRY:
            json.dump(new_state, open(STATE_FILE, "w"), indent=2)
        return

    body = build_email(to_alert)
    subject = f"⚠️ Pipeline stuck: {len(to_alert)} issue(s) — " + \
              ", ".join(i["key"] for i in to_alert)

    if DRY:
        print("=== DRY RUN ===\nSubject:", subject, "\n", body)
        return

    subprocess.run([os.path.join(HOME, "projects/team/scripts/send-mail-internal.sh"),
                    subject, body, "pm@roikedem.com", "Project Manager"], check=False)
    subprocess.run([os.path.join(HOME, "projects/team/scripts/log.sh"),
                    "Project Manager", "WARN",
                    "pipeline watchdog: " + ", ".join(
                        f'{i["key"]} {i["status"]} {human_age(i["age_min"])}' for i in to_alert)],
                   check=False)
    json.dump(new_state, open(STATE_FILE, "w"), indent=2)
    print("watchdog: alerted on", ", ".join(i["key"] for i in to_alert))


if __name__ == "__main__":
    main()
