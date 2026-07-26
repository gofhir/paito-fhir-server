#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# SMART on FHIR / OAuth2 — runnable walkthrough
# ══════════════════════════════════════════════════════════════════════════════
# Derived from go-fhir-server scripts/e2e-security-smoke.sh. Exercises:
#   discovery + JWKS · anonymous 401 · client_credentials JWT · introspection ·
#   scope enforcement (write + cross-type) · no-scope 403 ·
#   authorization_code + consent + PKCE S256 + id_token + refresh_token +
#   patient launch context · SMART v2 granular sub-scope · Backend Services
#   private_key_jwt (RFC 7523) · AuditEvent trail.
#
# Launch the stack first:
#   docker compose -f docker-compose.smart-auth.yml up -d
#
# Then:
#   bash run.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

FHIR_BASE="${BASE_URL:-http://localhost:3500/fhir/r4}"
ISS_BASE="${ISS_BASE:-http://localhost:3500}"
ADMIN_URL="${ADMIN_URL:-http://localhost:3501}"
ADMIN_KEY="${ADMIN_API_KEY:-paito-smart-admin-key}"

# Demo clients (seeded via GitOps from config/clients.smart-auth.yaml).
CLIENT_FULL=demo-full;     SECRET_FULL=demo-full-secret-do-not-use-in-prod
CLIENT_RO=demo-readonly;   SECRET_RO=demo-readonly-secret-do-not-use-in-prod
CLIENT_NS=demo-noscope;    SECRET_NS=demo-noscope-secret-do-not-use-in-prod
CLIENT_GRAN=demo-granular; SECRET_GRAN=demo-granular-secret-do-not-use-in-prod
CLIENT_BACKEND=demo-backend
CLIENT_APP=demo-app;       SECRET_APP=demo-app-secret-do-not-use-in-prod
APP_REDIRECT="http://localhost:9999/callback"
LOGIN_USER=demo-user;      LOGIN_PASS=demo-user-pass-do-not-use-in-prod
JWKS_PORT=9443

hdr()  { printf "\n\033[1;36m═══ %s ═══\033[0m\n" "$1"; }
sub()  { printf "\033[1m── %s\033[0m\n" "$1"; }
ok()   { printf "\033[32m✔\033[0m %s\n" "$1"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$1" >&2; }

decode_jwt() {
  python3 -c "
import sys,base64,json
p=sys.argv[1].split('.')
pad=p[1]+'='*(4-len(p[1])%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(pad)),indent=2))" "$1"
}
urlenc() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"; }

