import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createWorker } from "../src/worker.mjs";
globalThis.crypto ||= webcrypto;

// Run the production SQL against actual SQLite rather than emulate its predicates.
const PYTHON = `import json,sqlite3,sys
p=json.load(sys.stdin)
c=sqlite3.connect(p['path']); c.row_factory=sqlite3.Row
if 'schema' in p: c.executescript(p['schema']); rows=[]
else:
 cur=c.execute(p['sql'],p['args']); rows=[dict(r) for r in cur.fetchall()] if cur.description else []
c.commit(); print(json.dumps(rows)); c.close()
`;
class Database {
  constructor(path) { this.path = path; }
  query(data) {
    const result = spawnSync("python3", ["-c", PYTHON], {
      input: JSON.stringify({ path: this.path, ...data }), encoding: "utf8",
    });
    if (result.status !== 0) throw new Error(result.stderr);
    return JSON.parse(result.stdout);
  }
  prepare(sql) {
    const database = this;
    return { bind(...args) {
      return {
        async first() { return database.query({ sql, args })[0] || null; },
        async run() { database.query({ sql, args }); return { success: true }; },
      };
    } };
  }
}
const ORIGIN = "https://calendar.example.test";
const scopes = "openid email https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events";
function fixture(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), "calendar-onboarding-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const db = new Database(join(dir, "sessions.sqlite3"));
  db.query({ schema: readFileSync(new URL("../migrations/0001_pairings.sql", import.meta.url), "utf8") });
  let clock = 1000000;
  const calls = [];
  const env = { DB: db, PUBLIC_ORIGIN: ORIGIN, GOOGLE_CLIENT_ID: "test-web-client",
    GOOGLE_CLIENT_SECRET: "private-client-secret", TOKEN_ENCRYPTION_KEY: Buffer.alloc(32, 9).toString("base64url"),
    PAIRING_LIMIT: { limit: async () => ({ success: true }) },
    TOKEN_LIMIT: { limit: async () => ({ success: true }) },
  };
  const worker = createWorker({ now: () => clock, upstreamFetch: async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith("/userinfo")) return Response.json(options.badIdentity ? { email: "person@example.test", email_verified: false } : { email: "person@example.test", email_verified: true });
    if (url.endsWith("/revoke")) return new Response("");
    if (options.rejectUnsupportedRedirect && init.redirect === "error") throw new TypeError("Invalid redirect value");
    if (options.redirectResponse) return new Response(null, { status: 302, headers: { Location: "https://untrusted.example/" } });
    if (new URLSearchParams(init.body).get("grant_type") === "refresh_token") return options.refreshFailure
      ? Response.json({ error: "invalid_grant", error_description: "DO NOT EXPOSE THIS" }, { status: 400 })
      : Response.json({ access_token: "renewed-access", expires_in: 3600 });
    if (options.tokenError) return Response.json({ error: options.tokenError, error_description: "DO NOT EXPOSE THIS" }, { status: 400 });
    if (options.exchangeFailure) return Response.json({ error: "server_error", error_description: "DO NOT EXPOSE THIS" }, { status: 500 });
    return Response.json({ access_token: "initial-access", expires_in: 3600,
      refresh_token: "private-google-refresh", scope: options.scope ?? scopes });
  } });
  const request = (path, { method = "GET", json, headers = {} } = {}) => worker.fetch(new Request(ORIGIN + path, {
    method, headers: { ...(json !== undefined ? { "Content-Type": "application/json" } : {}), ...headers },
    ...(json !== undefined ? { body: JSON.stringify(json) } : {}),
  }), env);
  async function create() {
    const response = await request("/v1/pairings", { method: "POST", json: { provider: "google" } });
    assert.equal(response.status, 201);
    return response.json();
  }
  const poll = (pair, method = "GET", secret = pair.poll_secret) => request("/v1/pairings/" + pair.id, {
    method, headers: { Authorization: "Bearer " + secret },
  });
  async function start(pair) {
    const response = await request("/connect/" + pair.id, { method: "POST", headers: { Origin: ORIGIN } });
    assert.equal(response.status, 303);
    const location = new URL(response.headers.get("Location"));
    return { state: location.searchParams.get("state"), location,
      cookie: response.headers.get("Set-Cookie").split(";")[0] };
  }
  const finish = (auth, extra = "code=private-code") => request("/oauth/google/callback?state=" + auth.state + "&" + extra, {
    headers: { Cookie: auth.cookie },
  });
  return { env, db, request, create, poll, start, finish, calls, worker, advance: n => { clock += n * 1000; } };
}

