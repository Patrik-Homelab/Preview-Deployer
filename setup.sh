#!/usr/bin/env bash
set -euo pipefail

# Preview-Deployer LXC Bootstrap Script
# Target OS: Debian 12 (Bookworm) / Debian 13 (Trixie) / Ubuntu 22.04+
# Run as root: sudo ./setup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers & Logging
# ---------------------------------------------------------------------------
log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
log_ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

prompt_default() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="$3"
    local current_val="${!var_name:-}"

    if [[ -n "$current_val" ]]; then
        return 0
    fi

    local input=""
    read -rp "${prompt_text} [${default_val}]: " input
    printf -v "$var_name" '%s' "${input:-$default_val}"
}

prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    local current_val="${!var_name:-}"

    if [[ -n "$current_val" ]]; then
        return 0
    fi

    local input=""
    read -rsp "${prompt_text}: " input
    echo ""
    printf -v "$var_name" '%s' "$input"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 ))
}

validate_domain() {
    local dom="$1"
    [[ "$dom" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

# ---------------------------------------------------------------------------
# 1. Preflight Checks
# ---------------------------------------------------------------------------
preflight() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root (e.g., sudo ./setup.sh)."
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "Only Debian/Ubuntu (apt-get) systems are supported."
    fi

    if ! pidof systemd >/dev/null 2>&1 && [[ ! -d /run/systemd/system ]]; then
        die "systemd is required and does not appear to be running."
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  RUNNER_ARCH="x64" ;;
        aarch64) RUNNER_ARCH="arm64" ;;
        *)       die "Unsupported CPU architecture: $arch (expected x86_64 or aarch64)." ;;
    esac

    for required in bin/preview-ctl systemd/preview@.service systemd/preview-reaper.service systemd/preview-reaper.timer nginx/preview-router.conf.tmpl nginx/preview-site.conf.tmpl nginx/404.html; do
        [[ -f "${SCRIPT_DIR}/${required}" ]] || die "Missing required file: ${SCRIPT_DIR}/${required}"
    done

    log_ok "Preflight checks passed (arch=${RUNNER_ARCH})."
}

