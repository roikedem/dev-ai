import { auth } from '@/auth';
import { updateTaskStatus, type TaskStatus } from '@/lib/tasks';
import { NextRequest, NextResponse } from 'next/server';

export async function PATCH(req: NextRequest) {
  const session = await auth();
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const { id, status } = await req.json() as { id: number; status: TaskStatus };
  if (!id || !['queued', 'in_progress', 'done'].includes(status)) {
    return NextResponse.json({ error: 'Invalid params' }, { status: 400 });
  }

  await updateTaskStatus(id, status);
  return NextResponse.json({ ok: true });
}
