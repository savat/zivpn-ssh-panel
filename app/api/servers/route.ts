import { NextResponse } from 'next/server';
import { createServer, listServers } from '@/lib/servers';
import { bad, fail, readJson, str } from '@/lib/http';
import { RE_HOST, RE_SSHUSER, parsePort } from '@/lib/validate';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    return NextResponse.json({ servers: await listServers() });
  } catch (e) {
    return fail(e);
  }
}

export async function POST(req: Request) {
  try {
    const b = await readJson(req);
    const name = str(b.name);
    const host = str(b.host);
    const username = str(b.username) || 'root';
    const port = b.port === undefined || b.port === '' ? 22 : parsePort(b.port);
    const password = typeof b.password === 'string' ? b.password : '';
    if (name.length < 1 || name.length > 60) return bad('ชื่อต้องยาว 1-60 ตัวอักษร');
    if (!RE_HOST.test(host)) return bad('IP/โดเมนไม่ถูกต้อง');
    if (!RE_SSHUSER.test(username)) return bad('ชื่อผู้ใช้ SSH ไม่ถูกต้อง');
    if (port === null) return bad('พอร์ต SSH ต้องเป็น 1-65535');
    if (password.length < 1 || password.length > 256) return bad('กรอกรหัสผ่าน SSH');
    return NextResponse.json({ server: await createServer({ name, host, port, username, password }) });
  } catch (e) {
    return fail(e);
  }
}
