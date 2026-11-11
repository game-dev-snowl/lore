#!/usr/bin/env bash
# Trace why `lore push` fails to authenticate, and say how to fix it.
#
# Client (run inside the working tree that won't push):
#   ./deploy/scripts/trace-auth.sh                  # read-only checks + a traced dry-run push
#   ./deploy/scripts/trace-auth.sh --push           # also run the real push under --log-level trace
#
# Server (run on the server, in /opt/lore/deploy or /opt/lore):
#   ./scripts/trace-auth.sh --server
#
# Everything goes to a report directory (printed at the end). Access tokens are
# never written to it: only their decoded claims (iss, aud, exp, permissions,
# root_domains). Still, read the report before you share it.
set -uo pipefail

MODE=client
REAL_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --server) MODE=server ;;
    --push) REAL_PUSH=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Values from deploy/config/local.toml and deploy/auth0/actions/lore-permissions-login.js.
# Override with env vars if your deployment differs.
EXPECTED_ISS="${EXPECTED_ISS:-https://dev-tke5iflfv7b6gdca.eu.auth0.com/}"
EXPECTED_AUD="${EXPECTED_AUD:-https://lore.uzunov.me}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${TRACE_DIR:-$PWD/lore-auth-trace-$stamp}"
mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: > "$REPORT"

