import './globals.css';
import type { Metadata } from 'next';
import { GeistSans } from 'geist/font/sans';
import { GeistMono } from 'geist/font/mono';
import { Providers } from '@/components/Providers';
import { GlobalShell } from '@/components/shell/GlobalShell';
import { DynamicTitle } from "@/components/ui/DynamicTitle";

export const metadata: Metadata = {
  title: 'Home AI — Mission Control',
  description: 'The Olde Malthouse Inn · operational dashboard',
  manifest: '/app/manifest.webmanifest',
  themeColor: '#f59e0b',
  appleWebApp: { capable: true, title: 'Home AI', statusBarStyle: 'black-translucent' },
};

// Force dynamic rendering globally — the shell + multiple pages call
// useSearchParams() (date overrides, dialog state) which Next.js otherwise
// requires to live inside a Suspense boundary at every call site.
// This is a logged-in dashboard, so prerendering has no SEO value.
export const dynamic = 'force-dynamic';

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable} dark`}>
      <body className="font-sans antialiased">
        <Providers>
          <DynamicTitle /><GlobalShell>{children}</GlobalShell>
        </Providers>
      </body>
    </html>
  );
}
