-- NextAuth required tables
CREATE TABLE IF NOT EXISTS verification_token (
  identifier TEXT NOT NULL,
  expires     TIMESTAMPTZ NOT NULL,
  token       TEXT NOT NULL,
  PRIMARY KEY (identifier, token)
);

CREATE TABLE IF NOT EXISTS accounts (
  id                   SERIAL PRIMARY KEY,
  "userId"             INTEGER NOT NULL,
  type                 VARCHAR(255) NOT NULL,
  provider             VARCHAR(255) NOT NULL,
  "providerAccountId"  VARCHAR(255) NOT NULL,
  refresh_token        TEXT,
  access_token         TEXT,
  expires_at           BIGINT,
  id_token             TEXT,
  scope                TEXT,
  session_state        TEXT,
  token_type           TEXT,
  UNIQUE (provider, "providerAccountId")
);

CREATE TABLE IF NOT EXISTS sessions (
  id              SERIAL PRIMARY KEY,
  "userId"        INTEGER NOT NULL,
  expires         TIMESTAMPTZ NOT NULL,
  "sessionToken"  VARCHAR(255) UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
  id             SERIAL PRIMARY KEY,
  name           VARCHAR(255),
  email          VARCHAR(255) UNIQUE,
  "emailVerified" TIMESTAMPTZ,
  image          TEXT
);

-- Our whitelist of allowed users
CREATE TABLE IF NOT EXISTS web_users (
  id         BIGSERIAL PRIMARY KEY,
  email      TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Admin is always allowed
INSERT INTO web_users (email)
VALUES ('roikedem@gmail.com')
ON CONFLICT (email) DO NOTHING;
