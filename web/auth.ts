import NextAuth from 'next-auth';
import PostgresAdapter from '@auth/pg-adapter';
import Nodemailer from 'next-auth/providers/nodemailer';
import { authConfig } from './auth.config';
import pool from './lib/db';

const ADMIN_EMAIL = 'roikedem@gmail.com';

export const { handlers, auth, signIn, signOut } = NextAuth({
  ...authConfig,
  adapter: PostgresAdapter(pool),
  session: { strategy: 'jwt' },
  providers: [
    Nodemailer({
      server: {
        host: process.env.SMTP_HOST,
        port: Number(process.env.SMTP_PORT ?? 587),
        auth: {
          user: process.env.SMTP_USER,
          pass: process.env.SMTP_PASSWORD,
        },
      },
      from: process.env.EMAIL_FROM ?? 'roi@hazerem.com',
    }),
  ],
  callbacks: {
    signIn: async ({ user }) => {
      if (!user.email) return false;
      const { rows } = await pool.query(
        'SELECT email FROM web_users WHERE email = $1',
        [user.email]
      );
      return rows.length > 0;
    },
    session: async ({ session, token }) => {
      if (token?.sub) session.user.id = token.sub;
      session.user.isAdmin = session.user.email === ADMIN_EMAIL;
      return session;
    },
  },
});