test("phone consent, PKCE, encrypted delivery, one-time claim, and token renewal", async t => {
  const f = fixture(t);
  const pair = await f.create();
  assert.equal(pair.expires_in, 600);
  assert.match(pair.user_code, /^\d{6}$/);
  assert.equal(pair.verification_uri, ORIGIN + "/connect/" + pair.id);
  const stored = f.db.query({ sql: "SELECT * FROM pairings", args: [] })[0];
  assert.notEqual(stored.poll_hash, pair.poll_secret);
  const phone = await f.request("/connect/" + pair.id);
  assert.match(await phone.text(), new RegExp(pair.user_code));
  assert.equal(phone.headers.get("Cache-Control"), "no-store");
  assert.equal(phone.headers.get("Referrer-Policy"), "same-origin");
  // Other responses still suppress referrers, including the OAuth callback.
  assert.equal((await f.request("/health")).headers.get("Referrer-Policy"), "no-referrer");
  const auth = await f.start(pair);
  assert.equal(auth.location.origin, "https://accounts.google.com");
  assert.equal(auth.location.searchParams.get("redirect_uri"), ORIGIN + "/oauth/google/callback");
  assert.equal(auth.location.searchParams.get("code_challenge_method"), "S256");
  assert.equal((await f.poll(pair)).status, 200);
  assert.equal((await f.finish(auth)).status, 200);
  const ready = f.db.query({ sql: "SELECT * FROM pairings", args: [] })[0];
  assert.equal(ready.verifier, null);
  assert.equal(ready.oauth_hash, null);
  assert.ok(!JSON.stringify(ready).includes("private-google-refresh"));
  const [one, two] = await Promise.all([f.poll(pair), f.poll(pair)]);
  assert.deepEqual([one.status, two.status].sort(), [200, 404]);
  const delivered = await (one.status === 200 ? one : two).json();
  assert.equal(delivered.account.email, "person@example.test");
  assert.equal(delivered.credentials.type, "google-relay-v1");
  assert.ok(!JSON.stringify(delivered).includes("private-google-refresh"));
  assert.ok(!JSON.stringify(delivered).includes("private-client-secret"));
  const response = await f.request("/v1/google/token", { method: "POST", json: { grant: delivered.credentials.grant } });
  assert.deepEqual(await response.json(), { access_token: "renewed-access", token_type: "Bearer", expires_in: 3600 });
  assert.equal(new URLSearchParams(f.calls.at(-1).init.body).get("refresh_token"), "private-google-refresh");
  assert.equal(new URLSearchParams(f.calls[0].init.body).get("code_verifier").length, 64);
  assert.equal(f.calls[0].init.redirect, "manual");
});

test("QR identifier alone cannot poll, claim, or cancel credentials", async t => {
  const f = fixture(t), pair = await f.create();
  assert.equal((await f.request("/v1/pairings/" + pair.id)).status, 401);
  for (const method of ["GET", "DELETE"]) {
    assert.equal((await f.poll(pair, method, "a".repeat(43))).status, 404);
  }
  assert.equal((await f.poll(pair, "DELETE")).status, 200);
  assert.equal((await f.request("/connect/" + pair.id)).status, 410);
});

