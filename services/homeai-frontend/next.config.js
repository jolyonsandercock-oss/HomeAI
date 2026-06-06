/** @type {import('next').NextConfig} */

// H6 / review A5 — security response headers. The CSP is deliberately limited to
// directives that DON'T touch script/style loading (frame-ancestors, object-src,
// base-uri), so it hardens against clickjacking / object & base-uri injection
// without risking Next.js' inline runtime. A full default-src CSP needs render
// testing and is deferred.
const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
  {
    key: 'Content-Security-Policy',
    value: "frame-ancestors 'none'; object-src 'none'; base-uri 'self'",
  },
];

const nextConfig = {
  reactStrictMode: true,
  output: 'standalone',
  basePath: process.env.NEXT_PUBLIC_BASE_PATH || '',
  experimental: {
    serverComponentsExternalPackages: ['pg'],
  },
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};
module.exports = nextConfig;
