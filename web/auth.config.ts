import type { NextAuthConfig } from 'next-auth';
import Resend from 'next-auth/providers/resend';

const ADMIN_EMAIL = 'roikedem@gmail.com';

export const authConfig: NextAuthConfig = {
  providers: [
    Resend({
      apiKey: process.env.AUTH_RESEND_KEY,
      from: process.env.EMAIL_FROM ?? 'dev-ai <noreply@roikedem.com>',
    }),
  ],
  callbacks: {
    session: async ({ session, user }) => {
      if (session.user && user) {
        session.user.id = user.id;
        session.user.isAdmin = user.email === ADMIN_EMAIL;
      }
      return session;
    },
  },
  pages: {
    signIn: '/auth/signin',
    verifyRequest: '/auth/verify-request',
    error: '/auth/error',
  },
};
