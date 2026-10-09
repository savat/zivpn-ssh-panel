'use client';
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { api, clamp, fmtBytes, fmtUptime, type ApiErr, type Metrics, type Server } from '@/lib/client';
import { Num, Rate, Ring, Spark } from '@/components/ui';
import ServerModal from '@/components/ServerModal';

const HIST = 40;

type Live = {
  status: 'loading' | 'ok' | 'error';
  err?: string;
  code?: string;
  m?: Metrics;
  cpu?: number;
  ram?: number;
  disk?: number;
  rx: number;
  tx: number;
  hRx: number[];
  hTx: number[];
};

const blank = (): Live => ({ status: 'loading', rx: 0, tx: 0, hRx: [], hTx: [] });
const push = (a: number[], v: number) => [...a, v].slice(-HIST);

function step(prev: Live | undefined, m: Metrics): Live {
  const b = prev ?? blank();
  const p = b.m;
  let { cpu, rx, tx, hRx, hTx } = b;
  if (p) {
    const dt = m.up - p.up;
    const dTot = m.cpu.total - p.cpu.total;
    if (dt > 0 && dTot > 0) {
      cpu = clamp(((m.cpu.busy - p.cpu.busy) / dTot) * 100);
      rx = Math.max(0, (m.net.rx - p.net.rx) / dt);
      tx = Math.max(0, (m.net.tx - p.net.tx) / dt);
      hRx = push(hRx, rx);
      hTx = push(hTx, tx);
    }
  }
  const ram = m.mem.total > 0 ? clamp((1 - m.mem.avail / m.mem.total) * 100) : 0;
  const dsum = m.disk.used + m.disk.avail;
  const disk = dsum > 0 ? clamp((m.disk.used / dsum) * 100) : 0;
  return { ...b, status: 'ok', err: undefined, code: undefined, m, cpu, ram, disk, rx, tx, hRx, hTx };
}

