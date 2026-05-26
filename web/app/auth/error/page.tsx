import Link from 'next/link';

export default function AuthError({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center">
      <div className="bg-white border border-gray-200 rounded-xl p-8 w-full max-w-sm shadow-sm text-center">
        <div className="text-4xl mb-4">⚠️</div>
        <h1 className="text-xl font-semibold text-gray-900 mb-2">Access denied</h1>
        <p className="text-sm text-gray-500 mb-4">
          Your email is not authorized. Contact the admin to request access.
        </p>
        <Link href="/auth/signin" className="text-sm text-blue-600 hover:underline">
          Try again
        </Link>
      </div>
    </div>
  );
}
