import { NextResponse } from 'next/server';
import { execOnServer } from '@/lib/servers';
import { bad, fail, readJson, str } from '@/lib/http';
import { RE_ID, RE_PASS, RE_USER, parseDays, shq } from '@/lib/validate';

export const runtime = 'nodejs';
export const maxDuration = 60;

type Ctx = { params: Promise<{ id: string }> };

export async function POST(req: Request, { params }: Ctx) {
  try {
    const { id } = await params;
    if (!RE_ID.test(id)) return bad('id ไม่ถูกต้อง');
    const b = await readJson(req);
    const action = str(b.action);
    const user = str(b.user);
    const pass = typeof b.password === 'string' ? b.password.trim() : '';

    const needUser = () => (RE_USER.test(user) ? null : bad('ชื่อผู้ใช้ไม่ถูกต้อง (3-32 ตัว: a-z A-Z 0-9 _ -)'));
    const optPass = () => (pass === '' || RE_PASS.test(pass) ? null : bad('รหัสผ่านไม่ถูกต้อง (4-64 ตัว: a-z A-Z 0-9 และ @#%^*_+=.,:;!?~/-)'));

    let build: (M: string) => string;
    switch (action) {
      case 'add': {
        const days = parseDays(b.days);
        const e = needUser() ?? optPass() ?? (days === null ? bad('จำนวนวันต้องเป็น 1-3650') : null);
        if (e) return e;
        build = (M) => `${M} add ${shq(user)} ${shq(pass)} ${days}`;
        break;
      }
      case 'renew': {
        const days = parseDays(b.days);
        const e = needUser() ?? (days === null ? bad('จำนวนวันต้องเป็น 1-3650') : null);
        if (e) return e;
        build = (M) => `${M} renew ${shq(user)} ${days}`;
        break;
      }
      case 'passwd': {
        const e = needUser() ?? optPass();
        if (e) return e;
        build = (M) => `${M} passwd ${shq(user)} ${shq(pass)}`;
        break;
      }
      case 'on':
      case 'off':
      case 'del': {
        const e = needUser();
        if (e) return e;
        build = (M) => `${M} ${action} ${shq(user)}`;
        break;
      }
      case 'restart':
      case 'backup':
      case 'health':
        build = (M) => `${M} ${action}`;
        break;
      default:
        return bad('ไม่รู้จักคำสั่ง');
    }

    const r = await execOnServer(id, build);
    const output = `${r.stdout}${r.stderr}`.replace(/\u001b\[[0-9;?]*[A-Za-z]/g, '').trim();
    return NextResponse.json({ ok: r.code === 0, output });
  } catch (e) {
    return fail(e);
  }
}
