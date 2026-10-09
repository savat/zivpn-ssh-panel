-- รันใน Supabase > SQL Editor
create table if not exists public.servers (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  host             text not null,
  port             int  not null default 22,
  username         text not null default 'root',
  secret_enc       text not null,          -- รหัสผ่าน SSH เข้ารหัส AES-256-GCM แล้ว
  host_fingerprint text,                   -- SHA256 ของ host key (ผูกครั้งแรก, ใช้ตรวจครั้งต่อไป)
  created_at       timestamptz not null default now()
);

-- เปิด RLS โดยไม่มี policy = ปิดทุกทางจาก anon/authenticated
-- เข้าถึงได้เฉพาะ service_role ที่ใช้ในเซิร์ฟเวอร์ของเว็บนี้
alter table public.servers enable row level security;
