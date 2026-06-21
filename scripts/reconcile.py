#!/usr/bin/env python3
"""
Reconciler — detect and fix pipeline inconsistencies the normal flow leaves behind.

Deterministic, no LLM. Runs on a cron. For each enabled project it checks:

  1. Stuck Jira status — a queue task is `done` and a PR exists for the issue, but
     Jira is still "Work in progress"/"In Progress" (never advanced to Review).
     FIX: transition the Jira issue to "Review".
  2. Missing reviewed-ok — an open dev-targeted PR is mergeable/clean but has no
     `reviewed-ok` (and isn't held as `reviewed-pending-sibling`): the solver exited
     before its test + review/approve steps (the KNS-190 failure: stopped at "PR
     opened"). We do NOT approve unreviewed work; instead REQUEUE the issue so a
     fresh session completes test + review-and-approve (idempotent; skip-if-live).
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
import re
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
            if "reviewed-pending-sibling" in labels:
                continue  # intentionally held for a paired backend PR — poll-github promotes it
            num = pr["number"]
            # mergeable + clean check (cheap signal: mergeable_state)
            detail = gh(f"repos/{repo}/pulls/{num}")
            mstate = (detail or {}).get("mergeable_state", "unknown")
            if mstate not in ("clean", "unstable"):  # unstable = checks pending but mergeable
                continue
            # An open, clean, dev-targeted PR with no reviewed-ok means the solver
            # session exited before running its test + review/approve steps (the
            # KNS-190 failure: ended at "PR opened"). Don't approve unreviewed work
            # ourselves — instead REQUEUE the issue so a fresh session completes the
            # test + review-and-approve steps (the hardened Exit Checklist forces it).
            key = (pr.get("head", {}).get("ref") or "").upper()
            m = re.match(r"([A-Z]+-\d+)", key)
            key = m.group(1) if m else None
            if not key:
                findings.append(("FLAG", name,
                    f"{repo} PR #{num} ('{pr['title'][:50]}') open, {mstate}, no reviewed-ok — "
                    f"can't derive Jira key from branch; needs manual review/label"))
                continue
            # Only requeue issues that are NOT already finished. If Roi has marked the
            # Jira Done/Closed/Canceled, the open PR is a leftover, not work to finish —
            # don't reopen it. Unknown status (None) → skip too (can't verify).
            jstatus = jira_status(key)
            if jstatus is None or jstatus.lower() in (
                "done", "completed", "closed", "canceled", "cancelled"
            ):
                continue
            # Don't pile up: skip if a non-done task for this key is already queued/running.
            live = psql(
                "SELECT count(*) FROM tasks "
                f"WHERE project_dir='{pdir}' AND task_key='{key}' AND status <> 'done'"
            )
            if live and live[0] and int(live[0][0]) > 0:
                continue
            if DRY:
                findings.append(("FIX", name,
                    f"{key}: {repo} PR #{num} open, {mstate}, no reviewed-ok → would requeue "
                    f"to finish test+review [dry-run]"))
            else:
                payload = json.dumps({"type": "jira_issue", "key": key})
                dedup = f"reconcile:{key}:{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}"
                r = sh(f'''bash "{DEV_AI}/scripts/queue.sh" push "{pdir}" '{payload}' "{dedup}"''')
                ok = r.returncode == 0
                findings.append(("FIX", name,
                    f"{key}: {repo} PR #{num} open, {mstate}, no reviewed-ok (review-approve step "
                    f"didn't run) → {'requeued to finish test+review' if ok else 'requeue FAILED'}"))

    # ---- 2b: reviewed-ok PRs that can't merge (wedged) ------------------------
    # A PR that is reviewed-ok + green but NOT cleanly mergeable never merges: the
    # auto-merge gate (poll-github) requires `mergeable` and silently skips it on
    # every poll. (KNS-191 #128: shared the branch a prior PR was rebase-merged
    # from, so dev diverged → permanent conflict.) Nothing else surfaces this, so
    # it sits wedged forever while Jira stays in Review. Flag it for Roi.
    for repo in repos:
        base = next((r.get("base_branch") for r in cfg.get("repos", []) if r["github"] == repo), None)
        prs = gh(f"repos/{repo}/pulls?state=open&per_page=30") or []
        for pr in prs:
            if base and pr.get("base", {}).get("ref") != base:
                continue
            labels = [l["name"] for l in pr.get("labels", [])]
            if "reviewed-ok" not in labels:
                continue
            num = pr["number"]
            detail = gh(f"repos/{repo}/pulls/{num}")
            mstate = (detail or {}).get("mergeable_state", "unknown")
            # clean = ready; unstable = checks pending but mergeable; behind = base
            # moved (poll-github updates it). Anything else with reviewed-ok is stuck.
            if mstate not in ("clean", "unstable", "behind"):
                findings.append(("FLAG", name,
                    f"{repo} PR #{num} ('{pr['title'][:50]}') is reviewed-ok but "
                    f"mergeable_state={mstate} — auto-merge can't merge it; needs a "
                    f"rebase/conflict-fix or close"))

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

    # ---- 3b: uncommitted tracked edits left in a repo (orphaned work) ----------
    # An agent that edits files but exits without committing leaves the change
    # stranded — invisible, never pushed, lost on the next checkout. (KNS-191: a
    # review-comment run edited assignment-teaser.tsx and exited 'done' with the
    # edit uncommitted.) --untracked-files=no so this won't double-fire on the
    # stray .png case handled above; only real modified/deleted tracked files.
    for repo in cfg.get("repos", []):
        local = Path(repo["local"])
        if not (local / ".git").exists():
            continue
        r = sh(f'git -C "{local}" status --porcelain --untracked-files=no')
        dirty = [ln for ln in r.stdout.splitlines() if ln.strip()]
        if dirty:
            files = ", ".join(ln[3:] for ln in dirty[:5])
            more = f" (+{len(dirty)-5} more)" if len(dirty) > 5 else ""
            findings.append(("FLAG", name,
                f"{repo['github']}: {len(dirty)} uncommitted tracked change(s) left in the "
                f"working tree — an agent edited but never committed: {files}{more}"))


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

    # Notification policy: a DAILY DIGEST. Email at most once per calendar day, and
    # only when something actually needs attention (a flag is open). Auto-fixes are
    # NEVER emailed — they need no action and are already in the log. State tracks the
    # flag set as of the last email (to mark items new since you were last told) and
    # the date we last emailed, so standing flags nudge at most once a day.
    state_file = DEV_AI / "logs" / ".reconcile-flagged.json"
    emailed = set()
    last_email_date = ""
    try:
        st = json.loads(state_file.read_text())
        if isinstance(st, dict):
            emailed = set(st.get("emailed_flags", []))
            last_email_date = st.get("last_email_date", "")
        else:  # legacy: bare list of flag keys
            emailed = set(st)
    except Exception:
        pass

    cur_flags = {f"{p}|{m}" for _, p, m in flags}
    new_flags = cur_flags - emailed
    today = datetime.now().strftime("%Y-%m-%d")

    # Daily digest: send only if there are open flags AND we haven't emailed today.
    should_email = bool(flags) and last_email_date != today

    if should_email and not DRY:
        tag = lambda key: " <em>(new)</em>" if key in new_flags else ""
        body = ("<p>These pipeline items need attention "
                "(auto-fixes are in the log, not emailed):</p><ul>" +
                "".join(f"<li>[{p}] {m}{tag(p+'|'+m)}</li>" for _, p, m in flags) +
                "</ul>")
        n_new = len(new_flags)
        subj = (f"Pipeline: {len(flags)} item(s) need attention" +
                (f" ({n_new} new)" if n_new else ""))
        sh(f'''bash "{HOME}/projects/team/scripts/send-mail-internal.sh" '''
           f'''"{subj}" "{body}" "manager@roikedem.com" "Team Manager"''')

    if not DRY:
        state_file.write_text(json.dumps({
            "emailed_flags": sorted(cur_flags if should_email else emailed),
            "last_email_date": today if should_email else last_email_date,
        }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
