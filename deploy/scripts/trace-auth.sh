#!/usr/bin/env bash
# Trace why `lore push` fails to authenticate, and say how to fix it.
#
# Client: cd to the root of the working tree that won't push, then run
#   <deploy-dir>/scripts/trace-auth.sh          # read-only checks + a traced dry-run push
#   <deploy-dir>/scripts/trace-auth.sh --push   # also run the real push under --log-level trace
# A dry-run push connects and authenticates but skips the upload, so it can't show a
# missing `write` permission. Use --push for that.
#
# Server (any directory; the script finds docker-compose.yml from its own path):
#   /opt/lore/deploy/scripts/trace-auth.sh --server
#
# Output goes to a new temporary directory, printed at the end; set TRACE_DIR to choose one.
# Access tokens are replaced with <JWT redacted> before anything is written, and only their
# decoded claims are kept. Read the report before you share it: it names your user ID.
# Exits 1 when it finds a likely cause.
set -uo pipefail

MODE=client
REAL_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --server) MODE=server ;;
    --push) REAL_PUSH=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# What the server expects, from the server config next to this script. Env vars override it.
toml_first_string() {
  [ -f "$DEPLOY_DIR/config/local.toml" ] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$DEPLOY_DIR/config/local.toml" | head -n1 \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/'
}
EXPECTED_ISS="${EXPECTED_ISS:-$(toml_first_string jwt_issuer)}"
EXPECTED_AUD="${EXPECTED_AUD:-$(toml_first_string jwt_audience)}"

OUT="${TRACE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/lore-auth-trace.XXXXXX")}"
mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: > "$REPORT"

