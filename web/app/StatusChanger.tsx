'use client';

import { useState } from 'react';

const STATUS_COLORS: Record<string, string> = {
  queued: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-green-100 text-green-700',
};

export default function StatusChanger({
  taskId,
  status: initialStatus,
}: {
  taskId: number;
  status: string;
}) {
  const [status, setStatus] = useState(initialStatus);
  const [loading, setLoading] = useState(false);

  async function handleChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const next = e.target.value;
    setLoading(true);
    try {
      const res = await fetch('/api/tasks', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: taskId, status: next }),
      });
      if (res.ok) setStatus(next);
    } finally {
      setLoading(false);
    }
  }

  return (
    <select
      value={status}
      onChange={handleChange}
      disabled={loading}
      className={`text-xs px-1.5 py-0.5 rounded border-0 font-medium cursor-pointer ${STATUS_COLORS[status] ?? 'bg-gray-100 text-gray-700'}`}
    >
      <option value="queued">queued</option>
      <option value="in_progress">in progress</option>
      <option value="done">done</option>
    </select>
  );
}
