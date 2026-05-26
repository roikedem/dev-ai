'use client';

import { useEffect, useState } from 'react';

interface WebUser {
  id: number;
  email: string;
  created_at: string;
}

export default function AdminUsers() {
  const [users, setUsers] = useState<WebUser[]>([]);
  const [email, setEmail] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const res = await fetch('/api/admin/users');
    if (res.ok) setUsers(await res.json());
    else setError('Forbidden');
  }

  useEffect(() => { load(); }, []);

  async function addUser(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    const res = await fetch('/api/admin/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    });
    setLoading(false);
    if (res.ok) { setEmail(''); load(); }
    else setError('Failed to add user');
  }

  async function removeUser(userEmail: string) {
    if (!confirm(`Remove ${userEmail}?`)) return;
    const res = await fetch('/api/admin/users', {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: userEmail }),
    });
    if (res.ok) load();
    else setError('Failed to remove user');
  }

  return (
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-200 px-6 py-3 flex items-center gap-4">
        <a href="/" className="text-gray-500 hover:text-gray-900 text-sm">← Back</a>
        <h1 className="text-base font-semibold text-gray-900">Allowed users</h1>
      </header>

      <main className="max-w-xl mx-auto px-6 py-6 space-y-6">
        {error && (
          <div className="bg-red-50 border border-red-200 rounded p-3 text-sm text-red-700">{error}</div>
        )}

        {/* Add user */}
        <section className="bg-white rounded-lg border border-gray-200 p-4">
          <h2 className="text-sm font-semibold text-gray-700 mb-3">Add user</h2>
          <form onSubmit={addUser} className="flex gap-2">
            <input
              type="email"
              placeholder="user@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              className="flex-1 border border-gray-300 rounded px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
            />
            <button
              type="submit"
              disabled={loading}
              className="bg-gray-900 text-white rounded px-3 py-1.5 text-sm hover:bg-gray-700 disabled:opacity-50"
            >
              Add
            </button>
          </form>
        </section>

        {/* User list */}
        <section className="bg-white rounded-lg border border-gray-200 divide-y divide-gray-100">
          {users.map((u) => (
            <div key={u.id} className="flex items-center justify-between px-4 py-3">
              <div>
                <p className="text-sm text-gray-900">{u.email}</p>
                <p className="text-xs text-gray-400">
                  Added {new Date(u.created_at).toLocaleDateString()}
                </p>
              </div>
              <button
                onClick={() => removeUser(u.email)}
                className="text-xs text-red-500 hover:text-red-700"
              >
                Remove
              </button>
            </div>
          ))}
          {users.length === 0 && (
            <div className="px-4 py-6 text-sm text-gray-400 text-center">No users yet</div>
          )}
        </section>
      </main>
    </div>
  );
}
