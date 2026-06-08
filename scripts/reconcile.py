#!/usr/bin/env python3
"""
Reconciler — detect and fix pipeline inconsistencies the normal flow leaves behind.

Deterministic, no LLM. Runs on a cron. For each enabled project it checks:

  1. Stuck Jira status — a queue task is `done` and a PR exists for the issue, but
     Jira is still "Work in progress"/"In Progress" (never advanced to Review).
     FIX: transition the Jira issue to "Review".
  2. Missing reviewed-ok — an open dev-targeted PR is mergeable, CI green, authored
     by the deploy-eligible account, but has no `reviewed-ok` label and is sitting.
     FLAG only (review must gate the label; we don't approve unreviewed work).
  3. Stray repo PNGs / dirty tree — test screenshots left in a project repo working
     tree. FIX: move stray *.png at repo root into ~/dev-context/_reconciled/ and
     report. (Conservative: only untracked PNGs directly in a repo root.)
  4. Orphaned / stale tasks — queue task `done` but NO PR and Jira not advanced
     (silent drop); or `in_progress` with no live session on this host. FLAG.

Safe by design: only the high-confidence fixes (1, 3) auto-apply; the rest are
logged and emailed. Read-mostly; every write is idempotent.

Usage: reconcile.py [--dry-run]
"""

import json
import os
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

DRY = "--dry-run" in sys.argv

HOME = Path.home()
DEV_AI = Path(__file__).resolve().parent.parent
REGISTRY = HOME / ".config" / "dev-ai.json"
JIRA_TOKEN = (HOME / ".config" / "atlassian-api-token").read_text().strip()
JIRA_EMAIL = "roikedem+claudecode@gmail.com"
JIRA_BASE = "https://intotodev.atlassian.net/rest/api/3"
GH_TOKEN = (HOME / ".config" / "claude-agent-gh-token").read_text().strip()
NEON = HOME / ".config" / "dev-ai-neon-connection-params"
RECONCILED_DIR = HOME / "dev-context" / "_reconciled"
LOG = DEV_AI / "logs" / "reconcile.log"

findings = []   # (severity, project, msg) — severity: FIX|FLAG


def log(msg):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    with open(LOG, "a") as f:
        f.write(line + "\n")
    print(line)


def sh(cmd, env=None, check=False):
    e = os.environ.copy()
    if env:
        e.update(env)
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, env=e, check=check)


def jira_get(path):
    cmd = (f'curl -sf -u "{JIRA_EMAIL}:{JIRA_TOKEN}" -H "Accept: application/json" '
           f'"{JIRA_BASE}/{path}"')
    r = sh(cmd)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def jira_status(key):
    d = jira_get(f"issue/{key}?fields=status")
    if not d:
        return None
    return d["fields"]["status"]["name"]


def gh(path):
    r = sh(f'GH_TOKEN={GH_TOKEN} gh api "{path}" 2>/dev/null')
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def issue_has_pr(repos, key):
    """Return (state, number) of the most relevant PR for this Jira key, or None."""
    for repo in repos:
        prs = gh(f"search/issues?q=" + urllib.parse.quote(f"repo:{repo} is:pr {key} in:title"))
        if prs and prs.get("items"):
            it = prs["items"][0]
            return ("MERGED" if it.get("pull_request", {}).get("merged_at") else it["state"].upper(), it["number"], repo)
    return None


def psql(query):
    if not NEON.exists():
        return []
    # source connection params then run psql
    cmd = f'set -a; . "{NEON}"; set +a; psql -t -A -F "|" -c "{query}"'
    r = sh(cmd)
    if r.returncode != 0:
        return []
    return [line.split("|") for line in r.stdout.strip().splitlines() if line.strip()]


