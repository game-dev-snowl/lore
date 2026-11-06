/**
 * Auth0 Action — trigger: Login / Post Login
 * Name in Auth0: "Lore permissions"
 *
 * Copies the user's Lore permissions from app_metadata into the access token
 * as a top-level "lore_permissions" claim, which loreserver reads
 * (permission_claim = "lore_permissions" in config/local.toml).
 *
 * Set per user in the dashboard: User Management → Users → <user> → Details
 * → Metadata → app_metadata, e.g.
 *   { "lore_permissions": ["read", "write"] }
 * Valid values: read, write, owner, admin, migrate, push-protected,
 * obliterate, presign. Users without it get read only.
 *
 * Runs on interactive login, device-code login and refresh, so a change to
 * app_metadata reaches the user at their next token refresh.
 *
 * Also sets "root_domains": the lore CLI (>= 0.11) only sends a token to a
 * server whose host is in root_domains (or, without that claim, the host of
 * an https "aud"). The server is reached by LAN IP, which isn't the API
 * Identifier's host, so list every host/IP clients use in LORE_HOSTS.
 * An IP matches only exactly; a domain also matches its subdomains.
 *
 * Works on the Auth0 Free plan (no Role Management needed).
 */
const LORE_API = 'https://lore.uzunov.me';
const LORE_HOSTS = ['192.168.1.29', 'lore.uzunov.me'];
const VALID = new Set([
  'read', 'write', 'owner', 'admin', 'migrate', 'push-protected', 'obliterate', 'presign',
]);

exports.onExecutePostLogin = async (event, api) => {
  if (event.resource_server?.identifier !== LORE_API) return;

  api.accessToken.setCustomClaim('root_domains', LORE_HOSTS);

  const perms = event.user.app_metadata?.lore_permissions;
  if (!Array.isArray(perms)) return;

  api.accessToken.setCustomClaim(
    'lore_permissions',
    perms.filter((p) => typeof p === 'string' && VALID.has(p)),
  );
};
