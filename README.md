# ZIVPN Hub

เว็บ panel (Next.js) จัดการ VPS ZIVPN หลายเครื่องจากหน้าเดียว — เว็บ SSH เข้าไปรันคำสั่ง `m` ที่ติดตั้งโดย `install.sh` + `menu.sh` (v1.1.0 ขึ้นไป)

## ติดตั้งที่ VPS (install.sh)

รับ root + มี systemd + apt (Debian/Ubuntu) วางไฟล์ `install.sh` และ `menu.sh` ไว้โฟลเดอร์เดียวกับ แล้วคัดลอกรันตามนี้:

#### 1. ดาวน์โหลดไฟล์ติดตั้ง
```bash
cd /root
wget https://github.com/savat/zivpn-ssh-panel/raw/main/install.sh
wget https://github.com/savat/zivpn-ssh-panel/raw/main/menu.sh
chmod +x install.sh menu.sh
```

#### 2. รันติดตั้ง (ถามที่อยู่เซิร์ฟเวอร์/ช่วงพอร์ต หรือเว้นว่าง = ค่าเริ่มต้น)
```bash
sudo sh install.sh
```

#### 3. แบบไม่ถามคำถาม (ตั้งค่าล่วงหน้า)
```bash
sudo ZP_YES=1 ZP_HOST=vpn.example.com ZP_RANGE=6000:19999 sh install.sh
```
เปิดพอร์ตที่ใช้: `5667/udp` (และช่วง hopping `6000:19999`) ใน UFW ให้อัตโนมัติ

#### 4. หลังติดตั้ง
```bash
sudo m          # เปิดเมนูจัดการผู้ใช้
sudo m backup   # สำรองข้อมูล
sudo m expire   # ไล่ผู้ใช้หมดอายุ
```

## ติดตั้ง
1. **VPS ทุกเครื่อง**: อัปเดต `menu.sh` เป็น v1.1.0 แล้วรัน `sh install.sh` ใหม่ (เก็บผู้ใช้เดิมไว้) — ต้องมีคำสั่ง `m api status|list`
2. **Supabase**: สร้างโปรเจกต์ → SQL Editor → รัน `supabase/schema.sql`
3. **Vercel**: import โปรเจกต์นี้ แล้วตั้ง Environment Variables ตาม `.env.example`
   - `openssl rand -base64 48` → `SESSION_SECRET`
   - `openssl rand -base64 32` → `ENCRYPTION_KEY` (เก็บสำรองไว้ ถ้าหายต้องใส่รหัส VPS ใหม่ทั้งหมด)
4. เปิดเว็บ → ใส่ `ADMIN_PASSWORD` → “+ เพิ่ม VPS” (ชื่อ, IP, พอร์ต SSH, ผู้ใช้, รหัส)

รันในเครื่อง: `npm i && cp .env.example .env.local && npm run dev`

## ความปลอดภัย (อ่านก่อนใช้)
- Vercel ไม่มี IP คงที่ → พอร์ต SSH ของ VPS ต้องเปิดให้ทุก IP เข้าได้ ควรตั้งรหัสผ่านยาวๆ และติดตั้ง `fail2ban`
- รหัส SSH ถูกเข้ารหัส AES-256-GCM ก่อนเก็บใน Supabase (ตารางปิด RLS เข้าถึงได้เฉพาะ service role)
- host key ของ VPS ถูกผูกไว้ตอนเชื่อมต่อครั้งแรก ถ้าเปลี่ยนจะไม่ยอมเชื่อมต่อจนกว่าจะกดยอมรับ
- ผู้ใช้ SSH ที่ไม่ใช่ root ต้องมี `sudo` แบบไม่ถามรหัสสำหรับ `/usr/local/bin/m`
- ล็อกอินหน้าเว็บใช้รหัสเดียว (ยังไม่มี 2FA / จำกัดจำนวนครั้งที่ลองผิด)
