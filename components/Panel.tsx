'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';

type Server = { id: string; name: string; host: string; port: number; username: string; host_fingerprint: string | null };
type User = { name: string; password: string; expires: number; state: 'active' | 'expired' | 'off' };
type Overview = { installed: boolean; status: Record<string, string>; users: User[] };
type Brief = { kind: 'loading' | 'ok' | 'down' | 'error' | 'missing'; text: string };
type ApiErr = Error & { code?: string };

async function api<T = any>(url: string, method = 'GET', body?: unknown): Promise<T> {
  const r = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (r.status === 401) {
    window.location.href = '/login';
    throw new Error('หมดเวลาเข้าสู่ระบบ');
  }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(j.error || r.statusText), { code: j.code }) as ApiErr;
  return j as T;
}

const fmtDate = (s: number) => new Date(s * 1000).toLocaleString('th-TH', { dateStyle: 'medium', timeStyle: 'short' });
const daysLeft = (s: number) => Math.ceil((s * 1000 - Date.now()) / 86_400_000);
const copy = async (t: string) => { try { await navigator.clipboard.writeText(t); } catch { /* ignore */ } };

type Modal =
  | { k: 'server'; edit?: Server }
  | { k: 'user'; kind: 'add' | 'renew' | 'passwd'; user?: string }
  | null;

