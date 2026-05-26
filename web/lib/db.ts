import { Pool } from 'pg';

// Singleton pool — shared across requests in the same server process.
const globalPool = globalThis as typeof globalThis & { _pgPool?: Pool };

if (!globalPool._pgPool) {
  globalPool._pgPool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    max: 10,
    idleTimeoutMillis: 30_000,
  });
}

export const pool = globalPool._pgPool;
export default pool;