FINDINGS=()
say()     { echo "$*" | tee -a "$REPORT"; }
section() { say ""; say "=== $* ==="; }
finding() { FINDINGS+=("$*"); say "!! $*"; }
# Redact anything shaped like a JWT from a file in place.
redact() { sed -i -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/<JWT redacted>/g' "$1"; }
run() {   # run "label" cmd...: capture combined output to a file and the report
  local label="$1"; shift
  local file="$OUT/$label.log"
  say "\$ $*"
  "$@" >"$file" 2>&1
  local rc=$?
  redact "$file"
  sed 's/^/    /' "$file" | head -n 60 | tee -a "$REPORT"
  say "    (exit $rc, full output: $file)"
  return $rc
}

# ---------------------------------------------------------------------------
if [ "$MODE" = server ]; then
  section "Server: container state"
  run compose-ps docker compose ps
  section "Server: auth lines since last start"
  docker compose logs --no-color loreserver >"$OUT/server-full.log" 2>&1
  redact "$OUT/server-full.log"
  grep -iE 'jwks|oidc|authorizer|Auth:|jwt|issuer|aud|unauth|permission|denied|error|warn' \
    "$OUT/server-full.log" | tail -n 200 >"$OUT/server-auth.log"
  sed 's/^/    /' "$OUT/server-auth.log" | tail -n 60 | tee -a "$REPORT"

  grep -q 'Auth: enabled' "$OUT/server-full.log" \
    || finding "Server log has no 'Auth: enabled': the [server.auth] block isn't loaded. Check config/local.toml on the server and restart."
  grep -q 'No JWT verifier' "$OUT/server-full.log" \
    && finding "Server started without a JWT verifier. [server.auth] is missing or failed; see docs/AUTH0.md step 6."
  grep -qi 'OIDC discovery endpoint returned error' "$OUT/server-full.log" \
    && finding "Server can't reach Auth0 OIDC discovery. Check DNS/egress from the server and jwt_issuer spelling."
  grep -qiE 'iss(uer)?[^a-z]' "$OUT/server-auth.log" && grep -qiE 'invalid|mismatch|reject' "$OUT/server-auth.log" \
    && finding "Server rejects the token issuer. jwt_issuer must match the token's iss exactly, trailing '/' included."
  grep -qiE 'audience|aud[^a-z]' "$OUT/server-auth.log" && grep -qiE 'invalid|mismatch|reject' "$OUT/server-auth.log" \
    && finding "Server rejects the token audience. jwt_audience must equal the Auth0 API Identifier."

  section "Server: can it reach Auth0?"
  run oidc curl -sS --max-time 10 "${EXPECTED_ISS}.well-known/openid-configuration" \
    || finding "Server can't fetch ${EXPECTED_ISS}.well-known/openid-configuration (DNS, egress or TLS)."

  section "Server: clock (token exp/nbf checks depend on it)"
  run date date -u
  command -v timedatectl >/dev/null && run timedatectl timedatectl status
else
# ---------------------------------------------------------------------------
  command -v lore >/dev/null || { echo "lore not found on PATH" >&2; exit 1; }

  section "Client: versions and environment"
  run version lore --version
  say "LORE_AUTH_PATH=${LORE_AUTH_PATH:-<unset>}  LORE_TOKEN=$([ -n "${LORE_TOKEN:-}" ] && echo '<set>' || echo '<unset>')"
  [ -n "${LORE_TOKEN:-}" ] && finding "LORE_TOKEN is set in this shell; it may override your stored login. Try: unset LORE_TOKEN"
  run date date -u

  section "Client: repository remote"
  REMOTE=""
  if [ -f .lore/config.toml ]; then
    REMOTE="$(grep -E '^\s*remote_url\s*=' .lore/config.toml | head -n1 | sed -E 's/.*=\s*"([^"]*)".*/\1/')"
    say "remote_url = ${REMOTE:-<none>}"
  else
    finding "No .lore/config.toml here. Run this script from the root of the working tree that won't push."
  fi
  case "$REMOTE" in
    lore://*) finding "remote_url uses lore:// (no TLS). Tokens go to the server unencrypted, and a host not in root_domains won't get one. Use lores://." ;;
    "") ;;
  esac
  HOST="$(echo "$REMOTE" | sed -E 's#^[a-z]+://##; s#[/:].*##')"
  PORT="$(echo "$REMOTE" | sed -nE 's#^[a-z]+://[^/:]+:([0-9]+).*#\1#p')"; PORT="${PORT:-41337}"

  if [ -n "$HOST" ]; then
    section "Client: reachability of $HOST:$PORT"
    if command -v nc >/dev/null; then
      run tcp nc -z -w 5 "$HOST" "$PORT" || finding "TCP $HOST:$PORT is unreachable. This is a network problem, not auth."
    fi
    if command -v openssl >/dev/null; then
      run tls bash -c "echo | openssl s_client -connect '$HOST:$PORT' -servername '$HOST' 2>&1 | grep -E 'subject=|issuer=|Verify return code|NotAfter'"
      grep -q 'Verify return code: 0' "$OUT/tls.log" \
        || say "    (a self-signed home-LAN CA fails here unless it's in the system store; see HOME-LAN.md section 4)"
    fi
  fi

  section "Client: stored identities"
  run auth-list lore auth list
  run auth-info lore auth info \
    || finding "'lore auth info' failed: no usable login. Run: lore login ${REMOTE%/*}"

  section "Client: access token claims (token itself not saved)"
  TOKEN_RAW="$(lore auth info --with-access-token 2>&1)"
  TOKEN="$(printf '%s' "$TOKEN_RAW" | grep -oE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*' | head -n1)"
  unset TOKEN_RAW
  if [ -z "$TOKEN" ]; then
    finding "No JWT access token for this repository. Either not logged in for this remote, or Auth0 issued an opaque token (Default Audience not set, AUTH0.md step 3). Run: lore login ${REMOTE%/*}"
  elif ! command -v python3 >/dev/null; then
    say "python3 not found; can't decode the token claims."
  else
    printf '%s' "$TOKEN" | python3 -I -c '
import base64, json, sys, time
tok = sys.stdin.read().strip()
p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
keep = {k: c.get(k) for k in ("iss", "aud", "sub", "exp", "iat", "lore_permissions", "root_domains")}
now = int(time.time())
keep["expires_in_s"] = (c.get("exp") or 0) - now
print(json.dumps(keep, indent=2))
' >"$OUT/claims.json" 2>&1
    unset TOKEN
    sed 's/^/    /' "$OUT/claims.json" | tee -a "$REPORT"
    claim() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(json.dumps(v) if not isinstance(v,(str,int)) else v)' "$OUT/claims.json" "$1" 2>/dev/null; }
    ISS="$(claim iss)"; AUD="$(claim aud)"; PERMS="$(claim lore_permissions)"; DOMS="$(claim root_domains)"; LEFT="$(claim expires_in_s)"
    [ "$ISS" = "$EXPECTED_ISS" ] || finding "Token iss is '$ISS', server expects '$EXPECTED_ISS'. Log in again against the right tenant, or fix jwt_issuer."
    echo "$AUD" | grep -qF "$EXPECTED_AUD" || finding "Token aud is '$AUD', not '$EXPECTED_AUD'. Set Auth0 Default Audience (AUTH0.md step 3), then lore login again."
    case "$PERMS" in
      *write*) ;;
      null|""|"[]") finding "Token has no lore_permissions, so you can read but not push. Check the post-login Action is deployed and in the trigger, and app_metadata.lore_permissions includes write; then lore login again." ;;
      *) finding "Token lore_permissions is $PERMS: no 'write', so push is denied. Add write to app_metadata.lore_permissions, then lore login again." ;;
    esac
    if [ -n "$HOST" ] && ! echo "$DOMS" | grep -qF "\"$HOST\""; then
      finding "Host '$HOST' isn't in the token's root_domains ($DOMS), so the CLI won't send the token there. Add it to LORE_HOSTS in the Auth0 Action, then lore login again."
    fi
    if [ -n "$LEFT" ] && [ "$LEFT" -lt 0 ] 2>/dev/null; then
      finding "Cached access token expired $(( -LEFT ))s ago. If the push also fails, refresh isn't working: check Allow Offline Access + Refresh Token grant (AUTH0.md steps 1-2), then lore login again."
    fi
  fi

  section "Client: traced push"
  if [ "$REAL_PUSH" = 1 ]; then
    run push-trace lore --log-level trace push
  else
    run push-trace lore --log-level trace --dry-run push
  fi
  grep -iE 'unauth|permission|denied|forbidden|token|jwt|auth|tls|certificate|disconnected' "$OUT/push-trace.log" \
    | head -n 40 >"$OUT/push-auth-lines.log"
  [ -s "$OUT/push-auth-lines.log" ] && { say "    auth-related lines:"; sed 's/^/      /' "$OUT/push-auth-lines.log" | tee -a "$REPORT"; }
  grep -qi 'names no domain' "$OUT/push-trace.log" && finding "CLI refused to send the token: root_domains doesn't cover this host (see above)."
  grep -qiE 'certificate|UnknownIssuer' "$OUT/push-trace.log" && finding "TLS failure: this machine doesn't trust the server certificate. Install the LAN CA (HOME-LAN.md section 4)."

  section "Client: CLI log file"
  run logfile lore logfile info
  LOGFILE="$(sed -nE 's/.*Location:[^/A-Za-z]*(.*)$/\1/p' "$OUT/logfile.log" | head -n1)"
  if [ -n "$LOGFILE" ] && [ -e "$LOGFILE" ]; then
    tail -n 400 "$LOGFILE" >"$OUT/cli-logfile-tail.log" 2>/dev/null; redact "$OUT/cli-logfile-tail.log"
    say "    last 400 lines copied to $OUT/cli-logfile-tail.log"
  fi
fi

# ---------------------------------------------------------------------------
section "Diagnosis"
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  say "No known cause found. Run with --push on the client, run --server on the server,"
  say "and compare the two report.txt files against the table in deploy/docs/AUTH0.md#troubleshooting."
else
  i=1; for f in "${FINDINGS[@]}"; do say "$i. $f"; i=$((i + 1)); done
fi
say ""
say "Report: $REPORT"
