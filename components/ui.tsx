'use client';
import { useEffect, useRef, useState } from 'react';
import { clamp, fmtBits } from '@/lib/client';

/** ไล่ตัวเลขจากค่าเดิมไปค่าใหม่แบบนุ่มๆ */
export function useTween(target: number, ms = 700): number {
  const [v, setV] = useState(target);
  const from = useRef(target);
  useEffect(() => {
    const a = from.current;
    const t0 = performance.now();
    let raf = 0;
    const step = (now: number) => {
      const p = Math.min(1, (now - t0) / ms);
      const cur = a + (target - a) * (1 - Math.pow(1 - p, 3));
      from.current = cur;
      setV(cur);
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [target, ms]);
  return v;
}

export function Num({ value, digits = 0, suffix = '' }: { value: number; digits?: number; suffix?: string }) {
  const v = useTween(value);
  return <>{v.toFixed(digits)}{suffix}</>;
}

export function Rate({ bytesPerSec }: { bytesPerSec: number }) {
  const v = useTween(bytesPerSec, 900);
  return <>{fmtBits(v)}</>;
}

/** วงแหวนวัดค่า 0-100% */
export function Ring({ pct, label, sub }: { pct?: number; label: string; sub?: string }) {
  const r = 40;
  const c = 2 * Math.PI * r;
  const ready = pct !== undefined;
  const p = clamp(pct ?? 0);
  const shown = useTween(p);
  const tone = !ready ? 'wait' : p < 60 ? 'ok' : p < 85 ? 'warn' : 'bad';
  return (
    <div className="ringbox">
      <svg viewBox="0 0 100 100" className={`ring ${tone}`} role="img" aria-label={`${label} ${p.toFixed(0)}%`}>
        <circle className="ring-bg" cx="50" cy="50" r={r} />
        <circle
          className="ring-fg"
          cx="50" cy="50" r={r}
          strokeDasharray={c}
          style={{ strokeDashoffset: c * (1 - p / 100) }}
          transform="rotate(-90 50 50)"
        />
        <text x="50" y="54" textAnchor="middle" className="ring-num">{ready ? `${shown.toFixed(0)}%` : '…'}</text>
      </svg>
      <div className="ring-lab">{label}</div>
      {sub && <div className="ring-sub">{sub}</div>}
    </div>
  );
}

/** กราฟเส้นเล็ก ๆ (หลายเส้นซ้อนกันได้) */
export function Spark({ series, points = 40 }: { series: { vals: number[]; color: string }[]; points?: number }) {
  const W = 200;
  const H = 48;
  const max = Math.max(1, ...series.flatMap((s) => s.vals)) * 1.15;
  const step = W / (points - 1);
  const build = (vals: number[]) =>
    vals.map((v, i) => `${(W - (vals.length - 1 - i) * step).toFixed(1)},${(H - 2 - (v / max) * (H - 6)).toFixed(1)}`);
  const gid = useRef(`g${Math.random().toString(36).slice(2, 8)}`).current;
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="spark" preserveAspectRatio="none">
      <defs>
        {series.map((s, i) => (
          <linearGradient key={i} id={`${gid}${i}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor={s.color} stopOpacity=".35" />
            <stop offset="1" stopColor={s.color} stopOpacity="0" />
          </linearGradient>
        ))}
      </defs>
      {series.map((s, i) => {
        if (s.vals.length < 2) return null;
        const pts = build(s.vals);
        const first = pts[0].split(',')[0];
        return (
          <g key={i}>
            <polygon points={`${first},${H} ${pts.join(' ')} ${W},${H}`} fill={`url(#${gid}${i})`} />
            <polyline points={pts.join(' ')} fill="none" stroke={s.color} strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
          </g>
        );
      })}
    </svg>
  );
}
