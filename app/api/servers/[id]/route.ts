import { NextResponse } from 'next/server';
import { deleteServer, updateServer } from '@/lib/servers';
import { bad, fail, readJson, str } from '@/lib/http';
import { RE_HOST, RE_ID, RE_SSHUSER, parsePort } from '@/lib/validate';

export const runtime = 'nodejs';

type Ctx = { params: Promise<{ id: string }> };

export async function PATCH(req: Request, { params }: Ctx) {
  try {
    const { id } = await params;
    if (!RE_ID.test(id)) return bad('id ไม่ถูกต้อง');
    const b = await readJson(req);
    const patch: Parameters<typeof updateServer>[1] = {};
    if (b.name !== undefined) {
      const v = str(b.name);
      if (v.length < 1 || v.length > 60) return bad('ชื่อต้องยาว 1-60 ตัวอักษร');
      patch.name = v;
    }
    if (b.host !== undefined) {
      const v = str(b.host);
      if (!RE_HOST.test(v)) return bad('IP/โดเมนไม่ถูกต้อง');
      patch.host = v;
    }
    if (b.username !== undefined) {
      const v = str(b.username);
      if (!RE_SSHUSER.test(v)) return bad('ชื่อผู้ใช้ SSH ไม่ถูกต้อง');
      patch.username = v;
    }
    if (b.port !== undefined) {
      const v = parsePort(b.port);
      if (v === null) return bad('พอร์ต SSH ต้องเป็น 1-65535');
      patch.port = v;
    }
    if (typeof b.password === 'string' && b.password !== '') {
      if (b.password.length > 256) return bad('รหัสผ่านยาวเกินไป');
      patch.password = b.password;
    }
    if (b.resetFingerprint === true) patch.resetFingerprint = true;
    return NextResponse.json({ server: await updateServer(id, patch) });
  } catch (e) {
    return fail(e);
  }
}

export async function DELETE(_req: Request, { params }: Ctx) {
  try {
    const { id } = await params;
    if (!RE_ID.test(id)) return bad('id ไม่ถูกต้อง');
    await deleteServer(id);
    return NextResponse.json({ ok: true });
  } catch (e) {
    return fail(e);
  }
}
