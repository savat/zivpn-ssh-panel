export type Server = { id: string; name: string; host: string; port: number; username: string; host_fingerprint: string | null };
export type User = { name: string; password: string; expires: number; state: 'active' | 'expired' | 'off' };
export type Overview = { installed: boolean; status: Record<string, string>; users: User[] };
export type ApiErr = Error & { code?: string };
export type Metrics = {
  up: number;
  cpu: { busy: number; total: number };
  cores: number;
  load: number[];
  mem: { total: number; avail: number; swapTotal: number; swapFree: number }; // kB
  disk: { total: number; used: number; avail: number; mount: string }; // kB
  net: { rx: number; tx: number }; // bytes (สะสมตั้งแต่บูต)
  host: string;
  os: string;
  zivpn: { installed: boolean; service?: boolean; total?: number; active?: number; port?: string; range?: string; host?: string };
};

export async function api<T>(url: string, method = 'GET', body?: unknown): Promise<T> {
  const r = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: 'no-store',
  });
  if (r.status === 401) {
    window.location.href = '/login';
    throw new Error('หมดเวลาเข้าสู่ระบบ');
  }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(j.error || r.statusText), { code: j.code }) as ApiErr;
  return j as T;
}

export const clamp = (n: number, a = 0, b = 100) => Math.min(b, Math.max(a, n));

export function fmtBytes(n: number, d = 1): string {
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  let v = Math.max(0, n);
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i === 0 ? 0 : d)} ${u[i]}`;
}

/** bytes/วินาที -> แสดงเป็นบิต (Kbps / Mbps / Gbps) */
export function fmtBits(bytesPerSec: number): string {
  let v = Math.max(0, bytesPerSec) * 8;
  const u = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  let i = 0;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return `${v.toFixed(i === 0 ? 0 : v < 10 ? 2 : 1)} ${u[i]}`;
}

export function fmtUptime(s: number): string {
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  return d > 0 ? `${d} วัน ${h} ชม.` : h > 0 ? `${h} ชม. ${m} นาที` : `${m} นาที`;
}

export const fmtDate = (s: number) => new Date(s * 1000).toLocaleString('th-TH', { dateStyle: 'medium', timeStyle: 'short' });
export const daysLeft = (s: number) => Math.ceil((s * 1000 - Date.now()) / 86_400_000);
export const copy = async (t: string) => { try { await navigator.clipboard.writeText(t); } catch { /* ignore */ } };
