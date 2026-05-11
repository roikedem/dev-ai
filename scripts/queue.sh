#!/usr/bin/env bash
# Queue operations backed by Neon PostgreSQL.
# Usage:
#   queue.sh push    <project-dir> <json-object> [dedup-key]  — enqueue (no-op if dedup-key already exists)
#   queue.sh pop     <project-dir>                            — atomically claim oldest queued task; prints JSON with .id added
#   queue.sh count   <project-dir>                            — number of queued tasks
#   queue.sh peek    <project-dir>                            — oldest queued task JSON without changing it
#   queue.sh done    <project-dir> <task-id>                  — mark task done
#   queue.sh requeue <project-dir> <task-id>                  — reset in_progress → queued (crash recovery for a known task)
#   queue.sh recover <project-dir>                            — requeue all in_progress tasks owned by this host; prints one line per task

OPERATION="${1:?Usage: queue.sh <push|pop|count|peek|done|requeue|recover> <project-dir> [...]}"
PROJECT_DIR="${2:?Missing project-dir}"

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH"

CONN_PARAMS="$HOME/.config/dev-ai-neon-connection-params"
[ -f "$CONN_PARAMS" ] || { echo "Missing $CONN_PARAMS" >&2; exit 1; }
set -a && source "$CONN_PARAMS" && set +a

# Escape a value for SQL single-quoted string literal.
# Safe because PostgreSQL standard_conforming_strings=on (default): only ' needs doubling.
sq() { printf '%s' "$1" | sed "s/'/''/g"; }

HOST="$(sq "$(hostname)")"
DIR="$(sq "$PROJECT_DIR")"

case "$OPERATION" in
  push)
    JSON="${3:?Missing json argument for push}"
    DEDUP_KEY="${4:-}"
    TASK_TYPE=$(echo "$JSON"   | jq -r '.type                                          // ""')
    TASK_KEY=$(echo "$JSON"    | jq -r '.key                                           // ""')
    TASK_PR=$(echo "$JSON"     | jq -r 'if .pr_number != null then (.pr_number|tostring) else "" end')
    TASK_BRANCH=$(echo "$JSON" | jq -r '.branch                                        // ""')

    if [ -n "$DEDUP_KEY" ]; then
      # Print 1 if inserted, 0 if dedup conflict — lets callers skip duplicate logging
      psql -t -A -c "
        INSERT INTO tasks (project_dir, task_type, task_key, task_pr_number, task_branch, payload, dedup_key)
        VALUES (
          '$DIR',
          '$(sq "$TASK_TYPE")',
          NULLIF('$(sq "$TASK_KEY")',    ''),
          NULLIF('$(sq "$TASK_PR")',     ''),
          NULLIF('$(sq "$TASK_BRANCH")', ''),
          '$(sq "$JSON")'::jsonb,
          '$(sq "$DEDUP_KEY")'
        ) ON CONFLICT (dedup_key) DO NOTHING
        RETURNING 1;" | grep -c '^1$'
    else
      psql -q -c "
        INSERT INTO tasks (project_dir, task_type, task_key, task_pr_number, task_branch, payload)
        VALUES (
          '$DIR',
          '$(sq "$TASK_TYPE")',
          NULLIF('$(sq "$TASK_KEY")',    ''),
          NULLIF('$(sq "$TASK_PR")',     ''),
          NULLIF('$(sq "$TASK_BRANCH")', ''),
          '$(sq "$JSON")'::jsonb
        );"
    fi
    ;;

  pop)
    psql -t -A -c "
      UPDATE tasks
      SET status='in_progress', started_at=NOW(), worker_host='$HOST'
      WHERE id = (
        SELECT id FROM tasks
        WHERE project_dir='$DIR' AND status='queued'
        ORDER BY queued_at
        LIMIT 1
        FOR UPDATE SKIP LOCKED
      )
      RETURNING payload || jsonb_build_object('id', id);" | grep '^{'
    ;;

  count)
    psql -t -A -c "
      SELECT COUNT(*) FROM tasks
      WHERE project_dir='$DIR' AND status='queued';"
    ;;

  peek)
    psql -t -A -c "
      SELECT payload FROM tasks
      WHERE project_dir='$DIR' AND status='queued'
      ORDER BY queued_at
      LIMIT 1;" | grep '^{'
    ;;

  done)
    TASK_ID="${3:?Missing task-id for done}"
    psql -q -c "
      UPDATE tasks SET status='done', completed_at=NOW()
      WHERE id=$(sq "$TASK_ID") AND project_dir='$DIR';"
    ;;

  requeue)
    TASK_ID="${3:?Missing task-id for requeue}"
    psql -q -c "
      UPDATE tasks SET status='queued', started_at=NULL, worker_host=NULL
      WHERE id=$(sq "$TASK_ID") AND project_dir='$DIR';"
    ;;

  recover)
    # Requeue any in_progress tasks from this host (implies a previous crash on this machine).
    # Prints one line per recovered task: "<id> <task_type> <task_key>"
    psql -t -A -c "
      WITH recovered AS (
        UPDATE tasks SET status='queued', started_at=NULL, worker_host=NULL
        WHERE project_dir='$DIR' AND status='in_progress' AND worker_host='$HOST'
        RETURNING id, task_type, COALESCE(task_key, task_pr_number, '') AS ref
      )
      SELECT id || ' ' || task_type || ' ' || ref FROM recovered;"
    ;;

  *)
    echo "Unknown operation: $OPERATION" >&2
    exit 1
    ;;
esac
