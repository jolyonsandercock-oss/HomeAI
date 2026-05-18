/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  output: 'standalone',
  basePath: process.env.NEXT_PUBLIC_BASE_PATH || '',
  experimental: {
    serverComponentsExternalPackages: ['pg'],
  },
};
module.exports = nextConfig;
