// กฎเดียวกับ valid_user / valid_pass / valid_days ใน menu.sh
// ค่าทุกตัวที่จะส่งไปเป็นอาร์กิวเมนต์ของคำสั่งบน VPS ต้องผ่านตรงนี้ก่อนเสมอ
export const RE_USER = /^[A-Za-z0-9_-]{3,32}$/;
export const RE_PASS = /^[A-Za-z0-9@#%^*_+=.,:;!?~/-]{4,64}$/;
export const RE_HOST = /^[A-Za-z0-9.:-]{1,253}$/;
export const RE_SSHUSER = /^[A-Za-z_][A-Za-z0-9_-]{0,31}$/;
export const RE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseDays(v: unknown): number | null {
  const n = typeof v === 'string' ? Number(v) : typeof v === 'number' ? v : NaN;
  return Number.isInteger(n) && n >= 1 && n <= 3650 ? n : null;
}

export function parsePort(v: unknown): number | null {
  const n = typeof v === 'string' ? Number(v) : typeof v === 'number' ? v : NaN;
  return Number.isInteger(n) && n >= 1 && n <= 65535 ? n : null;
}

/** ครอบด้วย single quote ให้ปลอดภัยสำหรับ sh */
export function shq(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}