FINDINGS=()
say()     { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { say ""; say "=== $* ==="; }
finding() { FINDINGS+=("$*"); say "!! $*"; }
redact()  { sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/<JWT redacted>/g'; }
with_timeout() { if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi; }
# run LABEL CMD...: output is redacted before it reaches $OUT/LABEL.log, then shown.
run() {
  local label="$1"; shift
  local file="$OUT/$label.log"
  say "\$ $*"
  "$@" 2>&1 | redact >"$file"
  local rc=${PIPESTATUS[0]}
  sed 's/^/    /' "$file" | head -n 60 | tee -a "$REPORT"
  say "    (exit $rc, full output: $file)"
  return "$rc"
}

diagnose() {
  section "Diagnosis"
  if [ "${#FINDINGS[@]}" -eq 0 ]; then
    say "No known cause found. Run --server on the server too, and compare both reports"
    say "with the table in deploy/docs/AUTH0.md#troubleshooting."
  else
    local i=1 f
    for f in "${FINDINGS[@]}"; do say "$i. $f"; i=$((i + 1)); done
  fi
  say ""
  say "Report: $REPORT"
  [ "${#FINDINGS[@]}" -eq 0 ] && exit 0
  exit 1
}

# Flags stored logins whose `Expires:` time in `lore auth list` has passed. A login past it
# can no longer be refreshed, so every call that needs a token fails until `lore login`.
check_auth_list() {
  run auth-list lore auth list
  command -v python3 >/dev/null || return 0
  local expired
  expired="$(python3 -I -c '
import sys, time
from email.utils import parsedate_to_datetime
n = 0
for line in open(sys.argv[1]):
    k, _, v = line.strip().partition(":")
    if k == "Expires":
        try:
            if parsedate_to_datetime(v.strip()).timestamp() < time.time():
                n += 1
        except (TypeError, ValueError):
            pass
print(n)
' "$OUT/auth-list.log" 2>/dev/null)"
  if [ "${expired:-0}" -gt 0 ]; then
    finding "$expired stored login(s) in 'lore auth list' are past their Expires time, so the CLI can't refresh them and every authenticated call fails. Log in again: lore login ${1:-<lores://server:41337>}"
  fi
}

# ---------------------------------------------------------------------------
if [ "$MODE" = server ]; then
  cd "$DEPLOY_DIR" || exit 1
  section "Server: container state ($DEPLOY_DIR)"
  run compose-ps docker compose ps || { say "docker compose failed; run as a user in the docker group."; exit 1; }

  section "Server: auth log lines since the container last started"
  CID="$(docker compose ps -q loreserver 2>/dev/null)"
  [ -n "$CID" ] || { say "No loreserver container. Start it with: docker compose up -d"; exit 1; }
  STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$CID")"
  say "started at $STARTED"
  docker compose logs --no-color --since "$STARTED" loreserver 2>&1 | redact >"$OUT/server-full.log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || { say "docker compose logs failed:"; cat "$OUT/server-full.log"; exit 1; }
  grep -iE 'jwks|oidc|authorizer|Auth:|JWT|unauthenticated|permission denied' \
    "$OUT/server-full.log" | tail -n 200 >"$OUT/server-auth.log"
  sed 's/^/    /' "$OUT/server-auth.log" | tail -n 60 | tee -a "$REPORT"

  grep -q 'Auth: enabled' "$OUT/server-full.log" \
    || finding "Server didn't log 'Auth: enabled' at its last start: [server.auth] isn't loaded. Check config/local.toml on the server, then: docker compose restart loreserver"
  grep -q 'No JWT verifier' "$OUT/server-full.log" \
    && finding "Server started without a JWT verifier: [server.auth] is missing or failed. See docs/AUTH0.md step 6."
  grep -qi 'OIDC discovery endpoint returned error' "$OUT/server-full.log" \
    && finding "Server couldn't reach Auth0 OIDC discovery at start. Check jwt_issuer spelling, DNS and egress."
  # A rejected token logs one line, with the jsonwebtoken error kind in it.
  REJECTS="$(grep 'Unexpected error decoding JWT token' "$OUT/server-full.log")"
  case "$REJECTS" in *InvalidIssuer*)
    finding "Server rejects tokens for their issuer. jwt_issuer must equal the token's iss exactly, trailing '/' included." ;; esac
  case "$REJECTS" in *InvalidAudience*)
    finding "Server rejects tokens for their audience. jwt_audience must equal the Auth0 API Identifier." ;; esac
  case "$REJECTS" in *InvalidSignature*|*InvalidKeyFormat*|*InvalidAlgorithm*)
    finding "Server rejects token signatures: the token isn't from the tenant in jwt_issuer, or the signing keys rotated. Log in again; restart loreserver if it persists." ;; esac
  case "$REJECTS" in *ImmatureSignature*)
    finding "Server rejects tokens as not yet valid: the server clock is behind. Check the clock below." ;; esac
  say "(Expired tokens are logged only at debug level, so they don't show here.)"

  section "Server: can this host reach Auth0? (the container's egress can differ)"
  if [ -n "$EXPECTED_ISS" ]; then
    run oidc curl -sS --max-time 10 "${EXPECTED_ISS%/}/.well-known/openid-configuration" \
      || finding "This host can't fetch ${EXPECTED_ISS%/}/.well-known/openid-configuration (DNS, egress or TLS)."
  fi

  section "Server: clock (token exp and nbf checks depend on it)"
  run date date -u
  command -v timedatectl >/dev/null && run timedatectl timedatectl status
