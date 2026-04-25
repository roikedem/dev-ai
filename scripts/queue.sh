#!/usr/bin/env bash
# Queue operations for per-project Claude task queue.
# Usage:
#   queue.sh push  <project-dir> <json-object>   — append one task (JSONL)
#   queue.sh pop   <project-dir>                 — print+remove oldest task
#   queue.sh count <project-dir>                 — print number of queued tasks
#   queue.sh peek  <project-dir>                 — print oldest task without removing

OPERATION="${1:?Usage: queue.sh <push|pop|count|peek> <project-dir> [json]}"
PROJECT_DIR="${2:?Missing project-dir}"
QUEUE="$PROJECT_DIR/.claude-queue.jsonl"
LOCK="$PROJECT_DIR/.claude-queue.lock"

exec 9>"$LOCK"
flock 9

case "$OPERATION" in
  push)
    JSON="${3:?Missing json argument for push}"
    echo "$JSON" >> "$QUEUE"
    ;;
  pop)
    [ -f "$QUEUE" ] || exit 0
    head -1 "$QUEUE"
    tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    ;;
  count)
    [ -f "$QUEUE" ] || { echo 0; exit 0; }
    wc -l < "$QUEUE" | tr -d ' '
    ;;
  peek)
    [ -f "$QUEUE" ] || exit 0
    head -1 "$QUEUE"
    ;;
  *)
    echo "Unknown operation: $OPERATION" >&2
    exit 1
    ;;
esac
