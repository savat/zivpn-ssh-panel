import { createHash, timingSafeEqual } from 'node:crypto';
import { NextResponse } from 'next/server';
import { COOKIE, MAX_AGE, createSession } from '@/lib/session';
import { readJson } from '@/lib/http';

export const runtime = 'nodejs';

const sha = (s: string) => createHash('sha256').update(s).digest();

export async function POST(req: Request) {
  const body = await readJson(req);
  const given = typeof body.password === 'string' ? body.password : '';
  const expected = process.env.ADMIN_PASSWORD || '';
  if (!expected || !timingSafeEqual(sha(given), sha(expected))) {
    await new Promise((r) => setTimeout(r, 800)); // หน่วงเล็กน้อยกันเดารหัสรัวๆ
    return NextResponse.json({ error: 'รหัสผ่านไม่ถูกต้อง' }, { status: 401 });
  }
  const res = NextResponse.json({ ok: true });
  res.cookies.set(COOKIE, await createSession(), {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'strict',
    path: '/',
    maxAge: MAX_AGE,
  });
  return res;
}