else
# ---------------------------------------------------------------------------
  command -v lore >/dev/null || { echo "lore not found on PATH" >&2; exit 1; }

  section "Client: version and environment"
  run version lore --version
  for v in LORE_ACCESS_TOKEN LORE_IDENTITY_TOKEN LORE_AUTH_MODE LORE_AUTH_PATH; do
    if [ -n "${!v:-}" ]; then say "$v is set"; else say "$v is unset"; fi
  done
  [ -n "${LORE_ACCESS_TOKEN:-}${LORE_IDENTITY_TOKEN:-}" ] \
    && finding "LORE_ACCESS_TOKEN or LORE_IDENTITY_TOKEN is set; every command uses it instead of your stored login. If it's stale: unset LORE_ACCESS_TOKEN LORE_IDENTITY_TOKEN (and remove it from your shell profile)."
  [ -n "${LORE_AUTH_PATH:-}" ] \
    && say "    LORE_AUTH_PATH points the CLI at another token store; a login made without it isn't seen."
  run date date -u

  section "Client: repository remote"
  # pipefail makes the assignment fail when lore does; it prints its error on stdout.
  REMOTE="$(lore repository config get remote_url 2>/dev/null | tail -n1)" || REMOTE=""
  if [ -z "$REMOTE" ] && [ -f .lore/config.toml ]; then
    REMOTE="$(grep -E '^[[:space:]]*remote_url[[:space:]]*=' .lore/config.toml | head -n1 | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
  fi
  say "remote_url = ${REMOTE:-<none>}"
  if [ -z "$REMOTE" ]; then
    finding "No remote_url here ($PWD is not a Lore working tree). cd to the root of the working tree that won't push and run this script by its path. The connection, token and push checks were skipped because they need the repository."
    section "Client: stored identities"
    check_auth_list
    diagnose
  fi
  case "$REMOTE" in lore://*)
    finding "remote_url uses lore://, which sends tokens without TLS. Use lores:// for this server." ;; esac
  SCHEME="${REMOTE%%://*}"
  AUTHORITY="${REMOTE#*://}"; AUTHORITY="${AUTHORITY%%/*}"
  case "$AUTHORITY" in
    \[*) HOST="${AUTHORITY#[}"; HOST="${HOST%%]*}"; PORT="${AUTHORITY##*]:}"; [ "$PORT" = "$AUTHORITY" ] && PORT="" ;;
    *:*) HOST="${AUTHORITY%%:*}"; PORT="${AUTHORITY##*:}" ;;
    *)   HOST="$AUTHORITY"; PORT="" ;;
  esac
  PORT="${PORT:-41337}"
  SERVER_URL="$SCHEME://$AUTHORITY"

  if [ -n "$HOST" ]; then
    section "Client: reachability of $HOST:$PORT"
    if run tcp with_timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2" && echo connected' _ "$HOST" "$PORT"; then
      if command -v openssl >/dev/null; then
        run tls with_timeout 10 bash -c \
          'echo | openssl s_client -connect "$1:$2" -servername "$1" 2>&1 | grep -E "subject=|issuer=|Verify return code"' \
          _ "$HOST" "$PORT"
        grep -q 'Verify return code: 0' "$OUT/tls.log" \
          || say "    (openssl doesn't trust this certificate. Expected for the home-LAN CA unless it's in the system store; if the push below fails with a certificate error, see HOME-LAN.md section 4.)"
      fi
    else
      finding "Can't open a TCP connection to $HOST:$PORT. This is a network problem, not auth: check the server is up and the address is right."
    fi
  fi

  section "Client: stored identities"
  check_auth_list "$SERVER_URL"
  run auth-info lore auth info \
    || finding "'lore auth info' failed: no usable stored login. Run: lore login $SERVER_URL"

  section "Client: access token claims (the token itself isn't saved)"
  TOKEN_OUT="$(lore auth info --with-access-token 2>&1)"; TOKEN_RC=$?
  TOKEN="$(printf '%s' "$TOKEN_OUT" | grep -oE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*' | head -n1)"
  if [ "$TOKEN_RC" -ne 0 ]; then
    finding "Couldn't get an access token for this repository: $(printf '%s' "$TOKEN_OUT" | redact | tail -n 3 | tr '\n' ' ') — if this is an auth error, run: lore login $SERVER_URL"
  elif [ -z "$TOKEN" ]; then
    if printf '%s' "$TOKEN_OUT" | grep -qi 'access token'; then
      finding "The access token isn't a JWT: Auth0 issued an opaque token because no audience was sent. Set the tenant's Default Audience (AUTH0.md step 3), then: lore login $SERVER_URL"
    else
      finding "No access token stored for this repository. Run: lore login $SERVER_URL"
    fi
  elif ! command -v python3 >/dev/null; then
    say "python3 not found; can't decode the token claims."
  else
    # The token goes on stdin; argv is visible to other users.
    printf '%s' "$TOKEN" | python3 -I -c '
import base64, json, sys, time, urllib.parse
host, want_iss, want_aud = sys.argv[1:4]
p = sys.stdin.read().strip().split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
aud = c.get("aud") or []
aud = [aud] if isinstance(aud, str) else aud
# Same rule as lore-credential acceptable_root_domains / domain_in_root_domains.
roots = [d for k in ("root_domains", "https://lore.org/claims/root_domains")
         for d in ([c[k]] if isinstance(c.get(k), str) else c.get(k) or []) if d]
if not roots:
    roots = [urllib.parse.urlparse(a).hostname for a in aud if a.startswith("https://")]
    roots = [r for r in roots if r]
