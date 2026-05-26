export default function VerifyRequest() {
  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center">
      <div className="bg-white border border-gray-200 rounded-xl p-8 w-full max-w-sm shadow-sm text-center">
        <div className="text-4xl mb-4">📧</div>
        <h1 className="text-xl font-semibold text-gray-900 mb-2">Check your email</h1>
        <p className="text-sm text-gray-500">
          A sign-in link has been sent to your inbox. Click it to access the dashboard.
        </p>
      </div>
    </div>
  );
}