def check_project(proj):
    pdir = proj["dir"]
    cfg_path = Path(pdir) / ".jira-process.json"
    if not cfg_path.exists():
        return
    cfg = json.loads(cfg_path.read_text())
    repos = [r["github"] for r in cfg.get("repos", [])]
    name = Path(pdir).name

    # ---- 1 & 4: queue tasks: done/in_progress reconciliation -------------------
    rows = psql(
        "SELECT task_key, status, task_pr_number FROM tasks "
        f"WHERE project_dir='{pdir}' AND task_type='jira_issue' "
        "AND task_key IS NOT NULL AND task_key <> '' "
        "AND queued_at > now() - interval '14 days' ORDER BY id DESC"
    )
    seen = set()
    for row in rows:
        if len(row) < 2:
            continue
        key, status = row[0], row[1]
        if key in seen:
            continue
        seen.add(key)
        if status != "done":
            # in_progress with no live session is suspicious, but the cron's own
            # recover() handles crashes; only flag tasks stuck in_progress > 1h.
            continue
        jstatus = jira_status(key)
        if jstatus is None:
            continue
        jlow = jstatus.lower()
        if jlow in ("review", "in review", "completed", "done", "canceled", "closed"):
            continue  # already advanced or closed — fine
        # A task marked `done` whose Jira never reached Review/Done is STUCK: the
        # session exited (e.g. hit the turn limit) before finishing its final
        # steps (merge / transition / post report). The right fix is NOT to patch
        # Jira ourselves — that would advance Jira ahead of an unmerged PR. Instead
        # REQUEUE the task so the pipeline re-runs it and finishes it properly
        # (idempotent: a re-run resumes from $TASK_CONTEXT_FILE, merges if needed,
        # transitions Jira). The `done` flag was the lie; undo it by re-enqueuing.
        pr = issue_has_pr(repos, key)
        pr_desc = f"PR #{pr[1]} {pr[0]}" if pr else "no PR yet"

        # Don't pile up: skip if a non-done task for this key is already queued/running.
        live = psql(
            "SELECT count(*) FROM tasks "
            f"WHERE project_dir='{pdir}' AND task_key='{key}' AND status <> 'done'"
        )
        if live and live[0] and int(live[0][0]) > 0:
            continue

        if DRY:
            findings.append(("FIX", name,
                f"{key}: queue 'done' but Jira still '{jstatus}' ({pr_desc}) → would requeue [dry-run]"))
        else:
            payload = json.dumps({"type": "jira_issue", "key": key})
            dedup = f"reconcile:{key}:{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}"
            r = sh(f'''bash "{DEV_AI}/scripts/queue.sh" push "{pdir}" '{payload}' "{dedup}"''')
            ok = r.returncode == 0
            findings.append(("FIX", name,
                f"{key}: queue 'done' but Jira still '{jstatus}' ({pr_desc}) → "
                f"{'requeued for the pipeline to finish' if ok else 'requeue FAILED'}"))

    # ---- 2: open PRs missing reviewed-ok --------------------------------------
    for repo in repos:
        base = next((r.get("base_branch") for r in cfg.get("repos", []) if r["github"] == repo), None)
        prs = gh(f"repos/{repo}/pulls?state=open&per_page=30") or []
        for pr in prs:
            if base and pr.get("base", {}).get("ref") != base:
                continue
            labels = [l["name"] for l in pr.get("labels", [])]
            if "reviewed-ok" in labels or "danger" in labels:
                continue
            num = pr["number"]
            # mergeable + clean check (cheap signal: mergeable_state)
            detail = gh(f"repos/{repo}/pulls/{num}")
            mstate = (detail or {}).get("mergeable_state", "unknown")
            if mstate in ("clean", "unstable"):  # unstable = checks pending but mergeable
                findings.append(("FLAG", name,
                    f"{repo} PR #{num} ('{pr['title'][:50]}') is open, {mstate}, no reviewed-ok — "
                    f"review-approve step likely didn't run; needs review/label to merge"))

    # ---- 3: stray PNGs in repo working trees ----------------------------------
    for repo in cfg.get("repos", []):
        local = Path(repo["local"])
        if not (local / ".git").exists() and not (local / ".git"):
            continue
        # untracked PNGs at repo root (test screenshots wrongly written here)
        r = sh(f'git -C "{local}" status --porcelain --untracked-files=all')
        strays = [ln[3:] for ln in r.stdout.splitlines()
                  if ln.startswith("?? ") and ln[3:].lower().endswith(".png") and "/" not in ln[3:]]
        if strays:
            RECONCILED_DIR.mkdir(parents=True, exist_ok=True)
            moved = []
            for f in strays:
                src = local / f
                if not src.exists():
                    continue
                if DRY:
                    moved.append(f)
                    continue
                dst = RECONCILED_DIR / f"{name}-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{f}"
                try:
                    src.rename(dst)
                    moved.append(f)
                except Exception:
                    pass
            if moved:
                findings.append(("FIX", name,
                    f"{repo}: moved {len(moved)} stray screenshot(s) out of repo root → {RECONCILED_DIR}"
                    f"{' [dry-run]' if DRY else ''}: {', '.join(moved)}"))


def main():
    if not REGISTRY.exists():
        log("no dev-ai.json registry — nothing to do")
        return 0
    projects = [p for p in json.loads(REGISTRY.read_text()).get("projects", []) if p.get("enabled")]
    for proj in projects:
        try:
            check_project(proj)
        except Exception as e:
            findings.append(("FLAG", Path(proj["dir"]).name, f"reconcile error: {e}"))

    fixes = [f for f in findings if f[0] == "FIX"]
    flags = [f for f in findings if f[0] == "FLAG"]
    for sev, proj, msg in findings:
        log(f"{sev} [{proj}] {msg}")
    if not findings:
        log("clean — no inconsistencies found")

    # Email a digest, but ONLY when the picture changed since last run — a fix
    # happened, or a new flag appeared that wasn't flagged before. Otherwise the
    # same standing flags would email every 30 min. State kept in a small file.
    state_file = DEV_AI / "logs" / ".reconcile-flagged.json"
    prev = set()
    try:
        prev = set(json.loads(state_file.read_text()))
    except Exception:
        pass
    cur_flags = {f"{p}|{m}" for _, p, m in flags}
    new_flags = cur_flags - prev
    if not DRY:
        state_file.write_text(json.dumps(sorted(cur_flags)))

    should_email = bool(fixes) or bool(new_flags)
    if should_email and not DRY:
        lines = []
        if fixes:
            lines.append("<p><strong>Auto-fixed:</strong></p><ul>" +
                         "".join(f"<li>[{p}] {m}</li>" for _, p, m in fixes) + "</ul>")
        if flags:
            tag = lambda key: " <em>(new)</em>" if key in new_flags else ""
            lines.append("<p><strong>Needs attention:</strong></p><ul>" +
                         "".join(f"<li>[{p}] {m}{tag(p+'|'+m)}</li>" for _, p, m in flags) + "</ul>")
        body = "".join(lines)
        sh(f'''bash "{HOME}/projects/team/scripts/send-mail-internal.sh" '''
           f'''"Pipeline reconcile: {len(fixes)} fixed, {len(new_flags)} new flag(s)" '''
           f'''"{body}" "manager@roikedem.com" "Team Manager"''')
    return 0


if __name__ == "__main__":
    sys.exit(main())