export default function Panel() {
  const [servers, setServers] = useState<Server[]>([]);
  const [sel, setSel] = useState<string | null>(null);
  const [ov, setOv] = useState<Overview | null>(null);
  const [ovErr, setOvErr] = useState<ApiErr | null>(null);
  const [loading, setLoading] = useState(false);
  const [brief, setBrief] = useState<Record<string, Brief>>({});
  const [out, setOut] = useState('');
  const [busy, setBusy] = useState('');
  const [modal, setModal] = useState<Modal>(null);
  const [q, setQ] = useState('');
  const [show, setShow] = useState<Record<string, boolean>>({});

  const server = servers.find((s) => s.id === sel) ?? null;

  const loadServers = useCallback(async () => {
    const j = await api<{ servers: Server[] }>('/api/servers');
    setServers(j.servers);
    return j.servers;
  }, []);

  const loadOverview = useCallback(async (id: string) => {
    setLoading(true);
    setOvErr(null);
    setBrief((b) => ({ ...b, [id]: { kind: 'loading', text: '…' } }));
    try {
      const j = await api<Overview>(`/api/servers/${id}/overview`);
      setOv(j);
      setBrief((b) => ({
        ...b,
        [id]: !j.installed
          ? { kind: 'missing', text: 'ยังไม่ติดตั้ง ZIVPN' }
          : j.status.service === '1'
            ? { kind: 'ok', text: `${j.status.active}/${j.status.total} ผู้ใช้` }
            : { kind: 'down', text: 'ZIVPN หยุดทำงาน' },
      }));
    } catch (e) {
      setOv(null);
      setOvErr(e as ApiErr);
      setBrief((b) => ({ ...b, [id]: { kind: 'error', text: 'เชื่อมต่อไม่ได้' } }));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { loadServers().catch((e) => setOut(String(e.message))); }, [loadServers]);

  function pick(id: string) {
    setSel(id);
    setOv(null);
    setOut('');
    setQ('');
    setShow({});
    loadOverview(id);
  }

  async function checkAll() {
    await Promise.all(
      servers.map(async (s) => {
        setBrief((b) => ({ ...b, [s.id]: { kind: 'loading', text: '…' } }));
        try {
          const j = await api<Overview>(`/api/servers/${s.id}/overview`);
          setBrief((b) => ({
            ...b,
            [s.id]: !j.installed
              ? { kind: 'missing', text: 'ยังไม่ติดตั้ง ZIVPN' }
              : j.status.service === '1'
                ? { kind: 'ok', text: `${j.status.active}/${j.status.total} ผู้ใช้` }
                : { kind: 'down', text: 'ZIVPN หยุดทำงาน' },
          }));
        } catch {
          setBrief((b) => ({ ...b, [s.id]: { kind: 'error', text: 'เชื่อมต่อไม่ได้' } }));
        }
      }),
    );
  }

  async function act(action: string, extra: Record<string, unknown> = {}, label = action) {
    if (!sel) return;
    setBusy(label);
    setOut('');
    try {
      const j = await api<{ ok: boolean; output: string }>(`/api/servers/${sel}/action`, 'POST', { action, ...extra });
      setOut(`${j.ok ? '✔' : '✘'} ${j.output || (j.ok ? 'สำเร็จ' : 'ล้มเหลว')}`);
    } catch (e) {
      setOut(`✘ ${(e as Error).message}`);
    }
    setBusy('');
    await loadOverview(sel);
  }

  async function removeServer(s: Server) {
    if (!confirm(`ลบ VPS "${s.name}" ออกจากเว็บ?\n(ไม่กระทบเครื่องจริงและผู้ใช้บน VPS)`)) return;
    await api(`/api/servers/${s.id}`, 'DELETE');
    setSel(null);
    setOv(null);
    await loadServers();
  }

  async function acceptNewHostKey() {
    if (!sel) return;
    await api(`/api/servers/${sel}`, 'PATCH', { resetFingerprint: true });
    await loadServers();
    await loadOverview(sel);
  }

  async function logout() {
    await api('/api/auth/logout', 'POST');
    window.location.href = '/login';
  }

  const users = useMemo(() => {
    const t = q.trim().toLowerCase();
    return (ov?.users ?? []).filter((u) => !t || u.name.toLowerCase().includes(t));
  }, [ov, q]);

  function info(u: User) {
    const s = ov?.status ?? {};
    const host = s.host || server?.host || '';
    const lines = [`User: ${u.name}`, `Server: ${host}`, `Password: ${u.password}`, `Obfs: ${s.obfs ?? ''}`, `Port: ${s.port ?? ''}`];
    if (s.range) lines.push(`Port range: ${s.range.replace(':', '-')}`);
    lines.push(`Expires: ${fmtDate(u.expires)}`);
    return lines.join('\n');
  }

  const stateBadge = (u: User) =>
    u.state === 'active' ? <span className="badge b-ok">ใช้งาน · เหลือ {daysLeft(u.expires)} วัน</span>
    : u.state === 'expired' ? <span className="badge b-bad">หมดอายุ</span>
    : <span className="badge b-warn">ปิดอยู่</span>;

  const briefBadge = (id: string) => {
    const b = brief[id];
    if (!b) return <span className="badge muted">ยังไม่ตรวจ</span>;
    const c = b.kind === 'ok' ? 'b-ok' : b.kind === 'loading' ? '' : b.kind === 'missing' ? 'b-warn' : 'b-bad';
    return <span className={`badge ${c}`}>{b.kind === 'ok' ? '● ' : ''}{b.text}</span>;
  };

  return (
    <div className="wrap">
      <div className="top">
        <h1>ZIVPN Hub</h1>
        <div className="row">
          <button onClick={checkAll} disabled={!servers.length}>เช็กทุกเครื่อง</button>
          <button onClick={logout}>ออก</button>
        </div>
      </div>

      <div className="card">
        <div className="top" style={{ marginBottom: 10 }}>
          <h2>VPS ของฉัน ({servers.length})</h2>
          <button className="primary" onClick={() => setModal({ k: 'server' })}>+ เพิ่ม VPS</button>
        </div>
        {servers.length === 0 && <div className="muted">ยังไม่มี VPS - กด “เพิ่ม VPS” แล้วใส่ IP, ชื่อ และรหัส SSH</div>}
        <div className="servers">
          {servers.map((s) => (
            <button key={s.id} className={`srv ${s.id === sel ? 'sel' : ''}`} onClick={() => pick(s.id)}>
              <b>{s.name}</b>
              <span className="muted mono" style={{ fontSize: 12 }}>{s.username}@{s.host}:{s.port}</span>
              <span>{briefBadge(s.id)}</span>
            </button>
          ))}
        </div>
      </div>

      {server && (
        <div className="card" style={{ display: 'grid', gap: 12 }}>
          <div className="top">
            <h2>{server.name}</h2>
            <div className="row">
              <button onClick={() => loadOverview(server.id)} disabled={loading}>{loading ? 'กำลังโหลด…' : 'รีเฟรช'}</button>
              <button onClick={() => setModal({ k: 'server', edit: server })}>แก้ไข</button>
              <button className="danger" onClick={() => removeServer(server)}>ลบ</button>
            </div>
          </div>

          {ovErr && (
            <div>
              <div className="err">{ovErr.message}</div>
              {ovErr.code === 'HOSTKEY' && <button onClick={acceptNewHostKey}>ยอมรับ host key ใหม่</button>}
            </div>
          )}

          {ov && !ov.installed && (
            <div className="err">
              VPS นี้ยังไม่มีตัวจัดการ <span className="mono">m</span> - ติดตั้งก่อนด้วย <span className="mono">sh install.sh</span> (ต้องมี menu.sh v1.1.0 ขึ้นไป)
            </div>
          )}

          {ov?.installed && (
            <>
              <div className="stats">
                <div className="stat"><small>บริการ</small>{ov.status.service === '1' ? <span style={{ color: 'var(--green)' }}>● RUNNING</span> : <span style={{ color: 'var(--red)' }}>● STOPPED</span>}</div>
                <div className="stat"><small>ผู้ใช้ (ใช้งาน/ทั้งหมด)</small>{ov.status.active}/{ov.status.total}</div>
                <div className="stat"><small>Server</small><span className="mono">{ov.status.host}</span></div>
                <div className="stat"><small>Port</small>{ov.status.port}/udp{ov.status.range ? ` + ${ov.status.range}` : ''}</div>
                <div className="stat"><small>m version</small>{ov.status.version}</div>
              </div>

              <div className="row">
                <button disabled={!!busy} onClick={() => act('restart', {}, 'รีสตาร์ท')}>รีสตาร์ท ZIVPN</button>
                <button disabled={!!busy} onClick={() => act('health', {}, 'ตรวจสุขภาพ')}>ตรวจสุขภาพ</button>
                <button disabled={!!busy} onClick={() => act('backup', {}, 'สำรองข้อมูล')}>สำรองข้อมูล</button>
                {busy && <span className="muted">กำลังทำ: {busy}…</span>}
              </div>

              <div className="top">
                <h2>ผู้ใช้ ({ov.users.length})</h2>
                <button className="primary" onClick={() => setModal({ k: 'user', kind: 'add' })}>+ เพิ่มผู้ใช้</button>
              </div>
              {ov.users.length > 5 && <input placeholder="ค้นหาผู้ใช้…" value={q} onChange={(e) => setQ(e.target.value)} />}

              <div className="users">
                {users.length === 0 && <div className="muted">{ov.users.length ? 'ไม่พบผู้ใช้ที่ค้นหา' : 'ยังไม่มีผู้ใช้'}</div>}
                {users.map((u) => (
                  <div key={u.name} className="user">
                    <div className="head">
                      <b>{u.name}</b>
                      {stateBadge(u)}
                    </div>
                    <div className="row muted" style={{ fontSize: 13 }}>
                      <span className="mono" onClick={() => setShow((s) => ({ ...s, [u.name]: !s[u.name] }))} style={{ cursor: 'pointer' }}>
                        รหัส: {show[u.name] ? u.password : '••••••••'} {show[u.name] ? '' : '(แตะเพื่อดู)'}
                      </span>
                      <span>· หมดอายุ {fmtDate(u.expires)}</span>
                    </div>
                    <div className="btns">
                      <button disabled={!!busy} onClick={() => setModal({ k: 'user', kind: 'renew', user: u.name })}>ต่ออายุ</button>
                      <button disabled={!!busy} onClick={() => setModal({ k: 'user', kind: 'passwd', user: u.name })}>เปลี่ยนรหัส</button>
                      {u.state === 'off'
                        ? <button disabled={!!busy} onClick={() => act('on', { user: u.name })}>เปิด</button>
                        : u.state === 'active' && <button disabled={!!busy} onClick={() => act('off', { user: u.name })}>ปิด</button>}
                      <button onClick={() => { copy(info(u)); setOut(`คัดลอกข้อมูลเชื่อมต่อของ ${u.name} แล้ว\n\n${info(u)}`); }}>คัดลอกข้อมูล</button>
                      <button className="danger" disabled={!!busy} onClick={() => confirm(`ลบผู้ใช้ "${u.name}" ?`) && act('del', { user: u.name })}>ลบ</button>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}

          {out && <pre className="out">{out}</pre>}
        </div>
      )}

      {modal?.k === 'server' && (
        <ServerModal
          edit={modal.edit}
          onClose={() => setModal(null)}
          onSaved={async (id) => { setModal(null); await loadServers(); pick(id); }}
        />
      )}
      {modal?.k === 'user' && (
        <UserModal
          kind={modal.kind}
          user={modal.user}
          onClose={() => setModal(null)}
          onSubmit={async (v) => {
            setModal(null);
            await act(modal.kind, v, { add: 'เพิ่มผู้ใช้', renew: 'ต่ออายุ', passwd: 'เปลี่ยนรหัส' }[modal.kind]);
          }}
        />
      )}
    </div>
  );
}

function ServerModal({ edit, onClose, onSaved }: { edit?: Server; onClose: () => void; onSaved: (id: string) => void }) {
  const [f, setF] = useState({
    name: edit?.name ?? '', host: edit?.host ?? '', port: String(edit?.port ?? 22),
    username: edit?.username ?? 'root', password: '',
  });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });

  async function save() {
    setBusy(true);
    setErr('');
    try {
      const j = edit
        ? await api<{ server: Server }>(`/api/servers/${edit.id}`, 'PATCH', f)
        : await api<{ server: Server }>('/api/servers', 'POST', f);
      onSaved(j.server.id);
    } catch (e) {
      setErr((e as Error).message);
      setBusy(false);
    }
  }

  return (
    <div className="modal" onClick={onClose}>
      <div className="card" onClick={(e) => e.stopPropagation()}>
        <h2>{edit ? 'แก้ไข VPS' : 'เพิ่ม VPS'}</h2>
        <div className="grid2">
          <label className="full">ชื่อ<input value={f.name} onChange={set('name')} placeholder="เช่น SG-01" /></label>
          <label className="full">IP / โดเมน<input value={f.host} onChange={set('host')} placeholder="203.0.113.10" inputMode="url" autoCapitalize="none" /></label>
          <label>พอร์ต SSH<input value={f.port} onChange={set('port')} inputMode="numeric" /></label>
          <label>ผู้ใช้ SSH<input value={f.username} onChange={set('username')} autoCapitalize="none" /></label>
          <label className="full">รหัสผ่าน SSH{edit && ' (เว้นว่าง = ใช้รหัสเดิม)'}<input type="password" value={f.password} onChange={set('password')} autoComplete="new-password" /></label>
        </div>
        {err && <div className="err">{err}</div>}
        <div className="row" style={{ justifyContent: 'flex-end' }}>
          <button onClick={onClose}>ยกเลิก</button>
          <button className="primary" disabled={busy || !f.name || !f.host || (!edit && !f.password)} onClick={save}>{busy ? 'กำลังบันทึก…' : 'บันทึก'}</button>
        </div>
      </div>
    </div>
  );
}

function UserModal({ kind, user, onClose, onSubmit }: {
  kind: 'add' | 'renew' | 'passwd'; user?: string; onClose: () => void; onSubmit: (v: Record<string, unknown>) => void;
}) {
  const [name, setName] = useState(user ?? '');
  const [password, setPassword] = useState('');
  const [days, setDays] = useState('30');
  const title = kind === 'add' ? 'เพิ่มผู้ใช้' : kind === 'renew' ? `ต่ออายุ ${user}` : `เปลี่ยนรหัสผ่าน ${user}`;
  return (
    <div className="modal" onClick={onClose}>
      <div className="card" onClick={(e) => e.stopPropagation()}>
        <h2>{title}</h2>
        {kind === 'add' && <label>ชื่อผู้ใช้ (3-32 ตัว: a-z A-Z 0-9 _ -)<input value={name} onChange={(e) => setName(e.target.value)} autoCapitalize="none" /></label>}
        {kind !== 'renew' && <label>รหัสผ่าน (เว้นว่าง = สุ่มให้)<input value={password} onChange={(e) => setPassword(e.target.value)} autoCapitalize="none" /></label>}
        {kind !== 'passwd' && <label>จำนวนวัน<input value={days} onChange={(e) => setDays(e.target.value)} inputMode="numeric" /></label>}
        <div className="row" style={{ justifyContent: 'flex-end' }}>
          <button onClick={onClose}>ยกเลิก</button>
          <button
            className="primary"
            disabled={kind === 'add' && !name}
            onClick={() => onSubmit({ user: name, ...(kind !== 'renew' ? { password } : {}), ...(kind !== 'passwd' ? { days } : {}) })}
          >
            ยืนยัน
          </button>
        </div>
      </div>
    </div>
  );
}
