// ใช้ได้ทั้ง Edge (middleware) และ Node - ห้าม import node:crypto ที่นี่
import { SignJWT, jwtVerify } from 'jose';

export const COOKIE = 'zp_session';
export const MAX_AGE = 7 * 24 * 3600;

function secret(): Uint8Array {
  const s = process.env.SESSION_SECRET;
  if (!s || s.length < 32) throw new Error('SESSION_SECRET ต้องยาวอย่างน้อย 32 ตัวอักษร');
  return new TextEncoder().encode(s);
}

export async function createSession(): Promise<string> {
  return new SignJWT({ sub: 'admin' })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(`${MAX_AGE}s`)
    .sign(secret());
}

export async function verifySession(token?: string): Promise<boolean> {
  if (!token) return false;
  try {
    await jwtVerify(token, secret(), { algorithms: ['HS256'] });
    return true;
  } catch {
    return false;
  }
}