test("callback requires matching browser state; duplicate callbacks do not exchange twice", async t => {
  const f = fixture(t), pair = await f.create(), auth = await f.start(pair);
  assert.equal((await f.request("/oauth/google/callback?state=" + auth.state + "&code=x")).status, 400);
  assert.equal((await f.finish({ ...auth, state: "x".repeat(43) })).status, 400);
  assert.equal(f.calls.length, 0);
  assert.equal((await f.finish(auth)).status, 200);
  assert.equal((await f.finish(auth)).status, 410);
  assert.equal(f.calls.filter(c => c.url.endsWith("/token")).length, 1);
});

test("expired sessions cannot start, complete, or deliver; cleanup removes them", async t => {
  const f = fixture(t), pair = await f.create(), auth = await f.start(pair);
  f.advance(601);
  assert.equal((await f.poll(pair)).status, 410);
  assert.equal((await f.finish(auth)).status, 410);
  assert.equal(f.calls.length, 0);
  await f.worker.scheduled({}, f.env);
  assert.equal((await f.poll(pair)).status, 404);
});

test("denied authorization never yields credentials", async t => {
  const f = fixture(t), pair = await f.create(), auth = await f.start(pair);
  assert.equal((await f.finish(auth, "error=access_denied")).status, 200);
  assert.equal((await (await f.poll(pair)).json()).status, "denied");
  assert.equal(f.calls.length, 0);
});

test("missing Calendar permissions fail safely and revoke the unusable token", async t => {
  const f = fixture(t, { scope: "openid email" }), pair = await f.create(), auth = await f.start(pair);
  const response = await f.finish(auth);
  assert.equal(response.status, 400);
  assert.match(await response.text(), /Allow both calendar permissions/);
  assert.equal((await (await f.poll(pair)).json()).status, "error");
  assert.ok(f.calls.some(c => c.url.endsWith("/revoke")));
});

test("Google errors are sanitized and invalid refresh grants request reconnection", async t => {
  const failed = fixture(t, { exchangeFailure: true }), pair = await failed.create();
  const response = await failed.finish(await failed.start(pair));
  assert.equal(response.status, 502);
  assert.ok(!(await response.text()).includes("DO NOT EXPOSE"));
  const f = fixture(t, { refreshFailure: true }), other = await f.create();
  await f.finish(await f.start(other));
  const grant = (await (await f.poll(other)).json()).credentials.grant;
  const revoked = await f.request("/v1/google/token", { method: "POST", json: { grant } });
  assert.equal(revoked.status, 401);
  assert.deepEqual(await revoked.json(), { error: "google_reauthorization_required" });
});

test("tampered encrypted grants and grants for another client cannot refresh", async t => {
  const f = fixture(t), pair = await f.create();
  await f.finish(await f.start(pair));
  const grant = (await (await f.poll(pair)).json()).credentials.grant;
  const parts = grant.split("."); parts[2] = (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
  assert.equal((await f.request("/v1/google/token", { method: "POST", json: { grant: parts.join(".") } })).status, 401);
  f.env.GOOGLE_CLIENT_ID = "different-client";
  assert.equal((await f.request("/v1/google/token", { method: "POST", json: { grant } })).status, 401);
});

test("origin guards, request limits, and missing configuration fail closed", async t => {
  const f = fixture(t), pair = await f.create();
  assert.equal((await f.request("/connect/" + pair.id, { method: "POST", headers: { Origin: "https://other.test" } })).status, 403);
  assert.equal((await f.request("/v1/pairings", { method: "POST", json: { provider: "google" }, headers: { Origin: ORIGIN } })).status, 403);
  assert.equal((await f.request("/v1/pairings", { method: "POST", json: { provider: "google", junk: "x".repeat(17000) } })).status, 413);
  f.env.PAIRING_LIMIT = { limit: async () => ({ success: false }) };
  const limited = await f.request("/v1/pairings", { method: "POST", json: { provider: "google" } });
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("Retry-After"), "60");
  delete f.env.TOKEN_ENCRYPTION_KEY;
  assert.equal((await f.poll(pair)).status, 503);
  assert.equal((await f.request("/health")).status, 200);
});

