# Google sign-in service

An open-source Cloudflare Worker for connecting reMarkable Calendar to Google from a phone. The Worker serves the phone pages and Google callback, D1 stores short-lived pairing records, and the tablet retains an encrypted credential grant. It targets Workers/D1 free allowances; no paid services are configured.

**Status:** the service and tablet QR connection flow are implemented. Host tests cover pairing, private credential delivery, account confirmation, and compatibility with existing Desktop OAuth credentials. Live service configuration and an end-to-end tablet/phone sign-in still need deployment validation. The existing desktop helper remains supported.

## Connection flow

1. The tablet creates a pairing and keeps its polling secret private.
2. It displays a QR code containing only `verification_uri`, along with a six-digit comparison code.
3. The phone opens that URL. The user checks the comparison code, then chooses Continue with Google.
4. The service starts Google's web authorization flow, using an exact callback URL, browser-bound state, and PKCE. The user chooses an account and grants calendar permissions.
5. The callback exchanges the code, validates calendar scopes and the verified email, and seals the refresh token into an AES-256-GCM credential grant.
6. The tablet polls with its separate secret. One successful claim returns the account email and encrypted grant, deleting the pairing record atomically.
7. The tablet confirms the account to the user and saves the grant with private file permissions. It sends that grant to this service when it needs an access token; calendar API calls go directly to Google.

The QR URL never contains the polling secret, OAuth client secret, or Google credentials. A QR scanner alone cannot retrieve the tablet's credentials. The six-digit code is a visual comparison, not an authentication secret.

### Why token renewal also uses the service

Google's limited-input device flow does not support Calendar scopes. The web flow uses a confidential Web application client; its secret cannot ship in the app. This service therefore performs both initial exchange and later token renewal. It sees Google tokens during those operations but does not fetch calendar events.

The tablet keeps the encrypted grant, not the Web client secret or plaintext Google refresh token. The service does not keep an account/token database after claim. A database record can contain an encrypted grant for the remainder of the pairing's ten-minute lifetime. D1 cleanup runs every ten minutes, with expiration enforced on every operation regardless of cleanup timing.

Existing desktop-generated credentials can still refresh directly against Google; that path must remain supported in the tablet integration. The new relay credential format must not be passed to the old `client_id/client_secret/refresh_token` reader.

## Local development

Requires Node **22+**, npm, and Python 3.11+. Python is used by deployment checks and tests to run the production SQL against real SQLite.

```sh
cd services/google-onboarding
npm ci
npm test
npm run check
npx wrangler d1 migrations apply remarkable-calendar-onboarding --local
```

`npm run check` bundles and validates configuration without deploying. PR checks run tests and this dry run; they do not deploy or need Cloudflare/Google secrets.

For an actual local sign-in test:

1. Create a **Web application** OAuth client in Google Cloud, enable Calendar API, and add your account as a test user if the project is in Testing. This is separate from the existing Desktop app client.
2. Register exactly `http://localhost:8787/oauth/google/callback` as a redirect URI. `http://127.0.0.1:8787/...` is a different URI; use localhost consistently.
3. Set `GOOGLE_CLIENT_ID` in the local Wrangler configuration. `npm run dev` overrides `PUBLIC_ORIGIN` to `http://localhost:8787` for local development; the deployment configuration uses the public hostname.
4. Copy `.dev.vars.example` to `.dev.vars`, add your Web client secret, and generate a fresh encryption key:

   ```sh
   python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
   ```

   Put that value in `.dev.vars` as `TOKEN_ENCRYPTION_KEY`. This file is ignored by git. Do not reuse a production key for testing.
5. Start `npm run dev`. Use the protocol below to create a pairing, then open its `verification_uri` **on the same computer**. Localhost on a phone refers to the phone, so cross-device testing needs a reachable HTTPS deployment.

There is no simulated successful Google sign-in in the deployed Worker. The automated tests mock Google's endpoints; real local browser sign-in requires your own Google client.

## Cloudflare setup, when ready

The configured public origin is **`https://auth.opendev.stream`**. Register this exact Google Web application redirect URI:

```text
https://auth.opendev.stream/oauth/google/callback
```

The callback and returned URLs come only from `PUBLIC_ORIGIN`; OAuth configuration never trusts a phone-supplied redirect URL. `npm run dev` separately overrides the origin to localhost. The hostname must be connected to the deployed Worker with working HTTPS before phone sign-in can work. Setting `PUBLIC_ORIGIN` alone does not configure DNS or a Worker route.

