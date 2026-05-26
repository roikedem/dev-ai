import NextAuth from 'next-auth';
import PostgresAdapter from '@auth/pg-adapter';
import { authConfig } from './auth.config';
import pool from './lib/db';

const ADMIN_EMAIL = 'roikedem@gmail.com';

export const { handlers, auth, signIn, signOut } = NextAuth({
  ...authConfig,
  adapter: PostgresAdapter(pool),
  callbacks: {
    ...authConfig.callbacks,
    signIn: async ({ user }) => {
      if (!user.email) return false;
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
});
