#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# paito FHIR Server — Federated OIDC (Keycloak broker) demo
# ══════════════════════════════════════════════════════════════════════════════
#
# Drives the FULL federated SMART App Launch against a REAL Keycloak:
#
#   SMART app → paito /auth/authorize
#             → (no session) paito redirects to Keycloak for user login
#             → Keycloak login form (dr.smith)
#             → Keycloak redirects to paito /auth/oidc/callback?code&state
#             → paito exchanges the code at Keycloak, VALIDATES the upstream
#               id_token signature against the realm JWKS, maps the federated
#               (issuer, subject) → Practitioner/dr-smith via the binding table,
#               sets a session, returns to /auth/authorize
#             → paito consent → approve → app authorization code
#             → app exchanges the code at paito /auth/token (PKCE)
#             → paito issues ITS OWN access_token + id_token (iss = paito,
#               fhirUser = Practitioner/dr-smith) — never Keycloak's tokens.
#
# Keycloak is addressed as host.docker.internal:8081 from BOTH paito (host-gateway
# mapping) and this script (curl --resolve → 127.0.0.1:8081), so the issuer is
# identical everywhere and id_token/iss validation passes.
#
# Prereq:  docker compose -f docker-compose.federated.yml up -d
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GOFHIR="${GOFHIR:-http://localhost:3500}"
KC_HOST="${KC_HOST:-host.docker.internal:8081}"
KC="http://$KC_HOST"
KC_RESOLVE=(--resolve "$KC_HOST:127.0.0.1")
APP=smoke-fed-app
APP_SECRET=smoke-fed-app-secret-do-not-use-in-prod
APP_REDIRECT="http://localhost:9999/callback"
KC_USER=dr.smith
KC_PASS=smith-pass-do-not-use-in-prod

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$1"; }

