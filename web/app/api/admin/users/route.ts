import { auth } from '@/auth';
import pool from '@/lib/db';
import { NextRequest, NextResponse } from 'next/server';

const ADMIN_EMAIL = 'roikedem@gmail.com';

async function requireAdmin() {
  const session = await auth();
  if (!session || session.user.email !== ADMIN_EMAIL) return null;
  return session;
}

export async function GET() {
  if (!(await requireAdmin())) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }
  const { rows } = await pool.query(
    'SELECT id, email, created_at FROM web_users ORDER BY created_at'
  );
  return NextResponse.json(rows);
}

export async function POST(req: NextRequest) {
  if (!(await requireAdmin())) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }
  const { email } = await req.json() as { email: string };
  if (!email || !email.includes('@')) {
    return NextResponse.json({ error: 'Invalid email' }, { status: 400 });
  }
  await pool.query(
    'INSERT INTO web_users (email) VALUES ($1) ON CONFLICT (email) DO NOTHING',
    [email.toLowerCase().trim()]
  );
  return NextResponse.json({ ok: true });
}

export async function DELETE(req: NextRequest) {
  if (!(await requireAdmin())) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }
  const { email } = await req.json() as { email: string };
  if (email === ADMIN_EMAIL) {
    return NextResponse.json({ error: 'Cannot remove admin' }, { status: 400 });
  }
  await pool.query('DELETE FROM web_users WHERE email = $1', [email]);
  return NextResponse.json({ ok: true });
}
