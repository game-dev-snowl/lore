# Auth0 authentication

This turns on JWT auth on the Lore server with Auth0 as the identity provider. Users sign in with `lore login`. What each user may do comes from the **roles** you assign them in Auth0.

Expect about 15 minutes in the Auth0 dashboard and 5 on the server.

## How it works

```
lore login ──browser──► Auth0 (Native app) ──access token (JWT)──► lore CLI
lore CLI ──lores://…:41337 + token──► loreserver
loreserver: check signature (Auth0 JWKS), iss, aud ─► read "permissions" claim ─► allow/deny
```

| Auth0 role | Permissions in token | Can do |
|---|---|---|
| *(none)* | — | `read` only (clone, list) |
| `lore-dev` | `read`, `write` | clone, push |
| `lore-admin` | `read`, `write`, `admin`, `obliterate` | everything, including admin RPCs and obliterate |

Lore always gives a valid token `read`. `implicit_actions = []` in `config/local.toml` stops it from also giving everyone `write` (the default).

## 1. Create the API (this is the token's audience)

Auth0 dashboard → **Applications → APIs → Create API**

| Field | Value |
|---|---|
| Name | `Lore Server` |
| Identifier | `https://lore.example.com` (your `LORE_DOMAIN` with `https://`; it is only an ID and never fetched) |
| JWT Profile | Auth0 |
| Signing Algorithm | RS256 |

Then, on that API:

1. **Settings → RBAC Settings**: turn on **Enable RBAC** and **Add Permissions in the Access Token**. Save.
2. **Settings → Access Settings**: turn on **Allow Offline Access** (refresh tokens, so users don't sign in every day). Save.
3. **Permissions** tab: add `read`, `write`, `admin`, `obliterate`. These must match Lore's action names exactly.

## 2. Create the Native app (what `lore login` signs in with)

**Applications → Applications → Create Application → Native**. Name it `Lore CLI`.

1. **Settings → Advanced Settings → Grant Types**: tick **Authorization Code**, **Refresh Token**, **Device Code**. Save.
2. Copy the **Client ID**. It goes into `config/local.toml`.
3. Leave **Allowed Callback URLs** empty for now. Step 6 fills it in.

## 3. Set the tenant's default audience

**Settings (tenant) → General → API Authorization Settings → Default Audience** = your API Identifier from step 1.

Lore's docs don't say whether the CLI sends Auth0's `audience` parameter. Without it, Auth0 returns a token the server can't verify. The default audience covers that case.

## 4. Roles and users

**User Management → Roles**:

1. Create `lore-dev`. On its **Permissions** tab add `read`, `write` from `Lore Server`.
2. Create `lore-admin`. Add all four.

**User Management → Users** → pick a user → **Roles** → assign. Give yourself `lore-admin`.

Permission changes reach a user on their next token, so after changing roles they should run `lore login` again.

## 5. Turn it on in the server

On the server, edit `config/local.toml`. Uncomment the Auth0 block and fill in:

| Placeholder | Value |
|---|---|
| `<TENANT>.auth0.com` | your tenant domain, e.g. `my-studio.eu.auth0.com` (copy from the Native app's **Domain**). Keep `https://` and the trailing `/`. |
| `<API_IDENTIFIER>` | the API Identifier from step 1 |
| `<NATIVE_APP_CLIENT_ID>` | the Client ID from step 2 |

```bash
docker compose restart loreserver
docker compose logs --since 2m loreserver | grep -iE 'jwks|oidc|authorizer|Auth:|error'
```

Expect `Resolved jwks_uri through OIDC discovery`, `Repository authorizer: GlobalGrantsAuthorizer` and `Starting Lore GRPC Server: 0.0.0.0:41337, Auth: enabled`. The startup warning `No JWT verifier - Admin Service RPCs including obliterate will be unauthenticated` must be **gone**. The server fetches Auth0's signing keys over HTTPS, so it needs outbound internet access (LAN mode included).

## 6. First login (and the callback URL)

On your machine:

```bash
lore login lores://lore.example.com:41337
```

- **The browser opens and you get a token:** done, go to step 7.
- **Auth0 shows "Callback URL mismatch":** the error page (or the browser's address bar) contains `redirect_uri=…`. URL-decode it, add it exactly to the Native app's **Allowed Callback URLs**, save, and log in again.
- **The redirect port changes every time:** Auth0 needs an exact callback URL. Use `lore login --no-browser lores://lore.example.com:41337` instead, which doesn't need a callback.

## 7. Verify

```bash
lore auth info                                         # signed-in identity
lore repository list lores://lore.example.com:41337    # works with any role
lore repository create lores://lore.example.com:41337/auth-test   # needs write
```

Then check that anonymous access is blocked, from a machine that has never logged in (or after `lore auth logout`):

```bash
lore repository list lores://lore.example.com:41337    # must fail with an auth error
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Every call is rejected and the server logs mention `iss` / issuer | `jwt_issuer` is missing the trailing `/`, or uses a custom domain the token doesn't use. It must match the token's `iss` exactly. |
| Rejected and the logs mention `aud` / audience | `jwt_audience` doesn't match the API Identifier, or step 3 was skipped. |
| Token isn't a JWT (no two dots) / "invalid token" | No audience was sent, so Auth0 issued an opaque token. Do step 3. |
| Logged in but can't push | The user has no `lore-dev`/`lore-admin` role, RBAC's "Add Permissions in the Access Token" is off, or they need to `lore login` again after a role change. |
| Container exits with `Error: Internal Error` right after `OIDC discovery endpoint returned error` | The tenant domain in `jwt_issuer` is wrong, or the host can't reach `https://<TENANT>.auth0.com/.well-known/openid-configuration`. Check the spelling (region suffix like `.eu.`), DNS and egress. |
| Signed out every day | **Allow Offline Access** (step 1) or the **Refresh Token** grant (step 2) is off. |

Inspect a token **locally** (don't paste tokens into websites):

```bash
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{iss, aud, permissions, exp}'
```

## CI / build machines

Create an Auth0 **Machine to Machine** app, authorize it for `Lore Server` with only the permissions it needs, and log in with:

```bash
LORE_CLIENT_SECRET=… lore login --client-id <M2M_CLIENT_ID> lores://lore.example.com:41337
```

Keep the secret in the CI secret store, never on the command line.

## Reference

- Lore server config, Authentication: https://epicgames.github.io/lore/reference/lore-server-config/#authentication
- Auth0 RBAC: https://auth0.com/docs/manage-users/access-control/rbac
