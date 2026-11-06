# Auth0 authentication

This turns on JWT auth on the Lore server with Auth0 as the identity provider. Users sign in with `lore login`. What each user may do comes from a `lore_permissions` list in their Auth0 **app_metadata**, which an Auth0 Action copies into the access token.

Everything here works on the **Auth0 Free plan**. It does not use Auth0 Roles: "Role Management" is a paid feature and stops being available when the trial ends.

This repo is configured for:

| | |
|---|---|
| Tenant | `dev-tke5iflfv7b6gdca.eu.auth0.com` |
| API Identifier (audience) | `https://lore.uzunov.me` |
| Native app Client ID | `d47zg7pidwjME1Vr6btZaAj7u58NLaJj` |

Expect about 15 minutes in the Auth0 dashboard and 5 on the server. Commands below use `lores://lore.uzunov.me:41337`; replace it with your server URL if that's different.

## How it works

```
lore login ──browser──► Auth0 (Native app) ──► Post Login Action: app_metadata.lore_permissions
                                                  └─► access token (JWT) with "lore_permissions" claim
lore CLI ──lores://…:41337 + token──► loreserver
loreserver: check signature (Auth0 JWKS), iss, aud ─► read "lore_permissions" ─► allow/deny
```

| `app_metadata` | Can do |
|---|---|
| *(nothing)* | `read` only (clone, list) |
| `{"lore_permissions": ["read", "write"]}` | clone, push |
| `{"lore_permissions": ["read", "write", "admin", "obliterate"]}` | everything, including admin RPCs and obliterate |

Other valid values: `owner`, `migrate`, `push-protected`, `presign`. Anything else is dropped by the Action.

Lore always gives a valid token `read`. `implicit_actions = []` in `config/local.toml` stops it from also giving everyone `write` (the default).

## 1. Create the API (this is the token's audience)

Auth0 dashboard → **Applications → APIs → Create API**

| Field | Value |
|---|---|
| Name | `Lore Server` |
| Identifier | `https://lore.uzunov.me` (an ID only; never fetched) |
| JWT Profile | Auth0 |
| Signing Algorithm | RS256 |

