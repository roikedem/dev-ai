import NextAuth from 'next-auth';
import { authConfig } from './auth.config';
import { NextResponse } from 'next/server';

const { auth } = NextAuth(authConfig);

export default auth((req) => {
  const isAuth = !!req.auth;
  const isAuthPage = req.nextUrl.pathname.startsWith('/auth/');
  const isApi = req.nextUrl.pathname.startsWith('/api/auth');

  if (isApi || isAuthPage) return NextResponse.next();
  if (!isAuth) {
    return NextResponse.redirect(new URL('/auth/signin', req.url));
  }
  return NextResponse.next();
});

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
