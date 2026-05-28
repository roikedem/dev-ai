'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';

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
  const router = useRouter();
  const [status, setStatus] = useState(initialStatus);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);

  async function handleChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const next = e.target.value;
    setLoading(true);
    setError(false);
    try {
      const res = await fetch('/api/tasks', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: taskId, status: next }),
      });
      if (res.ok) {
        setStatus(next);
        router.refresh();
      } else {
        setError(true);
      }
    } catch {
      setError(true);
    } finally {
      setLoading(false);
    }
  }

  return (
    <select
      value={status}
      onChange={handleChange}
      disabled={loading}
      title={error ? 'Failed to update status' : undefined}
      className={`text-xs px-1.5 py-0.5 rounded font-medium cursor-pointer ${error ? 'outline outline-1 outline-red-400' : 'border-0'} ${STATUS_COLORS[status] ?? 'bg-gray-100 text-gray-700'}`}
    >
      <option value="queued">queued</option>
      <option value="in_progress">in progress</option>
      <option value="done">done</option>
    </select>
  );
}