export default function Dashboard() {
  const [servers, setServers] = useState<Server[] | null>(null);
  const [live, setLive] = useState<Record<string, Live>>({});
  const [modal, setModal] = useState<{ edit?: Server } | null>(null);
  const [nonce, setNonce] = useState(0); // เปลี่ยนเพื่อให้ลูป polling เริ่มใหม่

  async function loadServers() {
    const j = await api<{ servers: Server[] }>('/api/servers');
    setServers(j.servers);
  }
  useEffect(() => { loadServers().catch(() => setServers([])); }, []);

  const key = useMemo(() => (servers ?? []).map((s) => s.id).join(',') + `#${nonce}`, [servers, nonce]);

  // ---- realtime polling (หยุดเองเมื่อแท็บถูกซ่อน)
  useEffect(() => {
    const list = servers ?? [];
    if (!list.length) return;
    let dead = false;
    const timers: Record<string, ReturnType<typeof setTimeout>> = {};
    const every = list.length <= 2 ? 3000 : list.length <= 5 ? 5000 : 8000;

    const tick = async (id: string) => {
      if (dead) return;
      if (document.hidden) { timers[id] = setTimeout(() => tick(id), 1500); return; }
      let next = every;
      try {
        const m = await api<Metrics>(`/api/servers/${id}/metrics`);
        if (dead) return;
        setLive((l) => ({ ...l, [id]: step(l[id], m) }));
      } catch (e) {
        if (dead) return;
        const er = e as ApiErr;
        setLive((l) => ({ ...l, [id]: { ...(l[id] ?? blank()), status: 'error', err: er.message, code: er.code } }));
        next = 10_000;
      }
      if (!dead) timers[id] = setTimeout(() => tick(id), next);
    };
    list.forEach((s, i) => { timers[s.id] = setTimeout(() => tick(s.id), i * 350); });
    return () => { dead = true; Object.values(timers).forEach(clearTimeout); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  async function acceptHostKey(id: string) {
    await api(`/api/servers/${id}`, 'PATCH', { resetFingerprint: true });
    await loadServers();
    setNonce((n) => n + 1);
  }

  const all = Object.entries(live).filter(([id]) => servers?.some((s) => s.id === id));
  const okList = all.filter(([, l]) => l.status === 'ok');
  const sumRx = okList.reduce((a, [, l]) => a + l.rx, 0);
  const sumTx = okList.reduce((a, [, l]) => a + l.tx, 0);
  const users = okList.reduce((a, [, l]) => a + (l.m?.zivpn.active ?? 0), 0);
  const usersAll = okList.reduce((a, [, l]) => a + (l.m?.zivpn.total ?? 0), 0);

  return (
    <main className="wrap">
      <section className="hero rise">
        <div>
          <h1>แดชบอร์ด</h1>
          <p className="muted"><span className="livedot" /> อัปเดตแบบเรียลไทม์ · {servers?.length ?? 0} เครื่อง</p>
        </div>
        <button className="primary" onClick={() => setModal({})}>+ เพิ่ม VPS</button>
      </section>

      {servers && servers.length > 0 && (
        <section className="totals">
          <div className="tot rise" style={{ '--d': '40ms' } as React.CSSProperties}>
            <small>ออนไลน์</small><b><Num value={okList.length} />/{servers.length}</b>
          </div>
          <div className="tot rise" style={{ '--d': '100ms' } as React.CSSProperties}>
            <small>ผู้ใช้ที่ใช้งานได้</small><b><Num value={users} />/{usersAll}</b>
          </div>
          <div className="tot down rise" style={{ '--d': '160ms' } as React.CSSProperties}>
            <small>↓ รวมตอนนี้</small><b><Rate bytesPerSec={sumRx} /></b>
          </div>
          <div className="tot up rise" style={{ '--d': '220ms' } as React.CSSProperties}>
            <small>↑ รวมตอนนี้</small><b><Rate bytesPerSec={sumTx} /></b>
          </div>
        </section>
      )}

      {servers === null && <div className="skeleton tall" />}
      {servers && servers.length === 0 && (
        <div className="card empty rise">
          <h2>ยังไม่มี VPS</h2>
          <p className="muted">กด “+ เพิ่ม VPS” แล้วใส่ชื่อ, IP และรหัส SSH ของเครื่อง</p>
        </div>
      )}

      <section className="cards">
        {(servers ?? []).map((s, i) => (
          <ServerCard
            key={s.id}
            s={s}
            l={live[s.id]}
            i={i}
            onEdit={() => setModal({ edit: s })}
            onAccept={() => acceptHostKey(s.id)}
          />
        ))}
      </section>

      {modal && (
        <ServerModal
          edit={modal.edit}
          onClose={() => setModal(null)}
          onSaved={async () => { setModal(null); await loadServers(); setNonce((n) => n + 1); }}
          onDeleted={async () => { setModal(null); await loadServers(); }}
        />
      )}
    </main>
  );
}

function ServerCard({ s, l, i, onEdit, onAccept }: { s: Server; l?: Live; i: number; onEdit: () => void; onAccept: () => void }) {
  const m = l?.m;
  const ok = l?.status === 'ok' && !!m;
  const err = l?.status === 'error';
  const led = err ? 'bad' : ok ? 'ok' : 'wait';
  const z = m?.zivpn;

  return (
    <article className={`srvcard rise ${err ? 'is-err' : ''}`} style={{ '--d': `${i * 80}ms` } as React.CSSProperties}>
      <header className="sc-head">
        <div className="sc-title">
          <span className={`led ${led}`} />
          <div>
            <b>{s.name}</b>
            <small className="mono">{s.host}</small>
          </div>
        </div>
        {ok && z && (
          z.installed
            ? <span className={`badge ${z.service ? 'b-ok' : 'b-bad'}`}>{z.service ? '● ZIVPN' : '● หยุด'} · {z.active}/{z.total}</span>
            : <span className="badge b-warn">ยังไม่ติดตั้ง ZIVPN</span>
        )}
      </header>

      {err && (
        <div className="errbox">
          <div>{l?.err}</div>
          {l?.code === 'HOSTKEY' && <button onClick={onAccept}>ยอมรับ host key ใหม่</button>}
        </div>
      )}

      {!ok && !err && <div className="skeleton" />}

      {ok && m && (
        <>
          <div className="rings">
            <Ring pct={l?.cpu} label="CPU" sub={`${m.cores} คอร์ · load ${m.load[0]?.toFixed(2) ?? '-'}`} />
            <Ring pct={l?.ram} label="RAM" sub={`${fmtBytes((m.mem.total - m.mem.avail) * 1024)} / ${fmtBytes(m.mem.total * 1024)}`} />
            <Ring pct={l?.disk} label="DISK" sub={`${fmtBytes(m.disk.used * 1024)} / ${fmtBytes((m.disk.used + m.disk.avail) * 1024)}`} />
          </div>

          <div className="net">
            <div className="netcol down">
              <small>↓ ดาวน์โหลด</small>
              <b><Rate bytesPerSec={l?.rx ?? 0} /></b>
              <small className="muted">รวม {fmtBytes(m.net.rx)}</small>
            </div>
            <div className="netcol up">
              <small>↑ อัปโหลด</small>
              <b><Rate bytesPerSec={l?.tx ?? 0} /></b>
              <small className="muted">รวม {fmtBytes(m.net.tx)}</small>
            </div>
          </div>
          <Spark series={[{ vals: l?.hRx ?? [], color: '#38d0f0' }, { vals: l?.hTx ?? [], color: '#a78bfa' }]} points={HIST} />

          <footer className="sc-foot">
            <span className="muted">⏱ {fmtUptime(m.up)}{m.os ? ` · ${m.os}` : ''}</span>
            <span className="row">
              <Link href={`/users?s=${s.id}`} className="btnlink">ผู้ใช้</Link>
              <button onClick={onEdit}>แก้ไข</button>
            </span>
          </footer>
        </>
      )}

      {!ok && (
        <footer className="sc-foot">
          <span className="muted mono">{s.username}@{s.host}:{s.port}</span>
          <button onClick={onEdit}>แก้ไข</button>
        </footer>
      )}
    </article>
  );
}
