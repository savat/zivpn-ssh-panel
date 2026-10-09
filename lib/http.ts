import { NextResponse } from 'next/server';
import { SshError } from './servers';

export const bad = (message: string) => NextResponse.json({ error: message }, { status: 400 });

export function fail(e: unknown) {
  if (e instanceof SshError) {
    return NextResponse.json({ error: e.message, code: e.code }, { status: e.code === 'NOT_FOUND' ? 404 : 502 });
  }
  const message = e instanceof Error ? e.message : 'เกิดข้อผิดพลาด';
  return NextResponse.json({ error: message }, { status: 500 });
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  try {
    const j = await req.json();
    return j && typeof j === 'object' ? (j as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

export const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