urlenc()    { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"; }
htmlunesc() { sed 's/&amp;/\&/g'; }
jwt_claim() { python3 -c "
import sys,base64,json
p=sys.argv[1].split('.')[1]; p+='='*(4-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get(sys.argv[2],''))" "$1" "$2"; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight: paito + Keycloak reachable"
for i in $(seq 1 90); do
    curl -fsS --max-time 2 "$GOFHIR/fhir/r4/metadata" >/dev/null 2>&1 && break
    [[ $i == 90 ]] && fail "paito not reachable at $GOFHIR"; sleep 1
done
ok "paito responding at $GOFHIR"
for i in $(seq 1 120); do
    curl -fsS --max-time 2 ${KC_RESOLVE[@]+"${KC_RESOLVE[@]}"} "$KC/realms/gofhir/.well-known/openid-configuration" >/dev/null 2>&1 && break
    [[ $i == 120 ]] && fail "Keycloak realm 'gofhir' not reachable at $KC"; sleep 1
done
ok "Keycloak realm 'gofhir' responding"

KC_ISS=$(curl -s ${KC_RESOLVE[@]+"${KC_RESOLVE[@]}"} "$KC/realms/gofhir/.well-known/openid-configuration" \
          | python3 -c "import sys,json;print(json.load(sys.stdin)['issuer'])")
[[ "$KC_ISS" == "$KC/realms/gofhir" ]] \
    && ok "issuer pinned: $KC_ISS (id_token iss validation will pass)" \
    || fail "issuer mismatch: $KC_ISS != $KC/realms/gofhir"

CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT

# ── Step 1: app initiates SMART launch; paito redirects to Keycloak ──────────
step "Step 1: app → paito /auth/authorize → redirect to Keycloak"
read -r PKCE_V PKCE_C < <(python3 -c "
import secrets,hashlib,base64
v=base64.urlsafe_b64encode(secrets.token_bytes(40)).rstrip(b'=').decode()
print(v, base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode())")
SCOPE="openid fhirUser offline_access user/Patient.read"
AUTHZ="$GOFHIR/auth/authorize?response_type=code&client_id=$APP&redirect_uri=$(urlenc "$APP_REDIRECT")&scope=$(urlenc "$SCOPE")&state=demo-state-1&aud=$(urlenc "$GOFHIR/fhir/r4")&code_challenge=$PKCE_C&code_challenge_method=S256"
KC_AUTH_URL=$(curl -s -D - -o /dev/null "$AUTHZ" | grep -i '^location:' | tail -1 | sed -E 's/^[Ll]ocation: //; s/\r//')
[[ "$KC_AUTH_URL" == "$KC/realms/gofhir/protocol/openid-connect/auth"* ]] \
    && ok "paito redirected the browser to Keycloak login" \
    || fail "expected redirect to Keycloak, got: $KC_AUTH_URL"

# ── Step 2: Keycloak user login (dr.smith) ───────────────────────────────────
step "Step 2: Keycloak user login (dr.smith)"
LOGIN_HTML=$(curl -s ${KC_RESOLVE[@]+"${KC_RESOLVE[@]}"} -c "$CJ" "$KC_AUTH_URL")
FORM_ACTION=$(echo "$LOGIN_HTML" | grep -o 'action="[^"]*"' | head -1 | sed -E 's/action="([^"]*)"/\1/' | htmlunesc)
[[ -n "$FORM_ACTION" ]] && ok "got Keycloak login form" || fail "no login form in Keycloak response"
CB_URL=$(curl -s -D - -o /dev/null ${KC_RESOLVE[@]+"${KC_RESOLVE[@]}"} -b "$CJ" -c "$CJ" \
    --data-urlencode "username=$KC_USER" \
    --data-urlencode "password=$KC_PASS" \
    --data-urlencode "credentialId=" \
    "$FORM_ACTION" | grep -i '^location:' | tail -1 | sed -E 's/^[Ll]ocation: //; s/\r//')
[[ "$CB_URL" == "$GOFHIR/auth/oidc/callback"* ]] \
    && ok "Keycloak authenticated → redirect to paito callback" \
    || fail "expected paito callback, got: $CB_URL"
echo "$CB_URL" | grep -q 'code=' && ok "callback carries an authorization code" || fail "no code in callback"

# ── Step 3: paito callback validates upstream id_token, sets session ─────────
step "Step 3: paito /auth/oidc/callback (validates Keycloak id_token signature)"
CB_HDRS=$(curl -s -D - -o /dev/null "$CB_URL")
GF_SESSION=$(echo "$CB_HDRS" | grep -i '^set-cookie: auth_session=' | sed -E 's/.*auth_session=([^;]+).*/\1/' | head -1)
RETURN_TO=$(echo "$CB_HDRS" | grep -i '^location:' | tail -1 | sed -E 's/^[Ll]ocation: //; s/\r//')
[[ -n "$GF_SESSION" ]] \
    && ok "paito established a session (upstream id_token signature validated)" \
    || fail "no paito session cookie — id_token validation likely failed"
[[ "$RETURN_TO" == *"/auth/authorize"* ]] && ok "callback returns to the SMART /authorize step" || fail "unexpected return_to: $RETURN_TO"

# ── Step 4: paito consent → approve → app code ───────────────────────────────
step "Step 4: paito consent → approve"
[[ "$RETURN_TO" == http* ]] || RETURN_TO="$GOFHIR$RETURN_TO"
CONSENT=$(curl -s -H "Cookie: auth_session=$GF_SESSION" "$RETURN_TO")
CSRF=$(echo "$CONSENT" | grep -oE 'name="csrf_token" value="[^"]+"' | sed -E 's/.*value="([^"]+)".*/\1/')
[[ -n "$CSRF" ]] && ok "consent page rendered (CSRF token present)" || fail "no consent page"
APP_CB=$(curl -s -D - -o /dev/null -H "Cookie: auth_session=$GF_SESSION" -X POST "$GOFHIR/auth/authorize" \
    --data-urlencode "response_type=code" --data-urlencode "client_id=$APP" \
    --data-urlencode "redirect_uri=$APP_REDIRECT" --data-urlencode "scope=$SCOPE" \
    --data-urlencode "state=demo-state-1" --data-urlencode "aud=$GOFHIR/fhir/r4" \
    --data-urlencode "code_challenge=$PKCE_C" --data-urlencode "code_challenge_method=S256" \
    --data-urlencode "csrf_token=$CSRF" --data-urlencode "action=approve" \
    | grep -i '^location:' | tail -1 | sed -E 's/^[Ll]ocation: //; s/\r//')
APP_CODE=$(echo "$APP_CB" | sed -E 's/.*[?&]code=([^&]+).*/\1/')
[[ "$APP_CB" == "$APP_REDIRECT"* && -n "$APP_CODE" ]] \
    && ok "paito issued an authorization code to the app" \
    || fail "no app code; redirect was: $APP_CB"

# ── Step 5: app exchanges code at paito for paito-issued tokens ──────────────
step "Step 5: token exchange (paito issues its OWN tokens)"
TOK=$(curl -s -u "$APP:$APP_SECRET" -X POST "$GOFHIR/auth/token" \
    --data-urlencode "grant_type=authorization_code" --data-urlencode "code=$APP_CODE" \
    --data-urlencode "redirect_uri=$APP_REDIRECT" --data-urlencode "code_verifier=$PKCE_V")
AT=$(echo "$TOK" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
IDT=$(echo "$TOK" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id_token',''))")
[[ -n "$AT" ]] && ok "access_token issued" || fail "no access_token: $TOK"
[[ -n "$IDT" ]] && ok "id_token issued (openid scope)" || fail "no id_token"

ID_ISS=$(jwt_claim "$IDT" iss)
[[ "$ID_ISS" == "$GOFHIR" ]] \
    && ok "id_token iss = $ID_ISS (paito, broker boundary respected — NOT Keycloak)" \
    || fail "id_token iss = $ID_ISS, want $GOFHIR"

ID_FU=$(jwt_claim "$IDT" fhirUser)
AT_FU=$(jwt_claim "$AT" fhirUser)
[[ "$ID_FU" == "Practitioner/dr-smith" ]] \
    && ok "id_token fhirUser = $ID_FU (from (issuer,subject) binding, NOT fabricated)" \
    || fail "id_token fhirUser = '$ID_FU', want Practitioner/dr-smith"
[[ "$AT_FU" == "Practitioner/dr-smith" ]] && ok "access_token fhirUser = $AT_FU" || fail "access_token fhirUser = '$AT_FU'"

# ── Step 6: the paito access token authorizes a FHIR request ─────────────────
step "Step 6: paito token authorizes a FHIR request"
S=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AT" "$GOFHIR/fhir/r4/Patient?_count=0")
[[ "$S" == "200" ]] \
    && ok "GET /Patient with the federated-user token → 200 (user/Patient.read granted)" \
    || fail "expected 200, got $S"

step "Federated OIDC demo PASSED"
echo "  real Keycloak login · upstream id_token signature validated against realm JWKS ·"
echo "  (issuer,subject)→fhirUser binding · paito-issued tokens (own iss) · resource access"
