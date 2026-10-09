import { NextResponse } from 'next/server';
import { execOnServer } from '@/lib/servers';
import { bad, fail } from '@/lib/http';
import { RE_ID } from '@/lib/validate';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

type Ctx = { params: Promise<{ id: string }> };

export async function GET(_req: Request, { params }: Ctx) {
  try {
    const { id } = await params;
    if (!RE_ID.test(id)) return bad('id ไม่ถูกต้อง');

    const r = await execOnServer(id, (M) => `${M} api status && echo @@USERS && ${M} api list`);
    if (r.code === 127) return NextResponse.json({ installed: false, status: {}, users: [] });
    if (r.code !== 0) {
      const msg = (r.stderr || r.stdout).replace(/\u001b\[[0-9;]*m/g, '').trim() || `คำสั่งล้มเหลว (exit ${r.code})`;
      return NextResponse.json({ error: msg, code: 'REMOTE' }, { status: 502 });
    }

    const [head, tail = ''] = r.stdout.split('@@USERS\n');
    const status: Record<string, string> = {};
    for (const line of head.split('\n')) {
      const i = line.indexOf('=');
      if (i > 0) status[line.slice(0, i)] = line.slice(i + 1);
    }
    const users = tail
      .split('\n')
      .filter(Boolean)
      .map((l) => {
        const [name, password, exp, state] = l.split('|');
        return { name, password, expires: Number(exp), state };
      });
    return NextResponse.json({ installed: true, status, users });
  } catch (e) {
    return fail(e);
  }
}
