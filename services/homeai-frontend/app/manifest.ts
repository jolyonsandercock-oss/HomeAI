import type { MetadataRoute } from 'next';

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: 'Home AI — Mission Control',
    short_name: 'Home AI',
    description: 'The Olde Malthouse Inn · operational dashboard',
    start_url: '/app',
    scope: '/app',
    display: 'standalone',
    background_color: '#0a0a0a',
    theme_color: '#f59e0b',
    icons: [
      { src: '/app/icon.svg', sizes: 'any', type: 'image/svg+xml' },
    ],
  };
}
