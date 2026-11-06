/**
 * Auth0 Action — trigger: Machine to Machine / Credentials Exchange
 * Name in Auth0: "Lore permissions (M2M)"
 * Only needed for CI / build machines that log in with a client secret.
 *
 * Copies the M2M application's Lore permissions from its application
 * metadata into the access token as "lore_permissions".
 *
 * Set on the M2M app: Applications → <app> → Settings → Advanced Settings
 * → Application Metadata: key "lore_permissions", value "read,write"
 * (application metadata values are strings, so comma-separated).
 */
const LORE_API = 'https://lore.uzunov.me';
// Hosts the CLI may send this token to; see lore-permissions-login.js.
const LORE_HOSTS = ['192.168.1.29', 'lore.uzunov.me'];
const VALID = new Set([
  'read', 'write', 'owner', 'admin', 'migrate', 'push-protected', 'obliterate', 'presign',
]);

exports.onExecuteCredentialsExchange = async (event, api) => {
  if (event.resource_server?.identifier !== LORE_API) return;

  api.accessToken.setCustomClaim('root_domains', LORE_HOSTS);

  const raw = event.client.metadata?.lore_permissions;
  if (typeof raw !== 'string') return;

  api.accessToken.setCustomClaim(
    'lore_permissions',
    raw.split(',').map((p) => p.trim()).filter((p) => VALID.has(p)),
  );
};
