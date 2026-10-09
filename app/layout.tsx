import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = { title: 'ZIVPN Hub', robots: { index: false, follow: false } };
export const viewport: Viewport = { width: 'device-width', initialScale: 1, themeColor: '#0b1220' };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="th">
      <body>{children}</body>
    </html>
  );
}
