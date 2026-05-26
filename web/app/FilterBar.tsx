'use client';

const TASK_TYPE_LABELS: Record<string, string> = {
  jira_issue: 'Issue',
  jira_comment: 'Comment',
  github_pr_comment: 'PR Comment',
  github_pr_review: 'PR Review',
  github_pr_merged: 'PR Merged',
};

export default function FilterBar({
  params,
  projects,
}: {
  params: { project?: string; type?: string; status?: string; search?: string };
  projects: string[];
}) {
  function projectLabel(dir: string) {
    return dir.split('/').filter(Boolean).pop() ?? dir;
  }

  function submit(updates: Record<string, string>) {
    const f = new URLSearchParams();
    const merged = { ...params, ...updates };
    for (const [k, v] of Object.entries(merged)) {
      if (v) f.set(k, v);
    }
    window.location.search = f.toString();
  }

  return (
    <form
      className="flex flex-wrap gap-3 text-sm"
      onSubmit={(e) => {
        e.preventDefault();
        const fd = new FormData(e.currentTarget);
        submit({
          project: fd.get('project') as string ?? '',
          type: fd.get('type') as string ?? '',
          status: fd.get('status') as string ?? '',
          search: fd.get('search') as string ?? '',
        });
      }}
    >
      <select
        name="project"
        defaultValue={params.project ?? ''}
        className="border border-gray-300 rounded px-2 py-1 bg-white"
        onChange={(e) => submit({ project: e.target.value })}
      >
        <option value="">All projects</option>
        {projects.map((p) => (
          <option key={p} value={p}>{projectLabel(p)}</option>
        ))}
      </select>
      <select
        name="type"
        defaultValue={params.type ?? ''}
        className="border border-gray-300 rounded px-2 py-1 bg-white"
        onChange={(e) => submit({ type: e.target.value })}
      >
        <option value="">All types</option>
        {Object.entries(TASK_TYPE_LABELS).map(([k, v]) => (
          <option key={k} value={k}>{v}</option>
        ))}
      </select>
      <select
        name="status"
        defaultValue={params.status ?? ''}
        className="border border-gray-300 rounded px-2 py-1 bg-white"
        onChange={(e) => submit({ status: e.target.value })}
      >
        <option value="">All statuses</option>
        <option value="queued">Queued</option>
        <option value="in_progress">In progress</option>
        <option value="done">Done</option>
      </select>
      <input
        type="text"
        name="search"
        defaultValue={params.search ?? ''}
        placeholder="Search key / payload..."
        className="border border-gray-300 rounded px-2 py-1 flex-1 min-w-40"
      />
      <button
        type="submit"
        className="bg-gray-900 text-white rounded px-3 py-1 hover:bg-gray-700"
      >
        Filter
      </button>
      {Object.values(params).some(Boolean) && (
        <a href="/" className="text-gray-500 hover:text-gray-900 py-1">Clear</a>
      )}
    </form>
  );
}