Then **Settings → Access Settings**: turn on **Allow Offline Access** (refresh tokens, so users don't sign in every day). Save.

RBAC settings and the API's Permissions tab are **not** used. Leave them off.

## 2. Create the Native app (what `lore login` signs in with)

**Applications → Applications → Create Application → Native**. Name it `Lore CLI`.

1. **Settings → Advanced Settings → Grant Types**: tick **Authorization Code**, **Refresh Token**, **Device Code**. Save.
2. Copy the **Client ID**. It goes into `config/local.toml`.
3. Leave **Allowed Callback URLs** empty for now. Step 7 fills it in.

## 3. Set the tenant's default audience

**Settings (tenant) → General → API Authorization Settings → Default Audience** = `https://lore.uzunov.me`.

Lore's docs don't say whether the CLI sends Auth0's `audience` parameter. Without it, Auth0 returns a token the server can't verify. The default audience covers that case.

## 4. Add the login Action

**Actions → Library → Create Action → Build from scratch**

| Field | Value |
|---|---|
| Name | `Lore permissions` |
| Trigger | Login / Post Login |
| Runtime | the default (Node 22 or newer) |

1. Replace the code with the contents of [`auth0/actions/lore-permissions-login.js`](../auth0/actions/lore-permissions-login.js). If your API Identifier isn't `https://lore.uzunov.me`, change `LORE_API` at the top.
2. Click **Deploy**.
3. **Actions → Triggers → post-login**: drag `Lore permissions` from the right-hand panel into the flow, between Start and Complete. Click **Apply**.

The Action only touches tokens for the Lore API. It runs on browser login, device-code login and token refresh.

## 5. Give users permissions

**User Management → Users** → pick a user → **Details** → **Metadata** → **app_metadata**:

```json
{ "lore_permissions": ["read", "write", "admin", "obliterate"] }
```

Click **Save**. Give yourself the full list above, and give developers `["read", "write"]`.

Use **app_metadata**, not user_metadata. Users can edit their own user_metadata, so they could grant themselves permissions.

A change reaches the user on their next token refresh, or right away if they run `lore login` again.

## 6. Turn it on in the server

`config/local.toml` already has the block enabled with the values at the top of this page. For a different tenant, change `jwt_issuer` (keep `https://` and the trailing `/`), `jwt_audience` and `client_id`.

```bash
cd /opt/lore && git pull
docker compose restart loreserver
docker compose logs --since 2m loreserver | grep -iE 'jwks|oidc|authorizer|Auth:|error'
```

Expect `Resolved jwks_uri through OIDC discovery`, `Repository authorizer: GlobalGrantsAuthorizer` and `Starting Lore GRPC Server: 0.0.0.0:41337, Auth: enabled`. The startup warning `No JWT verifier - Admin Service RPCs including obliterate will be unauthenticated` must be **gone**. The server fetches Auth0's signing keys over HTTPS, so it needs outbound internet access (LAN mode included).

## 7. First login (and the callback URL)

On your machine:

```bash
lore login lores://lore.uzunov.me:41337
```

- **The browser opens and you get a token:** done, go to step 8.
- **Auth0 shows "Callback URL mismatch":** the error page (or the browser's address bar) contains `redirect_uri=…`. URL-decode it, add it exactly to the Native app's **Allowed Callback URLs**, save, and log in again.
- **The redirect port changes every time:** Auth0 needs an exact callback URL. Use `lore login --no-browser lores://lore.uzunov.me:41337` instead, which doesn't need a callback.

## 8. Verify

```bash
lore auth info                                                  # signed-in identity
lore repository list lores://lore.uzunov.me:41337               # works for any signed-in user
lore repository create lores://lore.uzunov.me:41337/auth-test   # needs write
```

Then check that anonymous access is blocked, from a machine that has never logged in (or after `lore auth logout`):

```bash
lore repository list lores://lore.uzunov.me:41337    # must fail with an auth error
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Every call is rejected and the server logs mention `iss` / issuer | `jwt_issuer` is missing the trailing `/`, or uses a custom domain the token doesn't use. It must match the token's `iss` exactly. |
| Rejected and the logs mention `aud` / audience | `jwt_audience` doesn't match the API Identifier, or step 3 was skipped. |
| Token isn't a JWT (no two dots) / "invalid token" | No audience was sent, so Auth0 issued an opaque token. Do step 3. |
| Logged in but can't push | The token has no `lore_permissions` (decode it, below). Check: the Action is **deployed and added to the post-login trigger** (step 4), `LORE_API` in the Action matches the API Identifier, the list is in **app_metadata** (not user_metadata), and the user logged in again after the change. |
| Container exits with `Error: Internal Error` right after `OIDC discovery endpoint returned error` | The tenant domain in `jwt_issuer` is wrong, or the host can't reach `https://dev-tke5iflfv7b6gdca.eu.auth0.com/.well-known/openid-configuration`. Check the spelling (region suffix like `.eu.`), DNS and egress. |
| Signed out every day | **Allow Offline Access** (step 1) or the **Refresh Token** grant (step 2) is off. |

The Action's runs and errors show under **Monitoring → Logs** (look for "Success Login" and open the Action details).

Inspect a token **locally** (don't paste tokens into websites):

```bash
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{iss, aud, lore_permissions, exp}'
```

## CI / build machines

Free plan: 1,000 machine-to-machine tokens per month.

1. **Applications → Create Application → Machine to Machine**, authorize it for `Lore Server`.
2. On that app: **Settings → Advanced Settings → Application Metadata**: key `lore_permissions`, value `read,write` (a comma-separated string; app metadata values can't be lists).
3. **Actions → Library → Create Action**: name `Lore permissions (M2M)`, trigger **Machine to Machine / Credentials Exchange**, code from [`auth0/actions/lore-permissions-m2m.js`](../auth0/actions/lore-permissions-m2m.js). Deploy, then add it under **Actions → Triggers → credentials-exchange**.
4. Log in on the CI machine:

```bash
LORE_CLIENT_SECRET=… lore login --client-id <M2M_CLIENT_ID> lores://lore.uzunov.me:41337
```

Keep the secret in the CI secret store, never on the command line.

## Reference

- Lore server config, Authentication: https://epicgames.github.io/lore/reference/lore-server-config/#authentication
- Auth0 Actions, post-login `api.accessToken.setCustomClaim`: https://auth0.com/docs/customize/actions/explore-triggers/signup-and-login-triggers/login-trigger/post-login-api-object
- Auth0 pricing (Role Management not on Free): https://auth0.com/pricing
