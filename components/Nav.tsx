'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { api } from '@/lib/client';

const IconGrid = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="7" height="9" rx="2" /><rect x="14" y="3" width="7" height="5" rx="2" /><rect x="14" y="12" width="7" height="9" rx="2" /><rect x="3" y="16" width="7" height="5" rx="2" /></svg>
);
const IconUsers = () => (
  <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20c.6-3.4 3.2-5.5 6.5-5.5s5.9 2.1 6.5 5.5" /><path d="M16 4.7a3.5 3.5 0 0 1 0 6.6M18.5 14.8c1.7.7 2.7 2.4 3 5.2" /></svg>
);

export default function Nav() {
  const path = usePathname();
  if (path === '/login') return null;

  async function logout() {
    await api('/api/auth/logout', 'POST');
    window.location.href = '/login';
  }

  return (
    <header className="nav">
      <div className="nav-in">
        <Link href="/" className="brand"><span className="logo" />ZIVPN <b>Hub</b></Link>
        <nav className="tabs">
          <Link href="/" className={path === '/' ? 'on' : ''}><IconGrid /><span>แดชบอร์ด</span></Link>
          <Link href="/users" className={path.startsWith('/users') ? 'on' : ''}><IconUsers /><span>ผู้ใช้</span></Link>
        </nav>
        <button className="ghost" onClick={logout}>ออก</button>
      </div>
    </header>
  );
}
