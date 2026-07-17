#!/usr/bin/env bash
# Deterministic Jira REST helper for the autonomous pipeline.
#
# The Atlassian MCP requires an interactive OAuth flow and is unusable in the
# headless cron worker (it silently blocks tasks — see TRIP-1, 2026-07-17).
# This wrapper uses the same static API token the poller already relies on, so
# every session reads/writes Jira the same way instead of improvising curl.
#
# Usage:
#   jira.sh get        <KEY>                 — print issue summary/status/description/comments
#   jira.sh raw        <KEY>                 — dump the raw issue JSON (fields=*all)
#   jira.sh transition <KEY> <STATUS_NAME>   — move issue to the named status (e.g. "In Progress", "Review", "Done")
#   jira.sh comment    <KEY> <TEXT>          — add a comment (plain text; converted to ADF)
#   jira.sh attach     <KEY> <FILE>          — upload a file attachment
#   jira.sh link       <KEY> <URL> [TITLE]   — add a remote link (PR → Development panel)
#   jira.sh links      <KEY>                 — list remote link URLs
#   jira.sh jql        "<JQL>"               — search, print key + status + summary per line
#
# Auth: reads ~/.config/atlassian-api-token (same as poll-jira.sh).

set -euo pipefail

CMD="${1:?Usage: jira.sh <get|raw|transition|comment|attach|jql> ...}"

TOKEN_FILE="$HOME/.config/atlassian-api-token"
[ -f "$TOKEN_FILE" ] || { echo "jira.sh: missing $TOKEN_FILE" >&2; exit 1; }
TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
EMAIL="roikedem+claudecode@gmail.com"
BASE="https://intotodev.atlassian.net/rest/api/3"
AUTH=(-u "$EMAIL:$TOKEN")

api() {  # method path [curl-args...]
    local method="$1" path="$2"; shift 2
    curl -sf "${AUTH[@]}" -X "$method" -H "Accept: application/json" "$BASE$path" "$@"
}

case "$CMD" in
  get)
    KEY="${2:?Usage: jira.sh get <KEY>}"
    api GET "/issue/$KEY?fields=summary,status,description,comment,assignee" \
      | python3 -c '
import json,sys
def text(node):
    # flatten an ADF node tree to plain text
    if node is None: return ""
    if isinstance(node,str): return node
    out=[]
    if isinstance(node,dict):
        if node.get("type")=="text": out.append(node.get("text",""))
        if node.get("type") in ("hardBreak","paragraph"): out.append("\n")
        for c in node.get("content",[]) or []: out.append(text(c))
    elif isinstance(node,list):
        for c in node: out.append(text(c))
    return "".join(out)
d=json.load(sys.stdin); f=d["fields"]
print("Key:",d["key"])
print("Summary:",f.get("summary"))
print("Status:",(f.get("status") or {}).get("name"))
a=f.get("assignee"); print("Assignee:", a["displayName"] if a else "UNASSIGNED")
print("\n--- Description ---")
print(text(f.get("description")).strip() or "(empty)")
c=f.get("comment",{}) or {}
print("\n--- Comments (%d) ---"%c.get("total",0))
for cm in c.get("comments",[]):
    print("["+cm["author"]["displayName"]+" @ "+cm["created"]+" id="+cm["id"]+"]")
    print(text(cm.get("body")).strip()); print()
'
    ;;

  raw)
    KEY="${2:?Usage: jira.sh raw <KEY>}"
    api GET "/issue/$KEY?fields=*all"
    ;;

  transition)
    KEY="${2:?Usage: jira.sh transition <KEY> <STATUS_NAME>}"
    TARGET="${3:?Usage: jira.sh transition <KEY> <STATUS_NAME>}"
    TID=$(api GET "/issue/$KEY/transitions" \
      | python3 -c 'import json,sys,os
t=os.environ["TARGET"].strip().lower()
d=json.load(sys.stdin)
for tr in d.get("transitions",[]):
    if tr["to"]["name"].strip().lower()==t or tr["name"].strip().lower()==t:
        print(tr["id"]); break
' TARGET="$TARGET")
    [ -n "$TID" ] || { echo "jira.sh: no transition to '$TARGET' available for $KEY" >&2; exit 2; }
    api POST "/issue/$KEY/transitions" -H "Content-Type: application/json" \
      -d "{\"transition\":{\"id\":\"$TID\"}}"
    echo "jira.sh: $KEY -> $TARGET (transition $TID)"
    ;;

  comment)
    KEY="${2:?Usage: jira.sh comment <KEY> <TEXT>}"
    TEXT="${3:?Usage: jira.sh comment <KEY> <TEXT>}"
    BODY=$(TEXT="$TEXT" python3 -c '
import json,os
text=os.environ["TEXT"]
paras=[]
for block in text.split("\n\n"):
    nodes=[]
    lines=block.split("\n")
    for i,line in enumerate(lines):
        if i: nodes.append({"type":"hardBreak"})
        if line: nodes.append({"type":"text","text":line})
    paras.append({"type":"paragraph","content":nodes or [{"type":"text","text":""}]})
print(json.dumps({"body":{"type":"doc","version":1,"content":paras}}))
')
    api POST "/issue/$KEY/comment" -H "Content-Type: application/json" -d "$BODY" >/dev/null
    echo "jira.sh: commented on $KEY"
    ;;

  link)
    KEY="${2:?Usage: jira.sh link <KEY> <URL> <TITLE>}"
    URL="${3:?Usage: jira.sh link <KEY> <URL> <TITLE>}"
    TITLE="${4:-$URL}"
    BODY=$(URL="$URL" TITLE="$TITLE" python3 -c '
import json,os
print(json.dumps({"object":{"url":os.environ["URL"],"title":os.environ["TITLE"],
  "icon":{"url16x16":"https://github.com/favicon.ico","title":"GitHub"}}}))')
    api POST "/issue/$KEY/remotelink" -H "Content-Type: application/json" -d "$BODY" >/dev/null
    echo "jira.sh: linked $URL to $KEY"
    ;;

  links)
    KEY="${2:?Usage: jira.sh links <KEY>}"
    api GET "/issue/$KEY/remotelink" \
      | python3 -c 'import json,sys
for l in json.load(sys.stdin): print(l.get("object",{}).get("url"))'
    ;;

  attach)
    KEY="${2:?Usage: jira.sh attach <KEY> <FILE>}"
    FILE="${3:?Usage: jira.sh attach <KEY> <FILE>}"
    [ -f "$FILE" ] || { echo "jira.sh: no such file $FILE" >&2; exit 1; }
    curl -sf "${AUTH[@]}" -X POST -H "X-Atlassian-Token: no-check" \
      -F "file=@$FILE" "$BASE/issue/$KEY/attachments" >/dev/null
    echo "jira.sh: attached $(basename "$FILE") to $KEY"
    ;;

  jql)
    JQL="${2:?Usage: jira.sh jql \"<JQL>\"}"
    ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$JQL")
    api GET "/search/jql?jql=$ENC&maxResults=50&fields=summary,status" \
      | python3 -c 'import json,sys
for i in json.load(sys.stdin).get("issues",[]):
    f=i["fields"]; print(i["key"], "|", f["status"]["name"], "|", f.get("summary"))'
    ;;

  *)
    echo "jira.sh: unknown command '$CMD'" >&2; exit 1;;
esac
