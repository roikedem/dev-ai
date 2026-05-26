import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'dev-ai tasks',
  description: 'Task management dashboard for dev-ai automation',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">{children}</body>
    </html>
  );
}
