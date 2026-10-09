import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { Client } from 'ssh2';
import { decrypt, encrypt } from './crypto';

export type ServerRow = {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  secret_enc: string;
  host_fingerprint: string | null;
  created_at: string;
};
export type ServerPublic = Omit<ServerRow, 'secret_enc'>;

const PUBLIC_COLS = 'id,name,host,port,username,host_fingerprint,created_at';

export class SshError extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

let _db: SupabaseClient | null = null;
function db(): SupabaseClient {
  if (_db) return _db;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('ยังไม่ได้ตั้ง SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  _db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  return _db;
}

export async function listServers(): Promise<ServerPublic[]> {
  const { data, error } = await db().from('servers').select(PUBLIC_COLS).order('created_at');
  if (error) throw new Error(error.message);
  return (data ?? []) as ServerPublic[];
}

export async function getServer(id: string): Promise<ServerRow> {
  const { data, error } = await db().from('servers').select('*').eq('id', id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new SshError('NOT_FOUND', 'ไม่พบ VPS นี้');
  return data as ServerRow;
}

export async function createServer(i: { name: string; host: string; port: number; username: string; password: string }) {
  const { data, error } = await db()
    .from('servers')
    .insert({ name: i.name, host: i.host, port: i.port, username: i.username, secret_enc: encrypt(i.password) })
    .select(PUBLIC_COLS)
    .single();
  if (error) throw new Error(error.message);
  return data as ServerPublic;
}

export async function updateServer(
  id: string,
  p: { name?: string; host?: string; port?: number; username?: string; password?: string; resetFingerprint?: boolean },
) {
  const cur = await getServer(id);
  const patch: Record<string, unknown> = {};
  if (p.name !== undefined) patch.name = p.name;
  if (p.host !== undefined) patch.host = p.host;
  if (p.port !== undefined) patch.port = p.port;
  if (p.username !== undefined) patch.username = p.username;
  if (p.password) patch.secret_enc = encrypt(p.password);
  const moved = (p.host !== undefined && p.host !== cur.host) || (p.port !== undefined && p.port !== cur.port);
  if (p.resetFingerprint || moved) patch.host_fingerprint = null;
  const { data, error } = await db().from('servers').update(patch).eq('id', id).select(PUBLIC_COLS).single();
  if (error) throw new Error(error.message);
  return data as ServerPublic;
}

export async function deleteServer(id: string) {
  const { error } = await db().from('servers').delete().eq('id', id);
  if (error) throw new Error(error.message);
}

// ------------------------------------------------------------------ SSH
function friendly(e: Error): string {
  const m = e.message || String(e);
  if (/All configured authentication methods failed/i.test(m)) return 'ล็อกอิน SSH ไม่สำเร็จ - ตรวจชื่อผู้ใช้/รหัสผ่าน และดูว่า VPS เปิด PasswordAuthentication';
  if (/ENOTFOUND/.test(m)) return 'หาโฮสต์ไม่เจอ - ตรวจ IP/โดเมน';
  if (/ECONNREFUSED/.test(m)) return 'เชื่อมต่อไม่ได้ (พอร์ตปิด) - ตรวจพอร์ต SSH และไฟร์วอลล์';
  if (/ETIMEDOUT|Timed out while waiting for handshake/i.test(m)) return 'เชื่อมต่อหมดเวลา - ตรวจไฟร์วอลล์ (ต้องเปิดให้ IP ของ Vercel เข้าได้)';
  return m;
}

type SshResult = { code: number; stdout: string; stderr: string; fingerprint: string | null };

function runSsh(row: ServerRow, command: string, timeoutMs = 40_000): Promise<SshResult> {
  return new Promise((resolve, reject) => {
    const conn = new Client();
    let observed: string | null = null;
    let mismatch = false;
    let done = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const finish = (fn: () => void) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      try { conn.end(); } catch { /* ignore */ }
      fn();
    };
    timer = setTimeout(() => finish(() => reject(new SshError('TIMEOUT', 'คำสั่งใช้เวลานานเกินไป'))), timeoutMs);

    conn.on('ready', () => {
      conn.exec(command, (err, stream) => {
        if (err) return finish(() => reject(new SshError('EXEC', err.message)));
        let stdout = '';
        let stderr = '';
        stream.on('data', (d: Buffer) => { if (stdout.length < 200_000) stdout += d.toString('utf8'); });
        stream.stderr.on('data', (d: Buffer) => { if (stderr.length < 50_000) stderr += d.toString('utf8'); });
        stream.on('close', (code: number | null) =>
          finish(() => resolve({ code: code ?? 1, stdout, stderr, fingerprint: observed })),
        );
      });
    });
    conn.on('error', (e: Error) =>
      finish(() =>
        reject(
          mismatch
            ? new SshError('HOSTKEY', 'host key ของ VPS เปลี่ยนไป (ติดตั้งเครื่องใหม่ หรืออาจมีคนดักกลางทาง) - ถ้าแน่ใจว่าเปลี่ยนจริง กด "ยอมรับ host key ใหม่"')
            : new SshError('CONNECT', friendly(e)),
        ),
      ),
    );

    conn.connect({
      host: row.host,
      port: row.port,
      username: row.username,
      password: decrypt(row.secret_enc),
      readyTimeout: 12_000,
      hostHash: 'sha256',
      hostVerifier: (hash: string) => {
        observed = hash;
        if (row.host_fingerprint && row.host_fingerprint !== hash) {
          mismatch = true;
          return false;
        }
        return true;
      },
    });
  });
}

/** รันคำสั่งของ `m` บน VPS  (ถ้าไม่ใช่ root จะใช้ sudo -n) */
export async function execOnServer(id: string, build: (m: string) => string): Promise<SshResult> {
  const row = await getServer(id);
  const M = row.username === 'root' ? '/usr/local/bin/m' : 'sudo -n /usr/local/bin/m';
  const r = await runSsh(row, build(M));
  if (!row.host_fingerprint && r.fingerprint) {
    await db().from('servers').update({ host_fingerprint: r.fingerprint }).eq('id', id);
  }
  return r;
}
