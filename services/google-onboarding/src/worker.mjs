const CALENDAR_SCOPES = [
  "https://www.googleapis.com/auth/calendar.readonly",
  "https://www.googleapis.com/auth/calendar.events",
];
const SCOPES = [...CALENDAR_SCOPES, "openid", "email"].join(" ");
const SESSION_SECONDS = 600;
const COOKIE = "__Host-calendar-pairing";
const encoder = new TextEncoder();
const decoder = new TextDecoder();

class HttpError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
function b64(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
function unb64(text) {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new Error("Invalid encoding");
  return Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0));
}
function random(bytes = 32) { return b64(crypto.getRandomValues(new Uint8Array(bytes))); }
async function hash(text) { return b64(await crypto.subtle.digest("SHA-256", encoder.encode(text))); }
function equal(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let different = 0;
  for (let i = 0; i < a.length; i++) different |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return different === 0;
}
function config(env) {
  let origin;
  try { origin = new URL(env.PUBLIC_ORIGIN); } catch { throw new HttpError(503, "service_not_configured"); }
  const local = ["localhost", "127.0.0.1"].includes(origin.hostname);
  if ((origin.protocol !== "https:" && !(local && origin.protocol === "http:")) ||
      origin.origin !== env.PUBLIC_ORIGIN || !env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) {
    throw new HttpError(503, "service_not_configured");
  }
  try {
    if (unb64(env.TOKEN_ENCRYPTION_KEY).length !== 32) throw new Error();
  } catch { throw new HttpError(503, "service_not_configured"); }
  if (!env.DB || !env.PAIRING_LIMIT || !env.TOKEN_LIMIT) throw new HttpError(503, "service_not_configured");
  return { origin: origin.origin, callback: origin.origin + "/oauth/google/callback", local };
}
async function key(env) {
  return crypto.subtle.importKey("raw", unb64(env.TOKEN_ENCRYPTION_KEY), "AES-GCM", false, ["encrypt", "decrypt"]);
}
async function seal(env, payload) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv,
    additionalData: encoder.encode("remarkable-calendar/google-grant/v1") },
    await key(env), encoder.encode(JSON.stringify(payload)));
  return "v1." + b64(iv) + "." + b64(ciphertext);
}
async function unseal(env, grant) {
  try {
    if (typeof grant !== "string" || grant.length > 12000) throw new Error();
    const [version, iv, ciphertext, extra] = grant.split(".");
    if (version !== "v1" || extra !== undefined) throw new Error();
    const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv),
      additionalData: encoder.encode("remarkable-calendar/google-grant/v1") },
      await key(env), unb64(ciphertext));
    const value = JSON.parse(decoder.decode(plaintext));
    if (value.client_id !== env.GOOGLE_CLIENT_ID || typeof value.refresh_token !== "string" ||
        !value.refresh_token || !CALENDAR_SCOPES.every(s => value.scope.split(" ").includes(s))) throw new Error();
    return value;
  } catch { throw new HttpError(401, "invalid_grant"); }
}
function escape(value) {
  return String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...headers } });
}
function page(title, body, status = 200, headers = {}) {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)} · Calendar</title>
<style>body{font:18px system-ui,sans-serif;line-height:1.5;margin:0;padding:32px 20px;color:#171717;background:#fafafa}main{max-width:480px;margin:40px auto}h1{font-size:30px;line-height:1.2}.code{font-size:36px;font-weight:700;letter-spacing:.18em}button{font:inherit;padding:14px 24px;border:0;border-radius:8px;color:white;background:#171717;cursor:pointer}small{color:#555}</style>
<main><h1>${escape(title)}</h1>${body}</main></html>`, { status,
    headers: { "Content-Type": "text/html; charset=utf-8", ...headers } });
}
function secure(response) {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries({
    "Cache-Control": "no-store", "Pragma": "no-cache",
    "Referrer-Policy": response.headers.get("Referrer-Policy") || "no-referrer",
    "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://accounts.google.com; frame-ancestors 'none'; base-uri 'none'",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  })) headers.set(name, value);
  return new Response(response.body, { status: response.status, headers });
}
async function body(request) {
  if (Number(request.headers.get("Content-Length")) > 16384) throw new HttpError(413, "request_too_large");
  if (!(request.headers.get("Content-Type") || "").startsWith("application/json")) throw new HttpError(415, "json_required");
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "invalid_request");
  let size = 0;
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 16384) { await reader.cancel(); throw new HttpError(413, "request_too_large"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try {
    const parsed = JSON.parse(decoder.decode(bytes));
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") throw new Error();
    return parsed;
  } catch { throw new HttpError(400, "invalid_request"); }
}
async function limit(binding, request, action) {
  const ip = request.headers.get("CF-Connecting-IP") || "local";
  if (!(await binding.limit({ key: action + ":" + ip })).success) throw new HttpError(429, "slow_down");
}
function noBrowserOrigin(request) {
  if (request.headers.has("Origin")) throw new HttpError(403, "native_client_required");
}
function cookieValue(request, name) {
  return (request.headers.get("Cookie") || "").split(";").map(p => p.trim())
    .find(p => p.startsWith(name + "="))?.slice(name.length + 1);
}
function cookie(state, local, expire = false) {
  // Secure __Host- cookies cannot be used over plain HTTP in every local browser.
  return `${local ? "calendar-pairing-local" : COOKIE}=${state}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${expire ? 0 : SESSION_SECONDS}${local ? "" : "; Secure"}`;
}
function bearer(request) {
  const value = request.headers.get("Authorization") || "";
  if (!/^Bearer [A-Za-z0-9_-]{43}$/.test(value)) throw new HttpError(401, "authorization_required");
  return value.slice(7);
}

export function createWorker({ upstreamFetch = (...args) => fetch(...args), now = () => Date.now() } = {}) {
  const seconds = () => Math.floor(now() / 1000);
  async function upstream(url, options) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await upstreamFetch(url, { ...options, redirect: "manual", signal: controller.signal });
      if (response.status >= 300 && response.status < 400) {
        await response.body?.cancel();
        throw new HttpError(502, "google_unexpected_redirect");
      }
      const reader = response.body?.getReader();
      const chunks = [];
      let size = 0;
      if (reader) while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 65536) { await reader.cancel(); throw new Error("Response too large"); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return new Response([204, 205, 304].includes(response.status) ? null : bytes,
        { status: response.status, headers: response.headers });
    } catch (error) {
      if (error instanceof HttpError) throw error;
      throw new HttpError(502, "google_unavailable");
    }
    finally { clearTimeout(timeout); }
  }
  async function token(env, fields) {
    const response = await upstream("https://oauth2.googleapis.com/token", { method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET, ...fields }).toString() });
    let data;
    try { data = await response.json(); } catch { throw new HttpError(502, "google_unavailable"); }
    if (!response.ok) {
      if (data.error === "invalid_grant") throw new HttpError(401, "google_reauthorization_required");
      if (data.error === "invalid_client" || data.error === "unauthorized_client")
        throw new HttpError(502, "google_client_credentials_rejected");
      if (data.error === "redirect_uri_mismatch") throw new HttpError(502, "google_callback_mismatch");
      if (data.error === "invalid_scope") throw new HttpError(502, "google_scope_configuration_invalid");
      throw new HttpError(502, "google_unavailable");
    }
    if (typeof data.access_token !== "string" || !data.access_token ||
        !Number.isFinite(data.expires_in) || data.expires_in <= 0) throw new HttpError(502, "google_unavailable");
    return data;
  }
  async function callback(request, env, cfg, url) {
    const state = url.searchParams.get("state") || "";
    const storedCookie = cookieValue(request, cfg.local ? "calendar-pairing-local" : COOKIE);
    if (state.length !== 43 || !equal(state, storedCookie)) throw new HttpError(400, "invalid_oauth_state");
    const session = await env.DB.prepare(`UPDATE pairings SET status='exchanging'
      WHERE oauth_hash=? AND status='authorizing' AND expires_at>? RETURNING *`)
      .bind(await hash(state), seconds()).first();
    if (!session) throw new HttpError(410, "pairing_expired_or_used");
    const clear = { "Set-Cookie": cookie("", cfg.local, true) };
    if (url.searchParams.has("error")) {
      await env.DB.prepare("UPDATE pairings SET status='denied',verifier=NULL,oauth_hash=NULL WHERE id=?")
        .bind(session.id).run();
      return page("Sign-in cancelled", "<p>No account was connected. You can start again on your tablet.</p>", 200, clear);
    }
    let refreshToken;
    let stage = "token_exchange";
    try {
      const code = url.searchParams.get("code");
      if (!code || code.length > 4096) throw new HttpError(400, "invalid_oauth_callback");
      const data = await token(env, { code, code_verifier: session.verifier,
        redirect_uri: cfg.callback, grant_type: "authorization_code" });
      refreshToken = data.refresh_token;
      const scope = typeof data.scope === "string" ? data.scope : "";
      if (typeof refreshToken !== "string" || !refreshToken) throw new HttpError(400, "google_offline_access_required");
      if (!CALENDAR_SCOPES.every(s => scope.split(" ").includes(s))) throw new HttpError(400, "calendar_permissions_required");
      stage = "account_lookup";
      const identity = await upstream("https://openidconnect.googleapis.com/v1/userinfo", {
        headers: { Authorization: "Bearer " + data.access_token },
      });
      const user = identity.ok ? await identity.json() : null;
      if (!user || typeof user.email !== "string" || user.email.length > 320 || user.email_verified !== true) {
        throw new HttpError(502, "google_identity_unavailable");
      }
      stage = "credential_encryption";
      const grant = await seal(env, { client_id: env.GOOGLE_CLIENT_ID, refresh_token: refreshToken, scope });
      stage = "pairing_storage";
      const saved = await env.DB.prepare(`UPDATE pairings SET status='ready',grant=?,email=?,verifier=NULL,oauth_hash=NULL
        WHERE id=? AND status='exchanging' AND expires_at>? RETURNING id`)
        .bind(grant, user.email, session.id, seconds()).first();
      if (!saved) throw new HttpError(410, "pairing_expired_or_used");
      return page("Return to your tablet", "<p>Google sign-in is complete. Your tablet can now finish connecting your account.</p>", 200, clear);
    } catch (error) {
      try {
        await env.DB.prepare("UPDATE pairings SET status='error',grant=NULL,email=NULL,verifier=NULL,oauth_hash=NULL WHERE id=?")
          .bind(session.id).run();
      } catch { /* Still attempt revocation and return a sanitized failure if D1 is unavailable. */ }
      if (typeof refreshToken === "string" && refreshToken) {
        try { await upstream("https://oauth2.googleapis.com/revoke", {
          method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ token: refreshToken }).toString(),
        }); } catch { /* Best effort; credentials are never delivered after failure. */ }
      }
      const reference = error instanceof HttpError ? error.code : "callback_" + stage + "_failed";
      const messages = {
        calendar_permissions_required: "Allow both calendar permissions when signing in. Start again on your tablet.",
        google_offline_access_required: "Google did not grant offline access. Start a new connection on your tablet and approve access again.",
        google_client_credentials_rejected: "Google rejected the service's OAuth client credentials. The administrator must check that the Web application client ID and client secret belong to the same client.",
        google_callback_mismatch: "The service callback does not match the redirect URI registered with Google. The administrator must check the Google Web application client.",
        google_scope_configuration_invalid: "Google rejected the configured permissions. The administrator must check the OAuth scope configuration.",
        google_reauthorization_required: "Google rejected or expired this sign-in code. Start a new connection on your tablet and finish sign-in promptly.",
        google_identity_unavailable: "Your Google account information could not be verified. Start again on your tablet.",
        pairing_expired_or_used: "This connection expired or was cancelled. Start a new connection on your tablet.",
      };
      const message = messages[reference] || "Sign-in could not be completed. Start again on your tablet.";
      // Only known service codes and fixed stage names reach the browser; never raw
      // Google descriptions, exception text, codes, cookies, or credential values.
      return page("Unable to connect", `<p>${escape(message)}</p><p><small>Reference: ${escape(reference)}<br>Step: ${escape(stage)}</small></p>`, error instanceof HttpError ? error.status : 502, clear);
    }
  }
  async function route(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ status: "ok", protocol: "google-relay-v1" });
    if (request.method === "GET" && url.pathname === "/") return page("reMarkable Calendar", "<p>Connect Google Calendar to your tablet by scanning the QR code shown in Calendar.</p><p>Sign-in links last ten minutes. Start a new connection on your tablet if a link has expired.</p><p><a href='/privacy'>How sign-in data is handled</a></p>");
    if (request.method === "GET" && url.pathname === "/privacy") return page("Sign-in privacy", "<p>This service exchanges your Google authorization code and renews access tokens for Calendar. It receives your email address, granted permissions, and Google tokens during that process. Calendar events sync directly between your tablet and Google; this service does not request your calendar events.</p><p>Pairing records last ten minutes. They contain a hashed tablet polling secret, a temporary OAuth verifier, your email after sign-in, and an encrypted credential grant. Successful delivery deletes the pairing record; expired records are cleaned up regularly. Your tablet retains the encrypted grant for future token renewal.</p><p>The service keeps its OAuth client secret and encryption key in server-side secrets. It does not intentionally log authorization codes or tokens. The hosting provider may process connection metadata and retain infrastructure records or database backups according to its policies.</p><p>You can revoke access in your Google Account's third-party connections. Removing the app from your tablet alone does not revoke Google's authorization.</p>");
    const cfg = config(env);
    if (url.origin !== cfg.origin) throw new HttpError(400, "unexpected_service_origin");
    if (request.method === "POST" && url.pathname === "/v1/pairings") {
      noBrowserOrigin(request);
      await limit(env.PAIRING_LIMIT, request, "create");
      const data = await body(request);
      if (data.provider !== "google") throw new HttpError(400, "unsupported_provider");
      const id = random(), pollSecret = random();
      const codeBytes = crypto.getRandomValues(new Uint8Array(4));
      const userCode = String(new DataView(codeBytes.buffer).getUint32(0) % 1000000).padStart(6, "0");
      await env.DB.prepare("DELETE FROM pairings WHERE expires_at<=?").bind(seconds()).run();
      await env.DB.prepare("INSERT INTO pairings(id,poll_hash,user_code,status,expires_at) VALUES(?,?,?,'pending',?)")
        .bind(id, await hash(pollSecret), userCode, seconds() + SESSION_SECONDS).run();
      return json({ id, poll_secret: pollSecret, user_code: userCode,
        verification_uri: cfg.origin + "/connect/" + id, expires_in: SESSION_SECONDS, interval: 5 }, 201);
    }
    const pairing = url.pathname.match(/^\/v1\/pairings\/([A-Za-z0-9_-]{43})$/);
    if (pairing && ["GET", "DELETE"].includes(request.method)) {
      noBrowserOrigin(request);
      const pollHash = await hash(bearer(request));
      await limit(env.TOKEN_LIMIT, request, "poll");
      if (request.method === "DELETE") {
        const removed = await env.DB.prepare("DELETE FROM pairings WHERE id=? AND poll_hash=? RETURNING id")
          .bind(pairing[1], pollHash).first();
        if (!removed) throw new HttpError(404, "pairing_not_found");
        return json({ status: "cancelled" });
      }
      // DELETE ... RETURNING makes delivery atomic: only one poll can receive credentials.
      const ready = await env.DB.prepare("DELETE FROM pairings WHERE id=? AND poll_hash=? AND status='ready' AND expires_at>? RETURNING grant,email")
        .bind(pairing[1], pollHash, seconds()).first();
      if (ready) return json({ status: "complete", account: { email: ready.email },
        credentials: { type: "google-relay-v1", service_url: cfg.origin, grant: ready.grant } });
      const session = await env.DB.prepare("SELECT status,expires_at FROM pairings WHERE id=? AND poll_hash=?")
        .bind(pairing[1], pollHash).first();
      if (!session) throw new HttpError(404, "pairing_not_found");
      if (session.expires_at <= seconds()) throw new HttpError(410, "pairing_expired");
      return json({ status: session.status === "exchanging" ? "authorizing" : session.status, interval: 5 });
    }
    const connect = url.pathname.match(/^\/connect\/([A-Za-z0-9_-]{43})$/);
    if (connect && ["GET", "POST"].includes(request.method)) {
      const session = await env.DB.prepare("SELECT user_code,status FROM pairings WHERE id=? AND expires_at>?")
        .bind(connect[1], seconds()).first();
      if (!session) throw new HttpError(410, "pairing_expired_or_used");
      if (session.status !== "pending") return page("Sign-in already started", "<p>Return to your tablet to check progress, or start a new connection there.</p>");
      if (request.method === "GET") return page("Connect Google Calendar", `<p>Check that this code matches the one on your tablet:</p><p class="code">${escape(session.user_code)}</p><p>Continue only if you started this connection on your own tablet.</p><form method="post"><button type="submit">Continue with Google</button></form><p><small>Calendar requests permission to read your calendars and create, edit, and delete events. Your calendar events sync directly between the tablet and Google. This service handles sign-in and access-token renewal. <a href="/privacy">Privacy details</a>.</small></p>`, 200, { "Referrer-Policy": "same-origin" });
      if (request.headers.get("Origin") !== cfg.origin) throw new HttpError(403, "origin_required");
      await limit(env.PAIRING_LIMIT, request, "authorize");
      const state = random(), verifier = random(48);
      const started = await env.DB.prepare("UPDATE pairings SET status='authorizing',oauth_hash=?,verifier=? WHERE id=? AND status='pending' AND expires_at>? RETURNING id")
        .bind(await hash(state), verifier, connect[1], seconds()).first();
      if (!started) throw new HttpError(409, "pairing_already_started");
      const authorize = new URL("https://accounts.google.com/o/oauth2/v2/auth");
      authorize.search = new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID, redirect_uri: cfg.callback,
        response_type: "code", scope: SCOPES, access_type: "offline", prompt: "consent select_account",
        state, code_challenge: await hash(verifier), code_challenge_method: "S256" }).toString();
      return new Response(null, { status: 303, headers: { Location: authorize.toString(), "Set-Cookie": cookie(state, cfg.local) } });
    }
    if (request.method === "GET" && url.pathname === "/oauth/google/callback") return callback(request, env, cfg, url);
    if (request.method === "POST" && url.pathname === "/v1/google/token") {
      noBrowserOrigin(request);
      await limit(env.TOKEN_LIMIT, request, "refresh");
      const grant = await unseal(env, (await body(request)).grant);
      const data = await token(env, { refresh_token: grant.refresh_token, grant_type: "refresh_token" });
      if (data.scope && !CALENDAR_SCOPES.every(s => data.scope.split(" ").includes(s))) {
        throw new HttpError(401, "google_reauthorization_required");
      }
      return json({ access_token: data.access_token, token_type: "Bearer", expires_in: data.expires_in });
    }
    throw new HttpError(404, "not_found");
  }
  return {
    async fetch(request, env) {
      try { return secure(await route(request, env)); }
      catch (error) {
        const status = error instanceof HttpError ? error.status : 500;
        const code = error instanceof HttpError ? error.code : "service_error";
        const headers = status === 429 ? { "Retry-After": "60" } : {};
        // Never log request URLs, Google responses, authorization codes, or credentials.
        const html = new URL(request.url).pathname.startsWith("/connect/") || new URL(request.url).pathname === "/oauth/google/callback";
        const explanations = {
          origin_required: "Your browser could not verify this sign-in form. Scan a fresh QR code and open it in your phone's regular browser.",
          pairing_expired_or_used: "This sign-in link has expired or was already used. Start again on your tablet.",
          invalid_oauth_state: "This browser session could not be verified. Start a fresh connection on your tablet and finish sign-in in the same browser.",
          slow_down: "Too many sign-in attempts. Wait a minute, then start again on your tablet.",
          service_not_configured: "The sign-in service setup is incomplete. Contact the service administrator.",
        };
        const explanation = explanations[code] || "This connection could not be completed. Return to your tablet and start again.";
        return secure(html ? page("Connection unavailable", `<p>${escape(explanation)}</p><p><small>Reference: ${escape(code)}</small></p>`, status, headers)
          : json({ error: code }, status, headers));
      }
    },
    async scheduled(_event, env) {
      await env.DB.prepare("DELETE FROM pairings WHERE expires_at<=?").bind(seconds()).run();
    },
  };
}
export default createWorker();
