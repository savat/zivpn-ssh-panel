/** @type {import('next').NextConfig} */
const nextConfig = {
  // ssh2 มี native add-on (optional) ห้ามให้ bundler รวมเข้าไป
  serverExternalPackages: ['ssh2', 'cpu-features'],
};
export default nextConfig;
