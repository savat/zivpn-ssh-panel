import { NextResponse } from 'next/server';
import { execOnServer } from '@/lib/servers';
import { bad, fail } from '@/lib/http';
import { RE_ID } from '@/lib/validate';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 30;

type Ctx = { params: Promise<{ id: string }> };

// คำสั่งคงที่ ไม่มีค่าจากผู้ใช้ปนเข้าไป  (อ่าน /proc อย่างเดียว ใช้ได้กับผู้ใช้ทั่วไปไม่ต้อง root)
const cmd = (M: string) =>
  [
    'echo @@U; cat /proc/uptime',
    'echo @@C; head -n1 /proc/stat',
    "echo @@M; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo",
    'echo @@L; cat /proc/loadavg',
    'echo @@N; nproc',
    'echo @@D; df -kP / | tail -n1',
    'echo @@X; cat /proc/net/dev',
    'echo @@H; hostname',
    'echo @@O; [ -r /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"',
    `echo @@S; ${M} api status 2>/dev/null`,
  ].join('; ');

function sections(out: string): Record<string, string> {
  const o: Record<string, string> = {};
  let k = '';
  for (const line of out.split('\n')) {
    if (line.startsWith('@@')) { k = line.slice(2).trim(); o[k] = ''; }
    else if (k) o[k] += line + '\n';
  }
  return o;
}

const num = (s: string | undefined) => { const n = Number(s); return Number.isFinite(n) ? n : 0; };

export async function GET(_req: Request, { params }: Ctx) {
  try {
    const { id } = await params;
    if (!RE_ID.test(id)) return bad('id ไม่ถูกต้อง');
    const r = await execOnServer(id, cmd);
    if (!r.stdout.includes('@@U')) {
      return NextResponse.json({ error: (r.stderr || 'อ่านข้อมูลเครื่องไม่ได้').trim().slice(0, 300), code: 'REMOTE' }, { status: 502 });
    }
    const s = sections(r.stdout);

    const up = num(s.U?.trim().split(/\s+/)[0]);

    const c = (s.C ?? '').trim().split(/\s+/).slice(1).map(Number);
    const total = c.slice(0, 8).reduce((a, b) => a + (b || 0), 0);
    const idle = (c[3] || 0) + (c[4] || 0);

    const mm: Record<string, number> = {};
    for (const line of (s.M ?? '').split('\n')) {
      const m = line.match(/^(\w+):\s+(\d+)/);
      if (m) mm[m[1]] = Number(m[2]);
    }

    const load = (s.L ?? '').trim().split(/\s+/).slice(0, 3).map(Number);
    const cores = Math.max(1, Math.round(num(s.N?.trim())));

    const d = (s.D ?? '').trim().split(/\s+/);
    const disk = { total: num(d[1]), used: num(d[2]), avail: num(d[3]), mount: d[5] || '/' };

    let rx = 0;
    let tx = 0;
    for (const line of (s.X ?? '').split('\n')) {
      const i = line.indexOf(':');
      if (i < 0) continue;
      const iface = line.slice(0, i).trim();
      if (/^(lo|ifb|veth|docker|br-|virbr|tun|tap)/.test(iface)) continue;
      const f = line.slice(i + 1).trim().split(/\s+/).map(Number);
      rx += f[0] || 0;
      tx += f[8] || 0;
    }

    const st: Record<string, string> = {};
    for (const line of (s.S ?? '').split('\n')) {
      const i = line.indexOf('=');
      if (i > 0) st[line.slice(0, i)] = line.slice(i + 1);
    }
    const zivpn = st.version
      ? { installed: true, service: st.service === '1', total: num(st.total), active: num(st.active), port: st.port, range: st.range, host: st.host }
      : { installed: false };

    return NextResponse.json({
      up,
      cpu: { busy: total - idle, total },
      cores,
      load,
      mem: { total: mm.MemTotal || 0, avail: mm.MemAvailable ?? mm.MemFree ?? 0, swapTotal: mm.SwapTotal || 0, swapFree: mm.SwapFree || 0 },
      disk,
      net: { rx, tx },
      host: (s.H ?? '').trim(),
      os: (s.O ?? '').trim(),
      zivpn,
    });
  } catch (e) {
    return fail(e);
  }
}
