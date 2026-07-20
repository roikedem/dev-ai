-- dev-ai pipeline schema (queue + cost accounting).
-- Reconstructed 20.7.2026: the tasks/cost_log tables were created ad hoc against
-- the DB and never checked in, so a DB move had no source of truth. This file is
-- that source of truth — apply it to any fresh queue database.
-- Web/NextAuth tables live separately in web/scripts/migrate.sql.

CREATE TABLE IF NOT EXISTS tasks (
  id              BIGSERIAL PRIMARY KEY,
  project_dir     TEXT NOT NULL,
  task_type       TEXT NOT NULL,
  task_key        TEXT,
  task_pr_number  TEXT,
  task_branch     TEXT,
  payload         JSONB NOT NULL,
  dedup_key       TEXT UNIQUE,
  status          TEXT NOT NULL DEFAULT 'queued',
  worker_host     TEXT,
  queued_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  context_notes   TEXT,
  labels          TEXT[]
);

-- pop/peek: highest-priority queued task per project, oldest first on ties.
CREATE INDEX IF NOT EXISTS tasks_queue_idx
  ON tasks (project_dir, status, queued_at);

CREATE TABLE IF NOT EXISTS cost_log (
  id                  BIGSERIAL PRIMARY KEY,
  agent_type          TEXT NOT NULL,
  project_dir         TEXT,
  task_key            TEXT,
  task_type           TEXT,
  model               TEXT,
  input_tokens        BIGINT,
  output_tokens       BIGINT,
  cache_read_tokens   BIGINT,
  cache_write_tokens  BIGINT,
  cost_usd            NUMERIC(12,6),
  logged_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