ok = any(host == r.lstrip(".") or host.endswith("." + r.lstrip(".")) for r in roots)
perms = c.get("lore_permissions") or []
perms = perms.split(",") if isinstance(perms, str) else perms
out = {k: c.get(k) for k in ("iss", "aud", "sub", "exp", "lore_permissions", "root_domains")}
out["expires_in_s"] = (c.get("exp") or 0) - int(time.time())
out["domains_token_may_go_to"] = roots
print(json.dumps(out, indent=2))
issues = []
iss = c.get("iss")
if want_iss and c.get("iss") != want_iss:
    issues.append(f"Token iss is {iss!r}, server expects {want_iss!r}. Log in again against the right tenant, or fix jwt_issuer.")
if want_aud and want_aud not in aud:
    issues.append(f"Token aud is {aud}, not {want_aud!r}. Set the Auth0 Default Audience (AUTH0.md step 3), then log in again.")
if "write" not in [x.strip() for x in perms]:
    issues.append(f"Token lore_permissions is {perms}: no write, so push is denied. Check the post-login Action is deployed and in the trigger, and app_metadata.lore_permissions includes write; then log in again.")
if host and not ok:
    issues.append(f"Host {host!r} is not covered by the domains the token may be sent to ({roots}), so the CLI withholds it. Add the host to LORE_HOSTS in the Auth0 Action, then log in again.")
for i in issues:
    print("FINDING\t" + i, file=sys.stderr)
' "$HOST" "$EXPECTED_ISS" "$EXPECTED_AUD" >"$OUT/claims.json" 2>"$OUT/claims-findings.txt"
    DECODE_RC=$?
    unset TOKEN TOKEN_OUT
    if [ "$DECODE_RC" -ne 0 ]; then
      say "Couldn't decode the token claims (not a plain JWS?):"; redact <"$OUT/claims-findings.txt" | tail -n 3 | tee -a "$REPORT"
    else
      sed 's/^/    /' "$OUT/claims.json" | tee -a "$REPORT"
      while IFS=$'\t' read -r tag msg; do
        [ "$tag" = FINDING ] && finding "$msg"
      done <"$OUT/claims-findings.txt"
    fi
  fi
  unset TOKEN TOKEN_OUT

  section "Client: traced push"
  if [ "$REAL_PUSH" = 1 ]; then
    run push-trace lore --log-level trace push; PUSH_RC=$?
  else
    run push-trace lore --log-level trace --dry-run push; PUSH_RC=$?
  fi
  grep -iE 'unauthenticated|permission|denied|forbidden|names no domain|certificate|UnknownIssuer|not connected|disconnected|token exchange' \
    "$OUT/push-trace.log" | head -n 40 >"$OUT/push-auth-lines.log"
  if [ -s "$OUT/push-auth-lines.log" ]; then
    say "    auth-related lines:"; sed 's/^/      /' "$OUT/push-auth-lines.log" | tee -a "$REPORT"
  fi
  grep -qi 'names no domain' "$OUT/push-trace.log" \
    && finding "The CLI withheld the token: it names no domain covering this host. Add the host to LORE_HOSTS in the Auth0 Action, then: lore login $SERVER_URL"
  grep -qiE 'certificate|UnknownIssuer' "$OUT/push-trace.log" \
    && finding "TLS failure: this machine doesn't trust the server certificate. Install the LAN CA (HOME-LAN.md section 4)."
  if [ "$REAL_PUSH" = 0 ] && [ "$PUSH_RC" -eq 0 ]; then
    finding "The dry-run push authenticated, but a dry run doesn't upload, so it can't show a missing write permission or a protected branch. Rerun with --push."
  fi

  section "Client: CLI log file"
  run logfile lore logfile info
  LOGFILE="$(sed -nE 's/.*Location:[^/A-Za-z]*(.*)$/\1/p' "$OUT/logfile.log" | head -n1)"
  if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
    tail -n 400 "$LOGFILE" 2>/dev/null | redact >"$OUT/cli-logfile-tail.log"
    say "    last 400 lines copied to $OUT/cli-logfile-tail.log"
  fi
fi

# ---------------------------------------------------------------------------
diagnose
