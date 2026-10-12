#!/usr/bin/env python3
"""
Reviewer — independent check of the developer agent's proof, before Roi sees a ticket.

The developer agent solves a ticket, proves it (screenshots, test output), and moves
it to Review — still assigned to the agent. This script picks up every such ticket,
asks a cheap model (agents/reviewer/CLAUDE.md in the team repo) whether the proof
convinces, and acts on the verdict. The model only returns a verdict; every action
is taken here, in code, so the rules below cannot be skipped:

  pass            -> comment "Reviewer: proof accepted", assign to Roi.
                     Review + assigned to Roi is the ONLY state Roi treats as his.
  fail, 1st time  -> comment the reasons, Jira back to In Progress, queue the
                     developer to re-prove (stays assigned to the agent).
  fail, 2nd time  -> comment, label `unproven`, assign to Roi (he decides).
  model error     -> nothing changes; retried next run (logged).

A "pass" whose claims don't cite real evidence (an attachment on the ticket, a
comment id, or the diff) is counted as a fail: no proof, no pass.

Why (12.10.2026): PAN-273 was reported "Tested in browser" with a 21-px screenshot
of a label and a fix that could not work. The developer graded its own work.

Usage: review-tickets.py [--dry-run] [--key KEY]
  --dry-run  print verdicts, change nothing
  --key      review one ticket (any status/assignee), e.g. for calibration
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

DRY = "--dry-run" in sys.argv
ONLY_KEY = sys.argv[sys.argv.index("--key") + 1] if "--key" in sys.argv else None

HOME = Path.home()
DEV_AI = Path(__file__).resolve().parent.parent
REGISTRY = HOME / ".config" / "dev-ai.json"
REVIEWER_MD = HOME / "projects" / "team" / "agents" / "reviewer" / "CLAUDE.md"
JIRA_TOKEN = (HOME / ".config" / "atlassian-api-token").read_text().strip()
JIRA_EMAIL = "roikedem+claudecode@gmail.com"
JIRA_SITE = "https://intotodev.atlassian.net"
JIRA_BASE = f"{JIRA_SITE}/rest/api/3"
GH_TOKEN = (HOME / ".config" / "claude-agent-gh-token").read_text().strip()
ROI_ID = "557058:9d9d1c56-8b3e-473c-953f-546715de7f0f"   # the assignable "Roi Kedem"
MODEL = "claude-haiku-5-5"
MAX_REJECTIONS = 2
DIFF_LIMIT = 60_000
MAX_IMAGES = 20
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp")
LOG = DEV_AI / "logs" / "review-tickets.log"
TAG_ACCEPT = "Reviewer: proof accepted"
TAG_REJECT = "Reviewer: proof rejected"


def log(msg):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    with open(LOG, "a") as f:
        f.write(line + "\n")
    print(line)


# ---- Jira / GitHub -------------------------------------------------------------

def jira(method, path, body=None, raw=False):
    cmd = ["curl", "-sS", "-u", f"{JIRA_EMAIL}:{JIRA_TOKEN}", "-H", "Accept: application/json",
           "-H", "Content-Type: application/json", "-X", method, "-w", "\n%{http_code}",
           path if path.startswith("http") else f"{JIRA_BASE}/{path}"]
    if body is not None:
        cmd += ["-d", json.dumps(body)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out, _, code = r.stdout.rpartition("\n")
    if not code.startswith("2"):
        raise RuntimeError(f"jira {method} {path} -> {code}: {out[:200]}")
    if raw or not out.strip():
        return out
    return json.loads(out)


def jira_download(url, dest):
    subprocess.run(["curl", "-sSL", "-u", f"{JIRA_EMAIL}:{JIRA_TOKEN}", "-o", str(dest), url],
                   check=True, capture_output=True)


def adf_text(node):
    """Flatten Atlassian Document Format to plain text; media shown as [image: alt]."""
    if isinstance(node, list):
        return "".join(adf_text(n) for n in node)
    if not isinstance(node, dict):
        return ""
    t = node.get("type")
    if t == "text":
        return node.get("text", "")
    if t == "hardBreak":
        return "\n"
    if t == "media":
        a = node.get("attrs", {})
        return f"[image: {a.get('alt') or a.get('id', '?')}]"
    inner = adf_text(node.get("content", []))
    if t in ("paragraph", "heading", "listItem", "codeBlock", "mediaSingle"):
        return inner + "\n"
    return inner


def comment_adf(text):
    return {"type": "doc", "version": 1, "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": line}]}
        for line in text.split("\n") if line.strip()]}


def gh(path):
    r = subprocess.run(["curl", "-sSf", "-H", f"Authorization: Bearer {GH_TOKEN}",
                        "-H", "Accept: application/vnd.github+json",
                        f"https://api.github.com/{path}"], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout else None


def pr_diff(repos, key):
    """(pr_urls, diff_text) of every PR titled with this key, across the project's
    repos (a ticket can span front + back, or take several PRs), newest first."""
    urls, parts = [], []
    for repo in repos:
        res = gh("search/issues?q=" + urllib.parse.quote(f"repo:{repo} is:pr {key} in:title")
                 + "&sort=created&order=desc")
        for it in (res or {}).get("items", [])[:4]:
            num = it["number"]
            r = subprocess.run(["curl", "-sSfL", "-H", f"Authorization: Bearer {GH_TOKEN}",
                                "-H", "Accept: application/vnd.github.v3.diff",
                                f"https://api.github.com/repos/{repo}/pulls/{num}"],
                               capture_output=True, text=True)
            url = f"https://github.com/{repo}/pull/{num}"
            urls.append(url)
            parts.append(f"===== {url} — {it['title']} ({it['state']}) =====\n"
                         + (r.stdout if r.returncode == 0 else "[diff unavailable]\n"))
    diff = "\n".join(parts)
    if len(diff) > DIFF_LIMIT:
        diff = diff[:DIFF_LIMIT] + f"\n\n[diff truncated at {DIFF_LIMIT} chars]\n"
    return ", ".join(urls) or None, diff


# ---- Evidence pack ---------------------------------------------------------------

def build_pack(key, fields, repos, workdir):
    comments = fields.get("comment", {}).get("comments", [])
    attachments = sorted(fields.get("attachment", []), key=lambda a: a["created"])
    images = [a for a in attachments if a["filename"].lower().endswith(IMAGE_EXT)][-MAX_IMAGES:]

    names = set()
    for a in images:
        # Same filename can be uploaded twice (before.png on two attempts): keep both.
        name = a["filename"]
        if name in names:
            stem, ext = os.path.splitext(name)
            name = f"{stem}--{a['id']}{ext}"
        names.add(name)
        a["_local"] = name
        jira_download(a["content"], workdir / name)

    pr_url, diff = pr_diff(repos, key)
    if diff:
        (workdir / "diff.patch").write_text(diff)

    lines = [f"# {key}: {fields.get('summary', '')}", "",
             f"Status: {fields['status']['name']}", f"PR: {pr_url or 'none found'}", "",
             "## Description", adf_text(fields.get("description")) or "(empty)", "",
             "## Attachments (oldest first)"]
    for a in attachments:
        local = a.get("_local")
        lines.append(f"- {local or a['filename']} — uploaded {a['created'][:16]} by "
                     f"{a.get('author', {}).get('displayName', '?')}"
                     + ("" if local else " (not an image, not downloaded)"))
    if not attachments:
        lines.append("(none)")
    lines += ["", "## Comments (oldest first)"]
    for c in comments:
        lines += [f"### comment:{c['id']} — {c['author']['displayName']} — {c['created'][:16]}",
                  adf_text(c.get("body")).strip(), ""]
    if not comments:
        lines.append("(none)")
    (workdir / "ticket.md").write_text("\n".join(lines))

    evidence = {a["_local"] for a in images} | {f"comment:{c['id']}" for c in comments}
    if diff:
        evidence.add("diff")
    return evidence, pr_url


# ---- Model -----------------------------------------------------------------------

def ask_model(workdir):
    claude = shutil.which("claude", path=f"{HOME}/.local/bin:{os.environ.get('PATH', '')}")
    if not claude:
        raise RuntimeError("claude CLI not found")
    files = sorted(p.name for p in workdir.iterdir())
    prompt = (REVIEWER_MD.read_text()
              + "\n\n---\n\nFiles in your working directory: " + ", ".join(files)
              + "\n\nReview this ticket now. Reply with the JSON object only.")
    r = subprocess.run(
        [claude, "-p", prompt, "--model", MODEL, "--output-format", "json",
         "--allowedTools", "Read", "--strict-mcp-config", "--max-turns", "40"],
        cwd=workdir, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise RuntimeError(f"claude exit {r.returncode}: {(r.stderr or r.stdout)[-300:]}")
    outer = json.loads(r.stdout)
    text = outer.get("result", "")
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise RuntimeError(f"no JSON in model reply: {text[:300]}")
    return json.loads(m.group(0)), outer.get("total_cost_usd")


def validate(verdict, evidence):
    """Return (final_verdict, problems). A pass that doesn't cite real proof is a fail."""
    problems = []
    claims = verdict.get("claims") or []
    if verdict.get("verdict") not in ("pass", "fail"):
        raise RuntimeError(f"bad verdict value: {verdict.get('verdict')!r}")
    if not claims:
        problems.append("no claims listed")
    for c in claims:
        if not c.get("proven"):
            continue
        cited = c.get("evidence") or []
        if not cited:
            c["proven"] = False
            c["reason"] = "marked proven but cites no evidence. " + (c.get("reason") or "")
            problems.append(f"uncited: {c.get('claim', '?')[:60]}")
            continue
        missing = [e for e in cited if e not in evidence]
        if missing:
            c["proven"] = False
            c["reason"] = f"cites evidence not on the ticket: {', '.join(missing)}. " + (c.get("reason") or "")
            problems.append(f"bad citation {missing}")
    final = "pass" if claims and all(c.get("proven") for c in claims) and not problems else "fail"
    if verdict["verdict"] == "fail":
        final = "fail"
    return final, problems


