import { auth } from '@/auth';
import { getTask, getRelatedTasks, jiraUrl, githubPrUrl } from '@/lib/tasks';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import StatusChanger from '../../StatusChanger';

const TASK_TYPE_LABELS: Record<string, string> = {
  jira_issue: 'Jira Issue',
  jira_comment: 'Jira Comment',
  github_pr_comment: 'GitHub PR Comment',
  github_pr_review: 'GitHub PR Review',
  github_pr_merged: 'GitHub PR Merged',
};

const STATUS_COLORS: Record<string, string> = {
  queued: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-green-100 text-green-700',
};

function fmt(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('en-US', {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

export default async function TaskDetail({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  await auth(); // ensures session exists (middleware already guards)

  const task = await getTask(Number(id));
  if (!task) notFound();

  const related = task.task_key ? await getRelatedTasks(task.task_key) : [task];
  const jiraLink = task.task_key ? jiraUrl(task.task_key) : null;
  const ghLink = githubPrUrl(task.payload);

  return (
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-200 px-6 py-3 flex items-center gap-4">
        <Link href="/" className="text-gray-500 hover:text-gray-900 text-sm">← Back</Link>
        <span className="text-gray-300">|</span>
        <h1 className="text-base font-semibold text-gray-900">
          {task.task_key ?? `Task #${task.id}`}
        </h1>
        {jiraLink && (
          <a href={jiraLink} target="_blank" rel="noopener noreferrer"
            className="text-sm text-blue-600 hover:underline">
            Open in Jira
          </a>
        )}
        {ghLink && (
          <a href={ghLink} target="_blank" rel="noopener noreferrer"
            className="text-sm text-purple-600 hover:underline">
            PR #{task.task_pr_number}
          </a>
        )}
      </header>

      <main className="max-w-4xl mx-auto px-6 py-6 space-y-6">
        {/* Related tasks */}
        {task.task_key && related.length > 1 && (
          <section className="bg-white rounded-lg border border-gray-200 p-4">
            <h2 className="text-sm font-semibold text-gray-700 mb-3">
              Related tasks — {task.task_key} ({related.length})
            </h2>
            <div className="space-y-1">
              {related.map((r) => (
                <Link
                  key={r.id}
                  href={`/tasks/${r.id}`}
                  className={`flex items-center gap-3 text-sm px-2 py-1.5 rounded hover:bg-gray-50 ${r.id === task.id ? 'bg-blue-50' : ''}`}
                >
                  <span className="font-mono text-xs text-gray-400 w-8">#{r.id}</span>
                  <span className={`text-xs px-1.5 py-0.5 rounded-full font-medium ${STATUS_COLORS[r.status] ?? ''}`}>
                    {r.status.replace('_', ' ')}
                  </span>
                  <span className="text-xs text-gray-500">
                    {TASK_TYPE_LABELS[r.task_type] ?? r.task_type}
                  </span>
                  <span className="text-xs text-gray-400 truncate flex-1">
                    {r.payload.author as string ?? r.payload.summary as string ?? ''}
                  </span>
                  <span className="text-xs text-gray-300">{fmt(r.queued_at)}</span>
                </Link>
              ))}
            </div>
          </section>
        )}

        {/* Task detail */}
        <section className="bg-white rounded-lg border border-gray-200 p-4">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-sm font-semibold text-gray-700">Task #{task.id}</h2>
            <StatusChanger taskId={task.id} status={task.status} />
          </div>

          <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt className="text-gray-400">Type</dt>
            <dd>{TASK_TYPE_LABELS[task.task_type] ?? task.task_type}</dd>

            <dt className="text-gray-400">Project</dt>
            <dd className="font-mono text-xs text-gray-600">{task.project_dir}</dd>

            {task.task_key && (
              <>
                <dt className="text-gray-400">Jira key</dt>
                <dd>
                  <a href={jiraUrl(task.task_key)} target="_blank" rel="noopener noreferrer"
                    className="text-blue-600 hover:underline font-mono">
                    {task.task_key}
                  </a>
                </dd>
              </>
            )}

            {task.task_pr_number && ghLink && (
              <>
                <dt className="text-gray-400">GitHub PR</dt>
                <dd>
                  <a href={ghLink} target="_blank" rel="noopener noreferrer"
                    className="text-purple-600 hover:underline">
                    #{task.task_pr_number} — {task.payload.pr_title as string ?? ''}
                  </a>
                </dd>
              </>
            )}

            {task.task_branch && (
              <>
                <dt className="text-gray-400">Branch</dt>
                <dd className="font-mono text-xs">{task.task_branch}</dd>
              </>
            )}

            <dt className="text-gray-400">Queued</dt>
            <dd>{fmt(task.queued_at)}</dd>

            {task.started_at && (
              <>
                <dt className="text-gray-400">Started</dt>
                <dd>{fmt(task.started_at)}</dd>
              </>
            )}

            {task.completed_at && (
              <>
                <dt className="text-gray-400">Completed</dt>
                <dd>{fmt(task.completed_at)}</dd>
              </>
            )}

            {task.worker_host && (
              <>
                <dt className="text-gray-400">Worker</dt>
                <dd className="font-mono text-xs">{task.worker_host}</dd>
              </>
            )}

            {task.context_notes && (
              <>
                <dt className="text-gray-400">Notes</dt>
                <dd className="text-gray-600 whitespace-pre-wrap">{task.context_notes}</dd>
              </>
            )}
          </dl>
        </section>

        {/* Payload */}
        <section className="bg-white rounded-lg border border-gray-200 p-4">
          <h2 className="text-sm font-semibold text-gray-700 mb-2">Payload</h2>
          <pre className="text-xs text-gray-600 bg-gray-50 rounded p-3 overflow-auto max-h-96">
            {JSON.stringify(task.payload, null, 2)}
          </pre>
        </section>
      </main>
    </div>
  );
}