get_token() { # client secret scope -> RESP_TOKEN, RESP_BODY
  RESP_BODY=$(curl -s -X POST "$ISS_BASE/auth/token" -u "$1:$2" \
    -d "grant_type=client_credentials&scope=$3")
  RESP_TOKEN=$(echo "$RESP_BODY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
hdr "Pre-flight"
curl -fsS --max-time 5 "$FHIR_BASE/metadata" >/dev/null \
  && ok "FHIR endpoint responding at $FHIR_BASE" \
  || { fail "stack not reachable — run: docker compose -f docker-compose.smart-auth.yml up -d"; exit 1; }

# ── 1. SMART discovery + JWKS ─────────────────────────────────────────────────
hdr "1. SMART discovery + JWKS"
sub "GET /.well-known/smart-configuration"
curl -s "$ISS_BASE/.well-known/smart-configuration" \
  | python3 -m json.tool | sed 's/^/    /' | head -40
sub "GET /.well-known/jwks.json (server signing keys, RS384)"
curl -s "$ISS_BASE/.well-known/jwks.json" | python3 -m json.tool | sed 's/^/    /'

# ── 2. Anonymous request rejected ─────────────────────────────────────────────
hdr "2. Anonymous request → 401 OperationOutcome"
S=$(curl -s -o /tmp/pa-401.json -w '%{http_code}' "$FHIR_BASE/Patient")
[[ "$S" == "401" ]] && ok "GET /Patient without token → 401" || fail "expected 401, got $S"
grep -q '"code":"login"' /tmp/pa-401.json && ok "issue.code=login (FHIR IssueType for auth required)" || true

# ── 3. client_credentials grant → JWT ─────────────────────────────────────────
hdr "3. client_credentials grant (Backend / server-to-server)"
sub "wrong secret → 401 invalid_client"
BAD=$(curl -s -X POST "$ISS_BASE/auth/token" -u "$CLIENT_FULL:wrong" \
  -d "grant_type=client_credentials&scope=system/*.cruds" -w '\n%{http_code}')
echo "    ${BAD##*$'\n'} · $(echo "${BAD%$'\n'*}" | head -c 120)"
sub "correct credentials → 200 + access_token (JWT)"
get_token "$CLIENT_FULL" "$SECRET_FULL" "system/*.cruds"
[[ -n "$RESP_TOKEN" ]] && ok "access_token issued (len=${#RESP_TOKEN})" || { fail "no token: $RESP_BODY"; exit 1; }
TOKEN_FULL="$RESP_TOKEN"
sub "decoded JWT payload"
decode_jwt "$TOKEN_FULL" | sed 's/^/    /'

# ── 4. Token introspection (RFC 7662) ─────────────────────────────────────────
hdr "4. Token introspection (RFC 7662)"
sub "POST /auth/introspect with valid token → active=true"
curl -s -X POST "$ISS_BASE/auth/introspect" -u "$CLIENT_FULL:$SECRET_FULL" \
  -d "token=$TOKEN_FULL" | python3 -m json.tool | sed 's/^/    /'

# ── 5. Scope enforcement (write privilege) ────────────────────────────────────
hdr "5. Scope enforcement — system/*.cruds writes, system/Patient.rs cannot"
sub "demo-full creates a Patient → 201"
S=$(curl -s -o /tmp/pa-p.json -w '%{http_code}' -X POST "$FHIR_BASE/Patient" \
  -H "Authorization: Bearer $TOKEN_FULL" -H 'Content-Type: application/fhir+json' \
  --data-binary @patient.json)
[[ "$S" == "201" ]] && ok "POST Patient → 201" || fail "expected 201, got $S"
PID=$(python3 -c "import json;print(json.load(open('/tmp/pa-p.json'))['id'])")
ok "created Patient/$PID"

sub "demo-readonly reads it → 200"
get_token "$CLIENT_RO" "$SECRET_RO" "system/Patient.rs"; TOKEN_RO="$RESP_TOKEN"
S=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN_RO" "$FHIR_BASE/Patient/$PID")
[[ "$S" == "200" ]] && ok "GET Patient/$PID → 200" || fail "expected 200, got $S"

sub "demo-readonly tries to CREATE → 403 (forbidden, NOT 401)"
S=$(curl -s -o /tmp/pa-403.json -w '%{http_code}' -X POST "$FHIR_BASE/Patient" \
  -H "Authorization: Bearer $TOKEN_RO" -H 'Content-Type: application/fhir+json' \
  --data-binary @patient.json)
[[ "$S" == "403" ]] && ok "POST blocked → 403" || fail "expected 403, got $S"
grep -q 'insufficient scope' /tmp/pa-403.json && ok "diagnostic: 'insufficient scope'" || true

sub "demo-readonly reads Observation (out of scope) → 403"
S=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN_RO" "$FHIR_BASE/Observation?_count=1")
[[ "$S" == "403" ]] && ok "cross-type read → 403 (Patient.rs does not cover Observation)" || fail "expected 403, got $S"

# ── 6. No-scope token cannot read ─────────────────────────────────────────────
hdr "6. No-scope token → 403 on read"
get_token "$CLIENT_NS" "$SECRET_NS" ""; TOKEN_NS="$RESP_TOKEN"
[[ -n "$TOKEN_NS" ]] && ok "token issued (RFC 6749 allows it — access is checked at the FHIR endpoint)" || true
S=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN_NS" "$FHIR_BASE/Patient/$PID")
[[ "$S" == "403" ]] && ok "GET /Patient with empty scope → 403" || fail "expected 403, got $S"

# ── 7. authorization_code + consent + PKCE + refresh + launch context ─────────
hdr "7. Authorization Code flow (consent + PKCE S256 + patient context)"
APP_SCOPE="openid fhirUser offline_access launch/patient patient/Patient.read"
APP_PID=$(curl -s -X POST "$FHIR_BASE/Patient" -H "Authorization: Bearer $TOKEN_FULL" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","name":[{"family":"SmartAppLaunch"}]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "seeded launch-context Patient/$APP_PID"

read PKCE_V PKCE_C < <(python3 -c "
import secrets,hashlib,base64
v=base64.urlsafe_b64encode(secrets.token_bytes(40)).rstrip(b'=').decode()
c=base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()
print(v,c)")
ok "PKCE verifier + S256 challenge generated"

AUTHZ="/auth/authorize?response_type=code&client_id=$CLIENT_APP&redirect_uri=$(urlenc "$APP_REDIRECT")&scope=$(urlenc "$APP_SCOPE")&state=st-demo&aud=$(urlenc "$FHIR_BASE")&code_challenge=$PKCE_C&code_challenge_method=S256"
sub "login → session cookie"
COOKIE=$(curl -s -D - -o /dev/null -X POST "$ISS_BASE/auth/login" \
  --data-urlencode "username=$LOGIN_USER" --data-urlencode "password=$LOGIN_PASS" \
  --data-urlencode "return_to=$AUTHZ" \
  | grep -i 'set-cookie:' | sed -E 's/.*auth_session=([^;]+).*/\1/' | head -1)
[[ -n "$COOKIE" ]] && ok "authenticated, got auth_session cookie" || { fail "login failed"; exit 1; }

sub "GET /auth/authorize → consent page (extract CSRF token)"
curl -s -o /tmp/pa-consent.html -H "Cookie: auth_session=$COOKIE" "$ISS_BASE$AUTHZ"
CSRF=$(grep -oE 'name="csrf_token" value="[^"]+"' /tmp/pa-consent.html | sed -E 's/.*value="([^"]+)".*/\1/')
ok "consent page rendered, CSRF token captured"

sub "POST /auth/authorize action=approve → 302 redirect with code"
LOC=$(curl -s -D - -o /dev/null -H "Cookie: auth_session=$COOKIE" -X POST "$ISS_BASE/auth/authorize" \
  --data-urlencode "response_type=code" --data-urlencode "client_id=$CLIENT_APP" \
  --data-urlencode "redirect_uri=$APP_REDIRECT" --data-urlencode "scope=$APP_SCOPE" \
  --data-urlencode "state=st-demo" --data-urlencode "aud=$FHIR_BASE" \
  --data-urlencode "code_challenge=$PKCE_C" --data-urlencode "code_challenge_method=S256" \
  --data-urlencode "csrf_token=$CSRF" --data-urlencode "patient=$APP_PID" \
  --data-urlencode "action=approve" \
  | grep -i 'location:' | tail -1 | sed -E 's/[Ll]ocation: //; s/\r//')
APP_CODE=$(echo "$LOC" | sed -E 's/.*[?&]code=([^&]+).*/\1/')
[[ "$LOC" == "$APP_REDIRECT"* && -n "$APP_CODE" ]] && ok "redirected to $APP_REDIRECT with code (len=${#APP_CODE})" || { fail "bad redirect: $LOC"; exit 1; }

sub "POST /auth/token (code + PKCE verifier + client secret) → 200"
S=$(curl -s -o /tmp/pa-tok.json -w '%{http_code}' -u "$CLIENT_APP:$SECRET_APP" \
  -X POST "$ISS_BASE/auth/token" \
  --data-urlencode "grant_type=authorization_code" --data-urlencode "code=$APP_CODE" \
  --data-urlencode "redirect_uri=$APP_REDIRECT" --data-urlencode "code_verifier=$PKCE_V")
[[ "$S" == "200" ]] && ok "token exchange → 200" || { fail "expected 200, got $S: $(cat /tmp/pa-tok.json)"; exit 1; }
python3 -c "
import json;d=json.load(open('/tmp/pa-tok.json'))
print('    access_token :', d['access_token'][:24]+'…')
print('    id_token     :', d['id_token'][:24]+'…')
print('    refresh_token:', d['refresh_token'][:24]+'…')
print('    patient      :', d.get('patient'))
print('    scope        :', d.get('scope'))"
APP_AT=$(python3 -c "import json;print(json.load(open('/tmp/pa-tok.json'))['access_token'])")
APP_RT=$(python3 -c "import json;print(json.load(open('/tmp/pa-tok.json'))['refresh_token'])")
ok "access_token + id_token + refresh_token + patient launch context returned"

sub "patient-scoped read of the in-context Patient → 200"
S=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $APP_AT" "$FHIR_BASE/Patient/$APP_PID")
[[ "$S" == "200" ]] && ok "GET Patient/$APP_PID → 200" || fail "expected 200, got $S"

sub "refresh_token grant → fresh access_token"
S=$(curl -s -o /tmp/pa-ref.json -w '%{http_code}' -u "$CLIENT_APP:$SECRET_APP" \
  -X POST "$ISS_BASE/auth/token" \
  --data-urlencode "grant_type=refresh_token" --data-urlencode "refresh_token=$APP_RT")
[[ "$S" == "200" ]] && ok "refresh_token grant → 200 (new access_token issued)" || fail "expected 200, got $S"

sub "replaying the consumed authorization code → 400 invalid_grant (single-use)"
S=$(curl -s -o /tmp/pa-neg.json -w '%{http_code}' -u "$CLIENT_APP:$SECRET_APP" \
  -X POST "$ISS_BASE/auth/token" \
  --data-urlencode "grant_type=authorization_code" --data-urlencode "code=$APP_CODE" \
  --data-urlencode "redirect_uri=$APP_REDIRECT" --data-urlencode "code_verifier=$PKCE_V")
[[ "$S" == "400" ]] && ok "reused code rejected → 400 invalid_grant" || fail "expected 400, got $S"
curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN_FULL" "$FHIR_BASE/Patient/$APP_PID"

# ── 8. SMART v2 granular sub-scope ────────────────────────────────────────────
hdr "8. SMART v2 granular sub-scope (system/Observation.rs?category=laboratory)"
TAG="gran-$(date +%s)"
VIT_ID=$(curl -s -X POST "$FHIR_BASE/Observation" -H "Authorization: Bearer $TOKEN_FULL" -H 'Content-Type: application/fhir+json' -d "{
  \"resourceType\":\"Observation\",\"status\":\"final\",
  \"category\":[{\"coding\":[{\"system\":\"http://terminology.hl7.org/CodeSystem/observation-category\",\"code\":\"vital-signs\"}]}],
  \"code\":{\"text\":\"$TAG-vital\"}}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
LAB_ID=$(curl -s -X POST "$FHIR_BASE/Observation" -H "Authorization: Bearer $TOKEN_FULL" -H 'Content-Type: application/fhir+json' -d "{
  \"resourceType\":\"Observation\",\"status\":\"final\",
  \"category\":[{\"coding\":[{\"system\":\"http://terminology.hl7.org/CodeSystem/observation-category\",\"code\":\"laboratory\"}]}],
  \"code\":{\"text\":\"$TAG-lab\"}}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "seeded lab=$LAB_ID + vital=$VIT_ID"
get_token "$CLIENT_GRAN" "$SECRET_GRAN" "system/Observation.rs?category=laboratory"; TOKEN_GRAN="$RESP_TOKEN"
sub "search Observation — results NARROWED to category=laboratory"
SR=$(curl -s -H "Authorization: Bearer $TOKEN_GRAN" "$FHIR_BASE/Observation?_count=100")
echo "$SR" | python3 -c "
import sys,json;d=json.load(sys.stdin)
lab=sum(1 for e in d.get('entry',[]) if e['resource']['id']=='$LAB_ID')
vit=sum(1 for e in d.get('entry',[]) if e['resource']['id']=='$VIT_ID')
print(f'    sees lab={lab} (want 1)  sees vital-signs={vit} (want 0)')"
sub "read the laboratory Obs → 200; read the vital-signs Obs → denied"
S1=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN_GRAN" "$FHIR_BASE/Observation/$LAB_ID")
S2=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN_GRAN" "$FHIR_BASE/Observation/$VIT_ID")
ok "lab read → $S1 · vital-signs read → $S2 (403/404 = no over-grant)"
curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN_FULL" "$FHIR_BASE/Observation/$LAB_ID"
curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN_FULL" "$FHIR_BASE/Observation/$VIT_ID"

# ── 9. Backend Services private_key_jwt (RFC 7523) ────────────────────────────
hdr "9. Backend Services — private_key_jwt (asymmetric auth, RFC 7523)"
if ! command -v openssl >/dev/null; then
  fail "openssl not found — skipping Backend Services demo"
else
  PKDIR=$(mktemp -d)
  b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
  lsof -ti "tcp:$JWKS_PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PKDIR/key.pem" 2>/dev/null
  BK_KID="demo-backend-$(date +%s)"
  BK_N=$(openssl rsa -in "$PKDIR/key.pem" -noout -modulus 2>/dev/null | sed 's/Modulus=//' | xxd -r -p | b64url)
  printf '{"keys":[{"kty":"RSA","kid":"%s","alg":"RS256","use":"sig","n":"%s","e":"AQAB"}]}\n' "$BK_KID" "$BK_N" > "$PKDIR/jwks.json"
  ( cd "$PKDIR" && python3 -m http.server "$JWKS_PORT" >/dev/null 2>&1 ) &
  JWKS_PID=$!
  trap 'kill "$JWKS_PID" 2>/dev/null; rm -rf "$PKDIR"' EXIT
  sleep 1
  ok "serving client JWKS on host :$JWKS_PORT (container reaches it via host.docker.internal)"
  BK_HDR=$(printf '%s' "{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"$BK_KID\"}" | b64url)
  BK_NOW=$(date +%s)
  # aud MUST equal issuer + /auth/token.
  BK_AUD="$ISS_BASE/fhir/r4/auth/token"
  BK_PAY=$(printf '%s' "{\"iss\":\"$CLIENT_BACKEND\",\"sub\":\"$CLIENT_BACKEND\",\"aud\":\"$BK_AUD\",\"jti\":\"jti-$BK_NOW\",\"exp\":$((BK_NOW+300)),\"iat\":$BK_NOW}" | b64url)
  BK_SIG=$(printf '%s' "$BK_HDR.$BK_PAY" | openssl dgst -sha256 -sign "$PKDIR/key.pem" -binary | b64url)
  BK_ASSERT="$BK_HDR.$BK_PAY.$BK_SIG"
  sub "POST /auth/token with signed client_assertion → 200"
  S=$(curl -s -o /tmp/pa-bk.json -w '%{http_code}' -X POST "$ISS_BASE/auth/token" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=system/Patient.rs" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=$BK_ASSERT")
  if [[ "$S" == "200" ]]; then
    ok "private_key_jwt token → 200 (no shared secret)"
    BK_AT=$(python3 -c "import json;print(json.load(open('/tmp/pa-bk.json'))['access_token'])")
    S=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $BK_AT" "$FHIR_BASE/Patient?_count=0")
    ok "Backend Services token reads Patient → $S"
  else
    fail "private_key_jwt token → $S: $(cat /tmp/pa-bk.json | head -c 200)"
  fi
  kill "$JWKS_PID" 2>/dev/null; trap - EXIT; rm -rf "$PKDIR"
fi

# ── 10. AuditEvent trail ──────────────────────────────────────────────────────
hdr "10. AuditEvent trail (admin API)"
sub "GET /api/audit/events?limit=5"
curl -s -H "Authorization: Bearer $ADMIN_KEY" "$ADMIN_URL/api/audit/events?limit=5" \
  | python3 -c "
import sys,json
for e in json.load(sys.stdin).get('events',[])[:5]:
    print(f\"    {e.get('type','?'):18} client={e.get('clientId','?'):14} {e.get('resourceType','?'):12} outcome={e.get('outcome','?')}\")" 2>/dev/null || echo "    (no events yet)"

# ── Cleanup ───────────────────────────────────────────────────────────────────
hdr "Cleanup"
curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN_FULL" "$FHIR_BASE/Patient/$PID"
ok "deleted Patient/$PID"

hdr "Done — SMART on FHIR walkthrough complete"