# ---- Actions ---------------------------------------------------------------------

def verdict_comment(tag, verdict, n=None):
    head = tag + (f" ({n}/{MAX_REJECTIONS})" if n else "")
    lines = [head, verdict.get("summary", "").strip(), ""]
    for c in verdict.get("claims", []):
        mark = "PROVEN" if c.get("proven") else "NOT PROVEN"
        ev = ", ".join(c.get("evidence") or []) or "no evidence"
        lines.append(f"- {mark}: {c.get('claim', '')} — {c.get('reason', '')} [{ev}]")
    return "\n".join(lines)


def transition(key, name):
    trs = jira("GET", f"issue/{key}/transitions")["transitions"]
    t = next((t for t in trs if t["to"]["name"].lower() == name.lower()
              or t["name"].lower() == name.lower()), None)
    if not t:
        raise RuntimeError(f"{key}: no '{name}' transition (have {[x['name'] for x in trs]})")
    jira("POST", f"issue/{key}/transitions", {"transition": {"id": t["id"]}})


def requeue_developer(pdir, key, comment_id, text):
    """Queue the developer to re-prove. A jira_comment task, because the context file
    usually says 'waiting for PR review', which a plain jira_issue task skips."""
    ctx = HOME / "dev-context" / key / "context.txt"
    if ctx.exists():
        body = ctx.read_text()
        body = re.sub(r"^## Status:.*$", "## Status: in progress — addressing reviewer rejection",
                      body, count=1, flags=re.M)
        ctx.write_text(body)
    task = json.dumps({"type": "jira_comment", "key": key, "comment_id": comment_id,
                       "author": "Reviewer", "body": text[:200], "priority": "High",
                       "priority_rank": 2,
                       "queued_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
    r = subprocess.run(["bash", str(DEV_AI / "scripts" / "queue.sh"), "push", pdir, task,
                        f"comment:{key}:{comment_id}"], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"queue push failed: {r.stderr[-200:]}")


def act(key, pdir, fields, final, verdict):
    prior = sum(1 for c in fields.get("comment", {}).get("comments", [])
                if adf_text(c.get("body")).startswith(TAG_REJECT))
    if final == "pass":
        jira("POST", f"issue/{key}/comment", {"body": comment_adf(verdict_comment(TAG_ACCEPT, verdict))})
        jira("PUT", f"issue/{key}/assignee", {"accountId": ROI_ID})
        return "passed, assigned to Roi"
    n = prior + 1
    text = verdict_comment(TAG_REJECT, verdict, n)
    if n >= MAX_REJECTIONS:
        text += (f"\n\nRejected {n} times — handed to Roi (label `unproven`). "
                 "The developer could not prove this ticket.")
        jira("POST", f"issue/{key}/comment", {"body": comment_adf(text)})
        jira("PUT", f"issue/{key}", {"update": {"labels": [{"add": "unproven"}]}})
        jira("PUT", f"issue/{key}/assignee", {"accountId": ROI_ID})
        return f"rejected {n}/{MAX_REJECTIONS}, unproven, assigned to Roi"
    c = jira("POST", f"issue/{key}/comment", {"body": comment_adf(text)})
    transition(key, "In Progress")
    requeue_developer(pdir, key, c["id"], text)
    return f"rejected {n}/{MAX_REJECTIONS}, back to developer"


# ---- Main ------------------------------------------------------------------------

def projects():
    reg = json.loads(REGISTRY.read_text())
    for p in (reg.get("projects", reg) if isinstance(reg, dict) else reg):
        if not p.get("enabled"):
            continue
        cfg_path = Path(p["dir"]) / ".jira-process.json"
        if cfg_path.exists():
            cfg = json.loads(cfg_path.read_text())
            yield p["dir"], cfg["jira_project_key"], [r["github"] for r in cfg.get("repos", [])]


def review(key, pdir, repos):
    fields = jira("GET", f"issue/{key}?fields=summary,status,description,comment,attachment")["fields"]
    with tempfile.TemporaryDirectory(prefix=f"review-{key}-") as tmp:
        workdir = Path(tmp)
        evidence, _ = build_pack(key, fields, repos, workdir)
        verdict, cost = ask_model(workdir)
    final, problems = validate(verdict, evidence)
    tag = f"{key}: model={verdict.get('verdict')} final={final} cost=${cost or 0:.3f}"
    if problems:
        tag += f" problems={problems}"
    if DRY:
        log(f"[dry-run] {tag}")
        print(verdict_comment(TAG_ACCEPT if final == "pass" else TAG_REJECT, verdict))
        print()
        return
    log(f"{tag} -> {act(key, pdir, fields, final, verdict)}")


def main():
    if ONLY_KEY:
        prefix = ONLY_KEY.split("-")[0]
        for pdir, pkey, repos in projects():
            if pkey == prefix:
                review(ONLY_KEY, pdir, repos)
                return
        sys.exit(f"no enabled project for {prefix}")

    me = jira("GET", "myself")["accountId"]
    done = set()
    for pdir, pkey, repos in projects():
        if pkey in done:      # several project dirs can share one Jira project
            continue
        done.add(pkey)
        jql = f'project = {pkey} AND status = Review AND assignee = "{me}" ORDER BY updated ASC'
        res = jira("GET", "search/jql?" + urllib.parse.urlencode(
            {"jql": jql, "fields": "summary", "maxResults": 50}))
        for issue in res.get("issues", []):
            try:
                review(issue["key"], pdir, repos)
            except Exception as e:   # one bad ticket must not stop the rest
                log(f"{issue['key']}: ERROR {e}")


if __name__ == "__main__":
    main()