1. Sign into a Cloudflare account on the Workers Free plan with `npx wrangler login`.
2. Create D1: `npx wrangler d1 create remarkable-calendar-onboarding`. Replace the placeholder `database_id` in `wrangler.toml` with the returned ID.
3. Configure the Web OAuth client ID and add `https://auth.opendev.stream/oauth/google/callback` as its authorized redirect URI. The configured `PUBLIC_ORIGIN` has no trailing slash or path. The repository declares a direct Worker custom domain for `auth.opendev.stream`. The `opendev.stream` zone must be active in the Cloudflare account used for deployment. In Google Auth Platform, add `opendev.stream` as an authorized domain; use `https://auth.opendev.stream/` as the app homepage and `https://auth.opendev.stream/privacy` as the privacy-policy URL.
4. Add secrets without committing them:

   ```sh
   npx wrangler secret put GOOGLE_CLIENT_SECRET
   npx wrangler secret put TOKEN_ENCRYPTION_KEY
   ```

   Use a stable random 32-byte base64url encryption key generated as above. Back it up privately. Changing it invalidates existing tablet grants, requiring sign-in again. OAuth client ID changes also require reconnection; client-secret rotation alone does not change the grant format.
5. Apply schema: `npx wrangler d1 migrations apply remarkable-calendar-onboarding --remote`.
6. Deploy the Worker with `npm run deploy`. Wrangler's `custom_domain = true` route connects `auth.opendev.stream` directly to the Worker and lets Cloudflare manage its DNS record and certificate. No Pages project, forwarding service, or manually created CNAME is needed. Its public workers.dev/preview URLs are disabled.
7. Check `https://auth.opendev.stream/health` and the landing/privacy pages after the custom domain is active and HTTPS is ready.
8. Test phone sign-in and tablet polling before inviting users. Public distribution also needs Google's consent-screen/domain verification and a reviewed privacy statement. The built-in `/privacy` page describes this implementation's data handling and needs to match the eventual deployment and provider policies.

Do not enable paid Workers features merely to deploy this service. Free limits can interrupt new sign-ins or renewal when exhausted; local events and cached events remain on the tablet. The service includes per-IP request limits, but they do not guarantee protection from distributed abuse or free-quota exhaustion.

Do not enable request-body, query-string, or OAuth callback URL logging. Application code does not log credentials; Worker observability is disabled in the starter configuration. The hosting provider may retain connection metadata and database backups, so record deletion is not a claim that every infrastructure copy disappears immediately.

## Tablet protocol

All API calls use HTTPS in production, accept no browser Origin header, and return `Cache-Control: no-store`. JSON request bodies are limited to 16 KiB. There is intentionally no CORS access to the native API. Phone pages use browser-bound cookies and origin-checked form submissions.

### Create pairing

`POST /v1/pairings`, `Content-Type: application/json`:

```json
{"provider":"google"}
```

Response `201`:

```json
{
  "id": "opaque-session-id",
  "poll_secret": "private-to-tablet",
  "verification_uri": "https://configured-service/connect/opaque-session-id",
  "user_code": "123456",
  "expires_in": 600,
  "interval": 5
}
```

Store the polling secret in memory only. Encode only `verification_uri` in the QR. Display the comparison code and ten-minute expiration. A reconnect must use a new pairing.

### Poll or cancel

`GET /v1/pairings/{id}`, header `Authorization: Bearer {poll_secret}`. Poll no more often than every five seconds. On `429`, wait at least the `Retry-After` interval.

Waiting statuses are `pending` and `authorizing`; `denied` and `error` end the attempt and should offer retry. HTTP `410` means expired. HTTP `404` means unavailable, already delivered, or a wrong secret; do not keep polling indefinitely.

Successful claim:

```json
{
  "status": "complete",
  "account": {"email":"person@example.com"},
  "credentials": {
    "type":"google-relay-v1",
    "service_url":"https://configured-service",
    "grant":"v1.encrypted-credential-grant"
  }
}
```

Delivery is one-time and atomic. If the claim response is lost, start a new sign-in rather than retrieving it again. Confirm the account on the tablet and save the credential record privately; never expose the grant through the tablet's frontend APIs or logs. Trust the configured service origin; do not accept arbitrary service URLs from imported records without user approval.

