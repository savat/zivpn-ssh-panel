import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

function key(): Buffer {
  const k = Buffer.from(process.env.ENCRYPTION_KEY || '', 'base64');
  if (k.length !== 32) throw new Error('ENCRYPTION_KEY ต้องเป็น 32 bytes (base64) - openssl rand -base64 32');
  return k;
}

export function encrypt(plain: string): string {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key(), iv);
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return ['v1', iv.toString('base64'), c.getAuthTag().toString('base64'), ct.toString('base64')].join(':');
}

export function decrypt(s: string): string {
  const [v, iv, tag, ct] = s.split(':');
  if (v !== 'v1' || !iv || !tag || !ct) throw new Error('ข้อมูลเข้ารหัสไม่ถูกต้อง');
  const d = createDecipheriv('aes-256-gcm', key(), Buffer.from(iv, 'base64'));
  d.setAuthTag(Buffer.from(tag, 'base64'));
  return Buffer.concat([d.update(Buffer.from(ct, 'base64')), d.final()]).toString('utf8');
}
