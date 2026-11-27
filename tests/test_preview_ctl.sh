#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_CTL="${REPO_DIR}/bin/preview-ctl"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" != "$actual" ]]; then
        fail "${msg}: expected='${expected}', actual='${actual}'"
    fi
}

assert_fails() {
    local msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "Expected failure (${msg}), but command succeeded: $*"
    fi
}

# Set up isolated test environment
mkdir -p "${TMP_ROOT}"/{apps,htpasswd,state,previews,nginx-previews,src-web,src-issx}
cp "${REPO_DIR}/examples/apps/web.conf" "${TMP_ROOT}/apps/web.conf"
cp "${REPO_DIR}/examples/apps/web.env.tmpl" "${TMP_ROOT}/apps/web.env.tmpl"
cp "${REPO_DIR}/examples/apps/issx.conf" "${TMP_ROOT}/apps/issx.conf"
cp "${REPO_DIR}/examples/apps/issx.env.tmpl" "${TMP_ROOT}/apps/issx.env.tmpl"
echo 'preview:$2y$05$dummyhash' > "${TMP_ROOT}/htpasswd/issx.htpasswd"
echo "console.log('ok')" > "${TMP_ROOT}/src-web/index.js"
echo "console.log('ok')" > "${TMP_ROOT}/src-issx/index.js"

cat > "${TMP_ROOT}/config.env" <<EOF
PREVIEW_DOMAIN="example.tld"
PORT_START=10000
PORT_END=10001
PREVIEW_TTL_DAYS=14
PNPM_STORE_DIR="${TMP_ROOT}/pnpm-store"
PREVIEWS_ROOT="${TMP_ROOT}/previews"
STATE_DIR="${TMP_ROOT}/state"
APPS_DIR="${TMP_ROOT}/apps"
HTPASSWD_DIR="${TMP_ROOT}/htpasswd"
NGINX_PREVIEWS_DIR="${TMP_ROOT}/nginx-previews"
PREVIEW_USER="$(id -un)"
RUNNER_HOME="${TMP_ROOT}"
EOF

export PREVIEW_CONFIG_FILE="${TMP_ROOT}/config.env"
export PREVIEW_TEST_MODE="1"
export NGINX_SITE_TMPL="${REPO_DIR}/nginx/preview-site.conf.tmpl"

if ! command -v rsync >/dev/null 2>&1; then
    mkdir -p "${TMP_ROOT}/mock-bin"
    cat > "${TMP_ROOT}/mock-bin/rsync" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args=()
for a in "$@"; do
    case "$a" in
        --exclude) shift_next=1 ;;
        *)
            if [[ "${shift_next:-0}" == "1" ]]; then
                shift_next=0
            elif [[ "$a" != -* ]]; then
                args+=("$a")
            fi
            ;;
    esac
done
src="${args[-2]}"
dst="${args[-1]}"
mkdir -p "$dst"
cp -a "${src}." "$dst/"
MOCK
    chmod +x "${TMP_ROOT}/mock-bin/rsync"
    export PATH="${TMP_ROOT}/mock-bin:${PATH}"
fi

# 1. Input validation tests
assert_fails "path traversal app" "$PREVIEW_CTL" deploy "../evil" 1 "${TMP_ROOT}/src-web"
assert_fails "shell metachar app" "$PREVIEW_CTL" deploy "web;id" 1 "${TMP_ROOT}/src-web"
assert_fails "unknown app"        "$PREVIEW_CTL" deploy "unknown-app" 1 "${TMP_ROOT}/src-web"
assert_fails "non-numeric PR"     "$PREVIEW_CTL" deploy "web" "abc" "${TMP_ROOT}/src-web"
assert_fails "zero PR"            "$PREVIEW_CTL" deploy "web" "0" "${TMP_ROOT}/src-web"
assert_fails "missing source dir" "$PREVIEW_CTL" deploy "web" "1" "${TMP_ROOT}/does-not-exist"
pass "Input validation rejects unsafe app names, PR IDs, and missing paths"

# 2. Deploy first PR -> port 10000
out1="$("$PREVIEW_CTL" deploy web 14 "${TMP_ROOT}/src-web")"
echo "$out1" | grep -q "PREVIEW_URL=https://preview-web-pr-14.example.tld" || fail "Unexpected URL in output: $out1"
echo "$out1" | grep -q "PREVIEW_PORT=10000" || fail "Expected port 10000: $out1"

