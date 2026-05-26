import NextAuth from 'next-auth';
import PostgresAdapter from '@auth/pg-adapter';
import Resend from 'next-auth/providers/resend';
import pool from './lib/db';

const ADMIN_EMAIL = 'roikedem@gmail.com';

export const { handlers, auth, signIn, signOut } = NextAuth({
  adapter: PostgresAdapter(pool),
  providers: [
    Resend({
      apiKey: process.env.AUTH_RESEND_KEY,
      from: process.env.EMAIL_FROM ?? 'dev-ai <noreply@roikedem.com>',
    }),
  ],
  callbacks: {
    signIn: async ({ user }) => {
      if (!user.email) return false;
      // Only allow pre-approved users
      const { rows } = await pool.query(
        'SELECT email FROM web_users WHERE email = $1',
        [user.email]
      );
      return rows.length > 0;
    },
    session: async ({ session, user }) => {
      session.user.id = user.id;
      session.user.isAdmin = user.email === ADMIN_EMAIL;
      return session;
    },
  },
  pages: {
    signIn: '/auth/signin',
    verifyRequest: '/auth/verify-request',
    error: '/auth/error',
  },
});