# ---------------------------------------------------------------------------
# 2. Interactive Configuration
# ---------------------------------------------------------------------------
collect_config() {
    echo ""
    echo "================================================================"
    echo "  Preview-Deployer — LXC Setup"
    echo "  Preview URL format: preview-<app>-pr-<pr>.<domain>"
    echo "================================================================"
    echo ""

    while true; do
        prompt_default PREVIEW_DOMAIN "Base domain (for preview-<app>-pr-<pr>.<domain>)" "example.com"
        if validate_domain "$PREVIEW_DOMAIN"; then
            break
        fi
        log_warn "Invalid domain format: '$PREVIEW_DOMAIN'"
        PREVIEW_DOMAIN=""
    done

    while true; do
        prompt_default PORT_START "Preview port range START" "10000"
        prompt_default PORT_END   "Preview port range END"   "10999"
        if validate_port "$PORT_START" && validate_port "$PORT_END" && (( PORT_START < PORT_END )); then
            break
        fi
        log_warn "Invalid port range ($PORT_START - $PORT_END). Must be 1024..65535 with START < END."
        PORT_START=""
        PORT_END=""
    done

    while true; do
        prompt_default PREVIEW_TTL_DAYS "Auto-reap stale previews after N days" "14"
        if [[ "$PREVIEW_TTL_DAYS" =~ ^[0-9]+$ ]] && (( PREVIEW_TTL_DAYS >= 1 )); then
            break
        fi
        log_warn "TTL days must be a positive integer."
        PREVIEW_TTL_DAYS=""
    done

    prompt_default NODE_MAJOR "Node.js major version (e.g. 22 or 24)" "22"
    [[ "$NODE_MAJOR" =~ ^(20|22|24)$ ]] || die "Unsupported Node.js major version: $NODE_MAJOR"

    prompt_default PNPM_VERSION "pnpm version to install globally" "10"

    prompt_default NPM_PROXY_IP "Nginx Proxy Manager IP for X-Forwarded-For trust (leave blank to skip)" ""
    if [[ -n "$NPM_PROXY_IP" ]] && ! [[ "$NPM_PROXY_IP" =~ ^[0-9a-fA-F.:/]+$ ]]; then
        die "Invalid IP/CIDR for NPM_PROXY_IP: $NPM_PROXY_IP"
    fi

    echo ""
    echo "--- GitHub Actions Runner Setup ---"
    prompt_default SETUP_RUNNER "Install & register GitHub Actions runner now? (y/n)" "y"

    if [[ "${SETUP_RUNNER,,}" == "y" || "${SETUP_RUNNER,,}" == "yes" ]]; then
        SETUP_RUNNER="y"
        prompt_default RUNNER_TARBALL_URL "GitHub runner .tar.gz URL (leave blank to fetch latest for linux-${RUNNER_ARCH})" "auto"
        if [[ "$RUNNER_TARBALL_URL" == "auto" ]]; then
            RUNNER_TARBALL_URL=""
        elif ! [[ "$RUNNER_TARBALL_URL" =~ ^https://github\.com/actions/runner/releases/download/.+\.tar\.gz$ ]]; then
            die "Runner URL must match https://github.com/actions/runner/releases/download/.../*.tar.gz"
        fi

        while true; do
            prompt_default GITHUB_SCOPE_URL "GitHub Org or Repo URL (e.g. https://github.com/Patrik-Homelab)" ""
            if [[ "$GITHUB_SCOPE_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]]; then
                break
            fi
            log_warn "Please enter a valid GitHub Org or Repo URL (https://github.com/<org> or https://github.com/<org>/<repo>)."
            GITHUB_SCOPE_URL=""
        done

        while true; do
            prompt_secret GITHUB_RUNNER_TOKEN "GitHub Runner registration token (hidden)"
            if [[ -n "$GITHUB_RUNNER_TOKEN" ]]; then
                break
            fi
            log_warn "Registration token cannot be empty."
        done

        prompt_default RUNNER_NAME "Runner name" "$(hostname -s)-preview"
        prompt_default RUNNER_LABELS "Runner labels (comma-separated)" "preview"
    else
        SETUP_RUNNER="n"
    fi
}

# ---------------------------------------------------------------------------
# 3. Install System Packages & Node.js / pnpm
# ---------------------------------------------------------------------------
install_packages() {
    log_info "Updating apt cache and installing base packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        curl ca-certificates gnupg rsync jq nginx mariadb-server \
        apache2-utils util-linux acl sudo

    local need_node=true
    if command -v node >/dev/null 2>&1; then
        local current_major
        current_major="$(node -v | sed -E 's/^v([0-9]+)\..*/\1/')"
        if [[ "$current_major" == "$NODE_MAJOR" ]]; then
            need_node=false
            log_ok "Node.js v${NODE_MAJOR} already installed ($(node -v))."
        fi
    fi

    if [[ "$need_node" == true ]]; then
        log_info "Installing Node.js ${NODE_MAJOR}.x via NodeSource..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq
        apt-get install -y -qq nodejs
    fi

    log_info "Installing pnpm@${PNPM_VERSION} globally..."
    npm install -g "pnpm@${PNPM_VERSION}" --silent
    log_ok "Installed node $(node -v) and pnpm $(pnpm -v)."
}

# ---------------------------------------------------------------------------
# 4. Create Users, Directories & Permissions
# ---------------------------------------------------------------------------
setup_users_and_dirs() {
    log_info "Configuring system users (gh-runner, preview) and directories..."

    if ! id -u preview >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin --comment "Preview App Runtime" preview
    fi

    if ! id -u gh-runner >/dev/null 2>&1; then
        useradd --system --create-home --home-dir /home/gh-runner --shell /bin/bash --comment "GitHub Actions Runner" gh-runner
    fi

    install -d -m 0750 -o root -g root /etc/preview-deployer
    install -d -m 0750 -o root -g root /etc/preview-deployer/apps
    install -d -m 0750 -o root -g www-data /etc/preview-deployer/htpasswd
    install -d -m 0750 -o root -g root /var/lib/preview-deployer
    install -d -m 0755 -o preview -g preview /opt/previews
    install -d -m 0755 -o preview -g preview /var/cache/pnpm-store
    install -d -m 0755 -o root -g root /etc/nginx/previews
    install -d -m 0755 -o root -g root /var/www/preview-404

    if [[ ! -f /var/lib/preview-deployer/ports.json ]]; then
        echo '{}' > /var/lib/preview-deployer/ports.json
        chmod 0640 /var/lib/preview-deployer/ports.json
    fi

    if [[ ! -f /var/lib/preview-deployer/deployments.json ]]; then
        echo '{}' > /var/lib/preview-deployer/deployments.json
        chmod 0640 /var/lib/preview-deployer/deployments.json
    fi

    touch /var/lib/preview-deployer/state.lock
    chmod 0640 /var/lib/preview-deployer/state.lock

    log_ok "Users and directories configured."
}

# ---------------------------------------------------------------------------
# 5. Write /etc/preview-deployer/config.env
# ---------------------------------------------------------------------------
write_config() {
    log_info "Writing /etc/preview-deployer/config.env..."
    cat > /etc/preview-deployer/config.env <<EOF
# Managed by Preview-Deployer setup.sh
PREVIEW_DOMAIN="${PREVIEW_DOMAIN}"
PORT_START=${PORT_START}
PORT_END=${PORT_END}
PREVIEW_TTL_DAYS=${PREVIEW_TTL_DAYS}
PNPM_STORE_DIR="/var/cache/pnpm-store"
PREVIEWS_ROOT="/opt/previews"
STATE_DIR="/var/lib/preview-deployer"
APPS_DIR="/etc/preview-deployer/apps"
HTPASSWD_DIR="/etc/preview-deployer/htpasswd"
NGINX_PREVIEWS_DIR="/etc/nginx/previews"
PREVIEW_USER="preview"
RUNNER_HOME="/home/gh-runner"
EOF
    chmod 0640 /etc/preview-deployer/config.env
    chown root:root /etc/preview-deployer/config.env
    log_ok "Saved configuration."
}

# ---------------------------------------------------------------------------
# 6. Harden & Start MariaDB
# ---------------------------------------------------------------------------
setup_mariadb() {
    log_info "Configuring MariaDB (bound to 127.0.0.1)..."
    mkdir -p /etc/mysql/mariadb.conf.d
    cat > /etc/mysql/mariadb.conf.d/99-preview-bind.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF

    systemctl enable --now mariadb
    mariadb -e "DELETE FROM mysql.user WHERE User='';" || true
    mariadb -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" || true
    mariadb -e "FLUSH PRIVILEGES;" || true
    log_ok "MariaDB is running and bound to 127.0.0.1."
}

# ---------------------------------------------------------------------------
# 7. Configure Nginx Router & 404 Page
# ---------------------------------------------------------------------------
setup_nginx() {
    log_info "Configuring Nginx preview router and 404 page..."
    cp "${SCRIPT_DIR}/nginx/404.html" /var/www/preview-404/index.html
    chmod 0644 /var/www/preview-404/index.html

    local real_ip_block=""
    if [[ -n "$NPM_PROXY_IP" ]]; then
        real_ip_block="    set_real_ip_from ${NPM_PROXY_IP};
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;"
    fi

    local router_conf
    router_conf="$(<"${SCRIPT_DIR}/nginx/preview-router.conf.tmpl")"
    router_conf="${router_conf//\{\{REAL_IP_BLOCK\}\}/$real_ip_block}"
    printf '%s\n' "$router_conf" > /etc/nginx/sites-available/preview-router.conf

    cp "${SCRIPT_DIR}/nginx/preview-site.conf.tmpl" /etc/preview-deployer/preview-site.conf.tmpl
    chmod 0644 /etc/preview-deployer/preview-site.conf.tmpl

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/preview-router.conf /etc/nginx/sites-enabled/preview-router.conf

    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    log_ok "Nginx configured and reloaded."
}

# ---------------------------------------------------------------------------
# 8. Install preview-ctl, Systemd Units & Sudoers
# ---------------------------------------------------------------------------
install_control_plane() {
    log_info "Installing preview-ctl, systemd units, and sudoers policy..."
    install -m 0755 -o root -g root "${SCRIPT_DIR}/bin/preview-ctl" /usr/local/bin/preview-ctl
    install -m 0644 -o root -g root "${SCRIPT_DIR}/systemd/preview@.service" /etc/systemd/system/preview@.service
    install -m 0644 -o root -g root "${SCRIPT_DIR}/systemd/preview-reaper.service" /etc/systemd/system/preview-reaper.service
    install -m 0644 -o root -g root "${SCRIPT_DIR}/systemd/preview-reaper.timer" /etc/systemd/system/preview-reaper.timer

    systemctl daemon-reload
    systemctl enable --now preview-reaper.timer

    cat > /etc/sudoers.d/preview-deployer <<'EOF'
# Allow gh-runner to invoke preview-ctl without a password.
# preview-ctl enforces strict argument validation and app allowlisting.
Defaults:gh-runner !requiretty
gh-runner ALL=(root) NOPASSWD: /usr/local/bin/preview-ctl deploy *
gh-runner ALL=(root) NOPASSWD: /usr/local/bin/preview-ctl destroy *
gh-runner ALL=(root) NOPASSWD: /usr/local/bin/preview-ctl list
gh-runner ALL=(root) NOPASSWD: /usr/local/bin/preview-ctl status *
EOF
    chmod 0440 /etc/sudoers.d/preview-deployer
    visudo -cf /etc/sudoers.d/preview-deployer >/dev/null

    log_ok "Control plane, reaper timer, and sudoers installed."
}

# ---------------------------------------------------------------------------
# 9. Install & Register GitHub Actions Runner
# ---------------------------------------------------------------------------
setup_github_runner() {
    if [[ "$SETUP_RUNNER" != "y" ]]; then
        log_warn "Skipping GitHub Actions runner setup."
        return 0
    fi

    local runner_dir="/home/gh-runner/actions-runner"
    if [[ -z "$RUNNER_TARBALL_URL" ]]; then
        log_info "Resolving latest actions/runner release for linux-${RUNNER_ARCH}..."
        RUNNER_TARBALL_URL="$(
            curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
            | jq -r --arg arch "linux-${RUNNER_ARCH}" \
                '.assets[] | select(.name | test("^actions-runner-" + $arch + "-[0-9.]+\\.tar\\.gz$")) | .browser_download_url' \
            | head -n 1
        )"
        [[ -n "$RUNNER_TARBALL_URL" && "$RUNNER_TARBALL_URL" != "null" ]] \
            || die "Failed to resolve latest actions/runner URL from GitHub API."
        log_ok "Resolved: ${RUNNER_TARBALL_URL}"
    fi

    # Stop existing runner service if re-running setup
    if [[ -x "${runner_dir}/svc.sh" ]]; then
        (cd "$runner_dir" && ./svc.sh stop >/dev/null 2>&1 || true)
        (cd "$runner_dir" && ./svc.sh uninstall >/dev/null 2>&1 || true)
    fi

    install -d -m 0750 -o gh-runner -g gh-runner "$runner_dir"
    local tarball_tmp
    tarball_tmp="$(mktemp /tmp/actions-runner.XXXXXX.tar.gz)"
    trap 'rm -f "${tarball_tmp:-}"' RETURN

    log_info "Downloading GitHub Actions runner..."
    curl -fsSL -o "$tarball_tmp" "$RUNNER_TARBALL_URL"

    log_info "Extracting runner into ${runner_dir}..."
    tar -xzf "$tarball_tmp" -C "$runner_dir"
    chown -R gh-runner:gh-runner "$runner_dir"

    if [[ -x "${runner_dir}/bin/installdependencies.sh" ]]; then
        log_info "Installing runner OS dependencies..."
        "${runner_dir}/bin/installdependencies.sh" >/dev/null 2>&1 || true
    fi

    log_info "Configuring runner '${RUNNER_NAME}' with labels '${RUNNER_LABELS}'..."
    su -s /bin/bash gh-runner -c "
        cd '${runner_dir}' && \
        ./config.sh \
            --unattended \
            --replace \
            --url '${GITHUB_SCOPE_URL}' \
            --token '${GITHUB_RUNNER_TOKEN}' \
            --name '${RUNNER_NAME}' \
            --labels '${RUNNER_LABELS}' \
            --work '_work'
    "

    unset GITHUB_RUNNER_TOKEN

    log_info "Installing and starting runner systemd service as user gh-runner..."
    (cd "$runner_dir" && ./svc.sh install gh-runner && ./svc.sh start)
    log_ok "GitHub Actions runner is installed and running."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    preflight
    collect_config
    install_packages
    setup_users_and_dirs
    write_config
    setup_mariadb
    setup_nginx
    install_control_plane
    setup_github_runner

    echo ""
    echo "================================================================"
    echo "  Setup Complete!"
    echo "================================================================"
    echo "  Domain pattern : preview-<app>-pr-<pr>.${PREVIEW_DOMAIN}"
    echo "  Port range     : ${PORT_START} - ${PORT_END}"
    echo "  Reaper TTL     : ${PREVIEW_TTL_DAYS} days (preview-reaper.timer)"
    echo "  Config file    : /etc/preview-deployer/config.env"
    echo ""
    echo "  Next steps:"
    echo "    1. Register an app:  sudo preview-ctl add-app web"
    echo "       (or copy templates from ${SCRIPT_DIR}/examples/apps/)"
    echo "    2. Point NPM *.${PREVIEW_DOMAIN} -> http://$(hostname -I | awk '{print $1}'):80"
    echo "    3. Add .github/workflows/preview.yaml to your repo"
    echo "================================================================"
}

main "$@"
