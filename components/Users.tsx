'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { api, copy, daysLeft, fmtDate, type ApiErr, type Overview, type Server, type User } from '@/lib/client';
import ServerModal from '@/components/ServerModal';

type Modal = { k: 'user'; kind: 'add' | 'renew' | 'passwd'; user?: string } | { k: 'server' } | null;

export default function Users() {
  const [servers, setServers] = useState<Server[] | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  const [ov, setOv] = useState<Overview | null>(null);
  const [ovErr, setOvErr] = useState<ApiErr | null>(null);
  const [loading, setLoading] = useState(false);
  const [out, setOut] = useState('');
  const [busy, setBusy] = useState('');
  const [modal, setModal] = useState<Modal>(null);
  const [q, setQ] = useState('');
  const [show, setShow] = useState<Record<string, boolean>>({});
  const [filter, setFilter] = useState<'all' | 'active' | 'soon' | 'bad'>('all');

  const loadOverview = useCallback(async (id: string) => {
    setLoading(true);
    setOvErr(null);
    try {
      setOv(await api<Overview>(`/api/servers/${id}/overview`));
    } catch (e) {
      setOv(null);
      setOvErr(e as ApiErr);
    } finally {
      setLoading(false);
    }
  }, []);

  const choose = useCallback((id: string) => {
    setSel(id);
    setOv(null);
    setOut('');
    setQ('');
    setShow({});
    setFilter('all');
    try { history.replaceState(null, '', `/users?s=${id}`); localStorage.setItem('zp_sel', id); } catch { /* ignore */ }
    loadOverview(id);
  }, [loadOverview]);

  useEffect(() => {
    api<{ servers: Server[] }>('/api/servers')
      .then((j) => {
        setServers(j.servers);
        let want: string | null = new URLSearchParams(window.location.search).get('s');
        if (!want) { try { want = localStorage.getItem('zp_sel'); } catch { /* ignore */ } }
        const pick = j.servers.find((x) => x.id === want) ?? j.servers[0];
        if (pick) choose(pick.id);
      })
      .catch(() => setServers([]));
  }, [choose]);

  const server = servers?.find((s) => s.id === sel) ?? null;

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

  async function acceptHostKey() {
    if (!sel) return;
    await api(`/api/servers/${sel}`, 'PATCH', { resetFingerprint: true });
    await loadOverview(sel);
  }

  const counts = useMemo(() => {
    const us = ov?.users ?? [];
    return {
      all: us.length,
      active: us.filter((u) => u.state === 'active').length,
      soon: us.filter((u) => u.state === 'active' && daysLeft(u.expires) <= 3).length,
      bad: us.filter((u) => u.state !== 'active').length,
    };
  }, [ov]);

  const users = useMemo(() => {
    const t = q.trim().toLowerCase();
    return (ov?.users ?? []).filter((u) => {
      if (t && !u.name.toLowerCase().includes(t)) return false;
      if (filter === 'active') return u.state === 'active';
      if (filter === 'soon') return u.state === 'active' && daysLeft(u.expires) <= 3;
      if (filter === 'bad') return u.state !== 'active';
      return true;
    });
  }, [ov, q, filter]);

  function info(u: User) {
    const s = ov?.status ?? {};
    const lines = [`User: ${u.name}`, `Server: ${s.host || server?.host || ''}`, `Password: ${u.password}`, `Obfs: ${s.obfs ?? ''}`, `Port: ${s.port ?? ''}`];
    if (s.range) lines.push(`Port range: ${s.range.replace(':', '-')}`);
    lines.push(`Expires: ${fmtDate(u.expires)}`);
    return lines.join('\n');
  }

  const stateBadge = (u: User) =>
    u.state === 'active' ? <span className="badge b-ok">ใช้งาน · เหลือ {daysLeft(u.expires)} วัน</span>
    : u.state === 'expired' ? <span className="badge b-bad">หมดอายุ</span>
    : <span className="badge b-warn">ปิดอยู่</span>;

  return (
    <main className="wrap">
      <section className="hero rise">
        <div>
          <h1>ผู้ใช้</h1>
          <p className="muted">เพิ่ม ต่ออายุ และจัดการบัญชีของแต่ละเครื่อง</p>
        </div>
      </section>

      {servers === null && <div className="skeleton tall" />}
      {servers && servers.length === 0 && (
        <div className="card empty rise">
          <h2>ยังไม่มี VPS</h2>
          <p className="muted">เพิ่ม VPS ก่อน แล้วค่อยกลับมาจัดการผู้ใช้</p>
          <button className="primary" onClick={() => setModal({ k: 'server' })}>+ เพิ่ม VPS</button>
        </div>
      )}

      {servers && servers.length > 0 && (
        <div className="chips rise">
          {servers.map((s) => (
            <button key={s.id} className={`chip ${s.id === sel ? 'on' : ''}`} onClick={() => choose(s.id)}>{s.name}</button>
          ))}
        </div>
      )}

      {ovErr && (
        <div className="card errbox">
          <div>{ovErr.message}</div>
          {ovErr.code === 'HOSTKEY' && <button onClick={acceptHostKey}>ยอมรับ host key ใหม่</button>}
        </div>
      )}

      {loading && !ov && <div className="skeleton tall" />}

      {ov && !ov.installed && (
        <div className="card errbox">
          VPS นี้ยังไม่มีตัวจัดการ <span className="mono">m</span> - ติดตั้งก่อนด้วย <span className="mono">sh install.sh</span> (ต้องมี menu.sh v1.1.0 ขึ้นไป)
        </div>
      )}

      {ov?.installed && server && (
        <>
          <section className="totals">
            <div className="tot rise"><small>บริการ</small><b style={{ color: ov.status.service === '1' ? 'var(--green)' : 'var(--red)' }}>{ov.status.service === '1' ? '● RUNNING' : '● STOPPED'}</b></div>
            <div className="tot rise" style={{ '--d': '60ms' } as React.CSSProperties}><small>ผู้ใช้ (ใช้งาน/ทั้งหมด)</small><b>{ov.status.active}/{ov.status.total}</b></div>
            <div className="tot rise" style={{ '--d': '120ms' } as React.CSSProperties}><small>พอร์ต</small><b>{ov.status.port}{ov.status.range ? ` +${ov.status.range}` : ''}</b></div>
            <div className="tot rise" style={{ '--d': '180ms' } as React.CSSProperties}><small>เซิร์ฟเวอร์</small><b className="mono sm">{ov.status.host}</b></div>
          </section>

          <section className="card rise">
            <div className="row" style={{ justifyContent: 'space-between' }}>
              <div className="row">
                <button disabled={!!busy} onClick={() => act('restart', {}, 'รีสตาร์ท')}>รีสตาร์ท</button>
                <button disabled={!!busy} onClick={() => act('health', {}, 'ตรวจสุขภาพ')}>ตรวจสุขภาพ</button>
                <button disabled={!!busy} onClick={() => act('backup', {}, 'สำรองข้อมูล')}>สำรองข้อมูล</button>
                <button disabled={loading} onClick={() => sel && loadOverview(sel)}>{loading ? 'กำลังโหลด…' : 'รีเฟรช'}</button>
              </div>
              <button className="primary" onClick={() => setModal({ k: 'user', kind: 'add' })}>+ เพิ่มผู้ใช้</button>
            </div>
            {busy && <div className="muted" style={{ marginTop: 8 }}><span className="livedot" /> กำลังทำ: {busy}…</div>}
            {out && <pre className="out">{out}</pre>}
          </section>

          <section className="card rise">
            <div className="row" style={{ marginBottom: 10 }}>
              <div className="chips grow">
                {([['all', 'ทั้งหมด'], ['active', 'ใช้งาน'], ['soon', 'ใกล้หมด ≤3 วัน'], ['bad', 'ปิด/หมดอายุ']] as const).map(([k, t]) => (
                  <button key={k} className={`chip ${filter === k ? 'on' : ''}`} onClick={() => setFilter(k)}>{t} <em>{counts[k]}</em></button>
                ))}
              </div>
            </div>
            {ov.users.length > 5 && <input placeholder="ค้นหาผู้ใช้…" value={q} onChange={(e) => setQ(e.target.value)} style={{ marginBottom: 10 }} />}

            <div className="users">
              {users.length === 0 && <div className="muted">{ov.users.length ? 'ไม่พบผู้ใช้ตามเงื่อนไข' : 'ยังไม่มีผู้ใช้'}</div>}
              {users.map((u, i) => (
                <div key={u.name} className="user rise" style={{ '--d': `${Math.min(i, 12) * 35}ms` } as React.CSSProperties}>
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
          </section>
        </>
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
      {modal?.k === 'server' && (
        <ServerModal
          onClose={() => setModal(null)}
          onSaved={async (id) => {
            setModal(null);
            const j = await api<{ servers: Server[] }>('/api/servers');
            setServers(j.servers);
            choose(id);
          }}
        />
      )}
    </main>
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
      <div className="card pop" onClick={(e) => e.stopPropagation()}>
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