test("phone forms retain their same-origin Origin without accepting null-origin submissions", async t => {
  const f = fixture(t), pair = await f.create();
  const phone = await f.request("/connect/" + pair.id);
  assert.equal(phone.headers.get("Referrer-Policy"), "same-origin");
  const rejected = await f.request("/connect/" + pair.id, { method: "POST", headers: { Origin: "null" } });
  assert.equal(rejected.status, 403);
  const html = await rejected.text();
  assert.match(html, /Reference: origin_required/);
  assert.match(html, /regular browser/);
  // Failed origin validation must leave the pairing available for a valid form POST.
  const auth = await f.start(pair);
  assert.equal(auth.location.origin, "https://accounts.google.com");
  const finished = await f.finish(auth);
  assert.equal(finished.status, 200);
  assert.equal(finished.headers.get("Referrer-Policy"), "no-referrer");
});

test("callback failures identify the safe step and cause without exposing Google's response", async t => {
  for (const [error, reference] of [
    ["invalid_client", "google_client_credentials_rejected"],
    ["unauthorized_client", "google_client_credentials_rejected"],
    ["redirect_uri_mismatch", "google_callback_mismatch"],
    ["invalid_grant", "google_reauthorization_required"],
    ["invalid_scope", "google_scope_configuration_invalid"],
  ]) {
    const f = fixture(t, { tokenError: error }), pair = await f.create();
    const response = await f.finish(await f.start(pair));
    const html = await response.text();
    assert.match(html, new RegExp("Reference: " + reference));
    assert.match(html, /Step: token_exchange/);
    assert.doesNotMatch(html, /DO NOT EXPOSE|private-client-secret|private-code|private-google-refresh/);
    assert.equal((await (await f.poll(pair)).json()).status, "error");
  }
  const f = fixture(t, { badIdentity: true }), pair = await f.create();
  const failed = await f.finish(await f.start(pair));
  const html = await failed.text();
  assert.match(html, /Reference: google_identity_unavailable/);
  assert.match(html, /Step: account_lookup/);
  assert.ok(f.calls.some(c => c.url.endsWith("/revoke")));
});

test("database failure during callback reports pairing_storage and still attempts revocation", async t => {
  const f = fixture(t), pair = await f.create(), auth = await f.start(pair);
  const db = f.env.DB;
  f.env.DB = { prepare(sql) {
    if (sql.includes("SET status='ready'")) throw new Error("DO NOT EXPOSE DATABASE DETAILS");
    return db.prepare(sql);
  } };
  const response = await f.finish(auth);
  assert.equal(response.status, 502);
  const html = await response.text();
  assert.match(html, /Reference: callback_pairing_storage_failed/);
  assert.match(html, /Step: pairing_storage/);
  assert.doesNotMatch(html, /DO NOT EXPOSE|private-google-refresh/);
  assert.ok(f.calls.some(c => c.url.endsWith("/revoke")));
});

test("Google requests use Workers-compatible manual redirects and explicit form encoding", async t => {
  const f = fixture(t, { rejectUnsupportedRedirect: true }), pair = await f.create();
  assert.equal((await f.finish(await f.start(pair))).status, 200);
  const exchange = f.calls.find(c => c.url.endsWith("/token"));
  assert.equal(exchange.init.redirect, "manual");
  assert.equal(exchange.init.headers["Content-Type"], "application/x-www-form-urlencoded");
  assert.equal(typeof exchange.init.body, "string");
  assert.equal(new URLSearchParams(exchange.init.body).get("grant_type"), "authorization_code");
  const grant = (await (await f.poll(pair)).json()).credentials.grant;
  assert.equal((await f.request("/v1/google/token", { method: "POST", json: { grant } })).status, 200);
  assert.equal(f.calls.at(-1).init.redirect, "manual");
});

test("Google redirects are rejected without forwarding tokens or client credentials", async t => {
  const f = fixture(t, { redirectResponse: true }), pair = await f.create();
  const response = await f.finish(await f.start(pair));
  assert.equal(response.status, 502);
  assert.match(await response.text(), /Reference: google_unexpected_redirect/);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].init.redirect, "manual");
});