env_file="${TMP_ROOT}/previews/web-pr-14/.env"
[[ -f "$env_file" ]] || fail "Missing rendered .env at $env_file"
assert_eq "600" "$(stat -c '%a' "$env_file")" ".env permissions"
if grep -q '{{' "$env_file"; then
    fail "Unresolved template placeholders in $env_file"
fi
grep -q "ORIGIN=https://preview-web-pr-14.example.tld" "$env_file" || fail "Missing ORIGIN in .env"
grep -q "PORT=10000" "$env_file" || fail "Missing PORT in .env"
pass "First deploy renders .env (0600), allocates port 10000, and sets preview-web-pr-14.example.tld"

# 3. Redeploy same PR reuses port 10000 & existing credentials
pass_before="$(grep '^DATABASE_PASSWORD=' "$env_file")"
out1_redeploy="$("$PREVIEW_CTL" deploy web 14 "${TMP_ROOT}/src-web")"
echo "$out1_redeploy" | grep -q "PREVIEW_PORT=10000" || fail "Redeploy did not reuse port 10000"
pass_after="$(grep '^DATABASE_PASSWORD=' "$env_file")"
assert_eq "$pass_before" "$pass_after" "DB password preserved on redeploy"
pass "Redeploy reuses port 10000 and preserves DB credentials"

# 4. Deploy second app with Basic Auth -> port 10001
out2="$("$PREVIEW_CTL" deploy issx 42 "${TMP_ROOT}/src-issx")"
echo "$out2" | grep -q "PREVIEW_URL=https://preview-issx-pr-42.example.tld" || fail "Unexpected URL for issx: $out2"
echo "$out2" | grep -q "PREVIEW_PORT=10001" || fail "Expected port 10001: $out2"

nginx_issx="${TMP_ROOT}/nginx-previews/issx-pr-42.conf"
grep -q "auth_basic \"Preview (issx)\";" "$nginx_issx" || fail "Missing Basic Auth in issx nginx conf"
grep -q "proxy_pass http://127.0.0.1:10001;" "$nginx_issx" || fail "Missing proxy_pass in issx nginx conf"
pass "Second deploy allocates port 10001 and enables Basic Auth in Nginx snippet"

# 5. Port exhaustion check
assert_fails "port range exhausted" "$PREVIEW_CTL" deploy web 99 "${TMP_ROOT}/src-web"
pass "Port allocator fails cleanly when range is exhausted"

# 6. List & Status
list_out="$("$PREVIEW_CTL" list)"
echo "$list_out" | grep -q "web-pr-14" || fail "list missing web-pr-14"
"$PREVIEW_CTL" status issx 42 | jq -e '.port == 10001' >/dev/null || fail "status missing port 10001"
pass "list and status report active deployments accurately"

# 7. Destroy releases port and allows new deployment
"$PREVIEW_CTL" destroy web 14 >/dev/null
[[ ! -d "${TMP_ROOT}/previews/web-pr-14" ]] || fail "Preview directory not removed on destroy"
[[ ! -f "${TMP_ROOT}/nginx-previews/web-pr-14.conf" ]] || fail "Nginx snippet not removed on destroy"

out3="$("$PREVIEW_CTL" deploy web 99 "${TMP_ROOT}/src-web")"
echo "$out3" | grep -q "PREVIEW_PORT=10000" || fail "Freed port 10000 was not reused: $out3"
pass "destroy cleans up files/nginx and releases port 10000"

# 8. Reaper destroys only stale deployments
old_ts=$(( $(date -u +%s) - 20 * 86400 ))
tmp_dep="$(mktemp)"
jq --argjson ts "$old_ts" '.["issx-pr-42"].updated_at = $ts' "${TMP_ROOT}/state/deployments.json" > "$tmp_dep"
mv "$tmp_dep" "${TMP_ROOT}/state/deployments.json"

"$PREVIEW_CTL" reap 14 >/dev/null
[[ ! -d "${TMP_ROOT}/previews/issx-pr-42" ]] || fail "Stale deployment issx-pr-42 was not reaped"
[[ -d "${TMP_ROOT}/previews/web-pr-99" ]] || fail "Fresh deployment web-pr-99 was wrongly reaped"
pass "reap destroys stale previews while preserving fresh ones"

echo ""
echo "All preview-ctl tests passed!"
