import pool from './db';

export type TaskStatus = 'queued' | 'in_progress' | 'done';

export interface Task {
  id: number;
  project_dir: string;
  task_type: string;
  task_key: string | null;
  task_pr_number: string | null;
  task_branch: string | null;
  payload: Record<string, unknown>;
  dedup_key: string | null;
  status: TaskStatus;
  worker_host: string | null;
  queued_at: string;
  started_at: string | null;
  completed_at: string | null;
  context_notes: string | null;
  labels: string[] | null;
}

export interface TaskGroup {
  groupKey: string;
  taskKey: string | null;
  tasks: Task[];
  latestAt: string;
  project_dir: string;
}

export interface TaskFilters {
  project?: string;
  type?: string;
  status?: string;
  search?: string;
  page?: number;
  pageSize?: number;
}

export interface TaskPage {
  groups: TaskGroup[];
  total: number;
  page: number;
  pageSize: number;
}

export async function getTasks(filters: TaskFilters = {}): Promise<TaskPage> {
  const page = Math.max(1, filters.page ?? 1);
  const pageSize = filters.pageSize ?? 20;
  const offset = (page - 1) * pageSize;

  const conditions: string[] = [];
  const params: unknown[] = [];
  let idx = 1;

  if (filters.project) {
    conditions.push(`project_dir = $${idx++}`);
    params.push(filters.project);
  }
  if (filters.type) {
    conditions.push(`task_type = $${idx++}`);
    params.push(filters.type);
  }
  if (filters.status) {
    conditions.push(`status = $${idx++}`);
    params.push(filters.status);
  }
  if (filters.search) {
    conditions.push(`(task_key ILIKE $${idx} OR payload::text ILIKE $${idx})`);
    params.push(`%${filters.search}%`);
    idx++;
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  const [{ rows }, { rows: countRows }] = await Promise.all([
    pool.query<Task & { group_latest: string }>(
      `WITH paged_groups AS (
         SELECT COALESCE(task_key, 'id:' || id::text) AS gk, MAX(queued_at) AS latest
         FROM tasks ${where}
         GROUP BY COALESCE(task_key, 'id:' || id::text)
         ORDER BY MAX(queued_at) DESC
         LIMIT $${idx} OFFSET $${idx + 1}
       )
       SELECT t.*, pg.latest AS group_latest
       FROM tasks t
       JOIN paged_groups pg ON COALESCE(t.task_key, 'id:' || t.id::text) = pg.gk
       ORDER BY pg.latest DESC, COALESCE(t.task_key, 'id:' || t.id::text), t.queued_at DESC`,
      [...params, pageSize, offset]
    ),
    pool.query<{ total: string }>(
      `SELECT COUNT(DISTINCT COALESCE(task_key, 'id:' || id::text)) AS total FROM tasks ${where}`,
      params
    ),
  ]);

  const groupMap = new Map<string, TaskGroup>();
  for (const row of rows) {
    const { group_latest, ...task } = row;
    const groupKey = task.task_key ?? `id:${task.id}`;
    if (!groupMap.has(groupKey)) {
      groupMap.set(groupKey, {
        groupKey,
        taskKey: task.task_key,
        tasks: [],
        latestAt: group_latest,
        project_dir: task.project_dir,
      });
    }
    groupMap.get(groupKey)!.tasks.push(task);
  }

  return {
    groups: Array.from(groupMap.values()),
    total: parseInt(countRows[0].total, 10),
    page,
    pageSize,
  };
}

export async function getTask(id: number): Promise<Task | null> {
  const { rows } = await pool.query<Task>('SELECT * FROM tasks WHERE id = $1', [id]);
  return rows[0] ?? null;
}

export async function getRelatedTasks(taskKey: string): Promise<Task[]> {
  const { rows } = await pool.query<Task>(
    'SELECT * FROM tasks WHERE task_key = $1 ORDER BY queued_at DESC',
    [taskKey]
  );
  return rows;
}

export async function updateTaskStatus(id: number, status: TaskStatus): Promise<void> {
  const extra =
    status === 'done'
      ? ', completed_at = NOW()'
      : status === 'in_progress'
      ? ', started_at = NOW()'
      : ', started_at = NULL, completed_at = NULL';
  await pool.query(
    `UPDATE tasks SET status = $1${extra} WHERE id = $2`,
    [status, id]
  );
}

export async function getDistinctProjects(): Promise<string[]> {
  const { rows } = await pool.query<{ project_dir: string }>(
    'SELECT DISTINCT project_dir FROM tasks ORDER BY project_dir'
  );
  return rows.map((r) => r.project_dir);
}

export function projectLabel(dir: string): string {
  return dir.split('/').filter(Boolean).pop() ?? dir;
}

export function jiraUrl(key: string): string {
  return `https://intotodev.atlassian.net/browse/${key}`;
}

export function githubPrUrl(payload: Record<string, unknown>): string | null {
  const repo = payload.repo as string | undefined;
  const pr = payload.pr_number as number | string | undefined;
  if (!repo || !pr) return null;
  return `https://github.com/${repo}/pull/${pr}`;
}
