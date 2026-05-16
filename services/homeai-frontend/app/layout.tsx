import './globals.css';
import type { Metadata } from 'next';
import { GeistSans } from 'geist/font/sans';
import { GeistMono } from 'geist/font/mono';
import { Providers } from '@/components/Providers';
import { GlobalShell } from '@/components/shell/GlobalShell';

export const metadata: Metadata = {
  title: 'Home AI — Mission Control',
  description: 'The Olde Malthouse Inn · operational dashboard',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable} dark`}>
      <body className="font-sans antialiased">
        <Providers>
          <GlobalShell>{children}</GlobalShell>
        </Providers>
      </body>
    </html>
  );
}
