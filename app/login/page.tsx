'use client';
import { useState } from 'react';

export default function Login() {
  const [password, setPassword] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true);
    setErr('');
    const r = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    if (r.ok) {
      window.location.href = '/';
      return;
    }
    const j = await r.json().catch(() => ({}));
    setErr(j.error || 'เข้าสู่ระบบไม่สำเร็จ');
    setBusy(false);
  }

  return (
    <main className="login">
      <div className="card">
        <h1>ZIVPN Hub</h1>
        <p className="muted">จัดการ VPS ทุกเครื่องในที่เดียว</p>
        <input
          type="password"
          placeholder="รหัสผ่านผู้ดูแล"
          value={password}
          autoFocus
          onChange={(e) => setPassword(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && password && submit()}
        />
        {err && <div className="err">{err}</div>}
        <button className="primary" disabled={busy || !password} onClick={submit}>
          {busy ? 'กำลังเข้าสู่ระบบ…' : 'เข้าสู่ระบบ'}
        </button>
      </div>
    </main>
  );
}