`DELETE /v1/pairings/{id}` with the same bearer header cancels a pending connection. It cannot cancel a credential record already delivered. Cancellation and expiration during the Google exchange prevent delivery; the service attempts to revoke a newly issued token if completion fails.

### Renew an access token

`POST /v1/google/token`, `Content-Type: application/json`:

```json
{"grant":"v1.encrypted-credential-grant"}
```

Response:

```json
{"access_token":"short-lived-google-token","token_type":"Bearer","expires_in":3600}
```

Keep the access token in backend memory, and use it directly with Google's Calendar API. A temporary service failure must not erase existing credentials, cached events, or queued edits. `google_reauthorization_required` (`401`) means Google rejected or revoked the underlying refresh token; ask the user to reconnect. `invalid_grant` (`401`) means the supplied relay grant is invalid, tampered with, or belongs to another encryption key/client.

Do not infer Google refresh-token rotation support: Google's normal refresh response does not replace the original refresh token. Other providers may need a stateful rotation design.

### Other endpoints

- `GET /health`: liveness and protocol version; does not claim Google or secrets are configured.
- `GET /`: basic service landing page.
- `GET /privacy`: data-handling description.
- `/connect/{id}` and `/oauth/google/callback`: browser-only phone flow.

Unknown failures return generic error codes, not Google error descriptions or request contents. Only `localhost` and `127.0.0.1` can use HTTP for development; public deployments require HTTPS.

## Tests

Tests exercise the actual Worker and production SQL with SQLite and mock Google responses: permission validation, browser state/PKCE, separate polling authorization, one-time delivery, encryption tampering, cross-client rejection, cancellation, expiry, cleanup, sanitized errors, rate limits, body limits, and token refresh. Wrangler validates the Worker bindings separately. Real Google browser sign-in and a real Cloudflare deployment remain deployment checks.

## References

- [Google's supported device-flow scopes](https://developers.google.com/identity/protocols/oauth2/limited-input-device#allowedscopes)
- [Google web-server OAuth and offline access](https://developers.google.com/identity/protocols/oauth2/web-server)
- [Google brand/domain verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification)
- [Workers free-plan limits](https://developers.cloudflare.com/workers/platform/limits/)
- [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)

The service is covered by the repository's MIT license. Credentials, deployment keys, and local state are excluded from source control.

## Domain ownership and Google verification

`opendev.stream` is the owned parent domain, and `auth.opendev.stream` is the configured service hostname. Hosting now uses a direct [Worker custom domain](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/).

For Google's public-app verification, verify ownership of `opendev.stream` in Google Search Console using its supplied DNS record in Cloudflare. Associate the verified Google account with the Google Cloud project and list `opendev.stream` under authorized domains. Owning the domain satisfies the ownership prerequisite; Google still reviews the consent screen, requested Calendar permissions, and applicable public-app requirements. Keep the project in Testing with explicit test users until ready for public verification.

## Diagnose service_not_configured

The health endpoint checks liveness only. If tablet sign-in reports incomplete service setup, run `npm run diagnose -- --remote` from this directory with Node 22+ and Python 3.11+. It checks local deployment settings and the names of deployed secrets without displaying their values. `npm run deploy` also runs the local configuration check before publishing, so an empty client ID or placeholder database ID cannot silently be deployed.

`GOOGLE_CLIENT_ID` belongs in `[vars]` in `wrangler.toml`; it is public configuration. `GOOGLE_CLIENT_SECRET` and `TOKEN_ENCRYPTION_KEY` belong in Cloudflare secrets. The encryption key must decode to exactly 32 bytes from unpadded base64url text; checking that format requires inspecting it privately, not sharing it. Changes to local configuration take effect only after redeployment.

The phone form uses `Referrer-Policy: same-origin` so its same-origin POST retains a usable `Origin` header. Other responses, including the OAuth callback, use `no-referrer`. Do not set a site-wide header rule that overwrites the form's policy with `no-referrer`: browsers can then submit `Origin: null`, which the service deliberately rejects. Phone error pages include a safe reference code for troubleshooting and never include Google codes or tokens.

After Google consent, a callback failure page includes a safe **Reference** and **Step**. `google_client_credentials_rejected` means the Web client ID and deployed client secret must be checked as a matching pair (do not use the old Desktop client's secret). `google_callback_mismatch` means the redirect URI must exactly match the Web client registration. Other step names distinguish token exchange, verified account lookup, credential encryption, and pairing storage. These diagnostics omit Google's raw response, authorization codes, cookies, and tokens.
