import { auth } from '@/auth';
import { getTasks, getDistinctProjects, jiraUrl, githubPrUrl, type TaskGroup } from '@/lib/tasks';
import Link from 'next/link';
import StatusChanger from './StatusChanger';
import FilterBar from './FilterBar';

const TASK_TYPE_LABELS: Record<string, string> = {
  jira_issue: 'Issue',
  jira_comment: 'Comment',
  github_pr_comment: 'PR Comment',
  github_pr_review: 'PR Review',
  github_pr_merged: 'PR Merged',
};

const STATUS_COLORS: Record<string, string> = {
  queued: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-green-100 text-green-700',
};

function groupStatus(group: TaskGroup): string {
  if (group.tasks.some((t) => t.status === 'queued')) return 'queued';
  if (group.tasks.some((t) => t.status === 'in_progress')) return 'in_progress';
  return 'done';
}

function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

export default async function Dashboard({
  searchParams,
}: {
  searchParams: Promise<{ project?: string; type?: string; status?: string; search?: string }>;
}) {
  const params = await searchParams;
  const session = await auth();
  const [groups, projects] = await Promise.all([
    getTasks(params),
    getDistinctProjects(),
  ]);

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <header className="bg-white border-b border-gray-200 px-6 py-3 flex items-center justify-between">
        <h1 className="text-lg font-semibold text-gray-900">dev-ai tasks</h1>
        <div className="flex items-center gap-4 text-sm text-gray-500">
          {session?.user?.isAdmin && (
            <Link href="/admin/users" className="hover:text-gray-900">Users</Link>
          )}
          <span>{session?.user?.email}</span>
          <form action="/api/auth/signout" method="POST">
            <button className="hover:text-gray-900">Sign out</button>
          </form>
        </div>
      </header>

      {/* Filters */}
      <div className="bg-white border-b border-gray-200 px-6 py-3">
        <FilterBar params={params} projects={projects} />
      </div>

      {/* Stats */}
      <div className="px-6 py-2 text-xs text-gray-400 border-b border-gray-100 bg-white">
        {groups.length} group{groups.length !== 1 ? 's' : ''}
        {' · '}
        {groups.reduce((s, g) => s + g.tasks.length, 0)} tasks
      </div>

      {/* Task list */}
      <main className="px-6 py-4">
        {groups.length === 0 && (
          <div className="text-center py-16 text-gray-400">No tasks found</div>
        )}
        <div className="space-y-2">
          {groups.map((group) => (
            <GroupCard key={group.groupKey} group={group} />
          ))}
        </div>
      </main>
    </div>
  );
}

function GroupCard({ group }: { group: TaskGroup }) {
  const status = groupStatus(group);
  const firstTask = group.tasks[0];
  const payload = firstTask?.payload ?? {};
  const summary = (payload.summary ?? payload.pr_title ?? payload.body ?? '') as string;
  const jiraLink = group.taskKey ? jiraUrl(group.taskKey) : null;
  const ghLink = githubPrUrl(payload);

  return (
    <div className="bg-white rounded-lg border border-gray-200 overflow-hidden">
      {/* Group header */}
      <div className="flex items-start gap-3 px-4 py-3">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            {group.taskKey && (
              <span className="font-mono text-sm font-semibold text-gray-900">
                {group.taskKey}
              </span>
            )}
            <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${STATUS_COLORS[status]}`}>
              {status.replace('_', ' ')}
            </span>
            {jiraLink && (
              <a
                href={jiraLink}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-blue-600 hover:underline"
              >
                Jira
              </a>
            )}
            {ghLink && (
              <a
                href={ghLink}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-purple-600 hover:underline"
              >
                PR #{firstTask.task_pr_number}
              </a>
            )}
          </div>
          {summary && (
            <p className="text-sm text-gray-600 mt-0.5 truncate">{String(summary).slice(0, 120)}</p>
          )}
        </div>
        <div className="text-xs text-gray-400 whitespace-nowrap">
          {relativeTime(group.latestAt)}
        </div>
      </div>

      {/* Subtasks */}
      <div className="border-t border-gray-100 divide-y divide-gray-100">
        {group.tasks.map((task) => {
          const prLink = githubPrUrl(task.payload);
          return (
            <div key={task.id} className="flex items-center gap-3 px-4 py-2 text-sm">
              <span className="text-xs text-gray-400 font-mono w-8"># {task.id}</span>
              <span className="text-xs text-gray-500 w-28 shrink-0">
                {TASK_TYPE_LABELS[task.task_type] ?? task.task_type}
              </span>
              <span className="text-xs text-gray-400 truncate flex-1">
                {(task.payload.author as string) ?? (task.payload.state as string) ?? ''}
                {task.task_branch && (
                  <span className="ml-1 font-mono text-gray-300">{task.task_branch}</span>
                )}
              </span>
              {prLink && (
                <a href={prLink} target="_blank" rel="noopener noreferrer" className="text-xs text-purple-500 hover:underline shrink-0">
                  PR #{task.task_pr_number}
                </a>
              )}
              <span className="text-xs text-gray-400 shrink-0 w-16 text-right">
                {relativeTime(task.queued_at)}
              </span>
              <StatusChanger taskId={task.id} status={task.status} />
              <Link
                href={`/tasks/${task.id}`}
                className="text-xs text-gray-400 hover:text-gray-900 shrink-0"
              >
                Detail →
              </Link>
            </div>
          );
        })}
      </div>
    </div>
  );
}
