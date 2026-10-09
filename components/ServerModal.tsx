'use client';
import { useState } from 'react';
import { api, type Server } from '@/lib/client';

export default function ServerModal({ edit, onClose, onSaved, onDeleted }: {
  edit?: Server;
  onClose: () => void;
  onSaved: (id: string) => void;
  onDeleted?: () => void;
}) {
  const [f, setF] = useState({
    name: edit?.name ?? '',
    host: edit?.host ?? '',
    port: String(edit?.port ?? 22),
    username: edit?.username ?? 'root',
    password: '',
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

  async function remove() {
    if (!edit || !confirm(`ลบ VPS "${edit.name}" ออกจากเว็บ?\n(ไม่กระทบเครื่องจริงและผู้ใช้บน VPS)`)) return;
    setBusy(true);
    try {
      await api(`/api/servers/${edit.id}`, 'DELETE');
      onDeleted?.();
    } catch (e) {
      setErr((e as Error).message);
      setBusy(false);
    }
  }

  return (
    <div className="modal" onClick={onClose}>
      <div className="card pop" onClick={(e) => e.stopPropagation()}>
        <h2>{edit ? 'แก้ไข VPS' : 'เพิ่ม VPS'}</h2>
        <div className="grid2">
          <label className="full">ชื่อ<input value={f.name} onChange={set('name')} placeholder="เช่น SG-01" /></label>
          <label className="full">IP / โดเมน<input value={f.host} onChange={set('host')} placeholder="203.0.113.10" inputMode="url" autoCapitalize="none" /></label>
          <label>พอร์ต SSH<input value={f.port} onChange={set('port')} inputMode="numeric" /></label>
          <label>ผู้ใช้ SSH<input value={f.username} onChange={set('username')} autoCapitalize="none" /></label>
          <label className="full">รหัสผ่าน SSH{edit && ' (เว้นว่าง = ใช้รหัสเดิม)'}<input type="password" value={f.password} onChange={set('password')} autoComplete="new-password" /></label>
        </div>
        {err && <div className="err">{err}</div>}
        <div className="row" style={{ justifyContent: 'space-between' }}>
          {edit ? <button className="danger" disabled={busy} onClick={remove}>ลบ VPS</button> : <span />}
          <div className="row">
            <button onClick={onClose}>ยกเลิก</button>
            <button className="primary" disabled={busy || !f.name || !f.host || (!edit && !f.password)} onClick={save}>{busy ? 'กำลังบันทึก…' : 'บันทึก'}</button>
          </div>
        </div>
      </div>
    </div>
  );
}
