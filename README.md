# Preview-Deployer

Bootstrap scripts and lifecycle tooling to turn a Debian 12/13+ LXC into an isolated **PR Preview Deployment Host** using `systemd`, `mariadb`, `nginx`, and a dedicated GitHub Actions self-hosted runner.

## Architecture

- **URL format**: `preview-<app>-pr-<pr>.<domain>` (e.g., `preview-issx-pr-42.domain.tld`)
- **Reverse proxy**: Cloudflare (`*.domain.tld`, Proxied) → Nginx Proxy Manager (`*.domain.tld`) → Preview LXC Nginx (`:80`) → `127.0.0.1:<port>`
- **Two-user isolation**:
  - `gh-runner`: Runs the GitHub Actions runner service. Its only elevated privilege is `NOPASSWD` sudo for `/usr/local/bin/preview-ctl` (`deploy`, `destroy`, `list`, `status`).
  - `preview`: Unprivileged `nologin` user running Node.js apps inside a sandboxed `systemd` template (`preview@.service`).
- **Database isolation**: Each PR gets its own MariaDB database (`preview_<app>_<pr>`) and scoped MySQL user restricted to `127.0.0.1` and that database only.
- **Automatic cleanup**: Previews are destroyed on PR close/teardown or reaped automatically after `PREVIEW_TTL_DAYS` (default: 14 days) via `preview-reaper.timer`.

## Quick Start (on a fresh Debian 12/13 LXC)

1. Clone this repository onto the LXC and run `setup.sh` as `root`:

   ```bash
   git clone <your-repo-url> Preview-Deployer
   cd Preview-Deployer
   sudo ./setup.sh
   ```

   `setup.sh` will interactively prompt you for:
   - Base domain (e.g., `domain.tld`)
   - Preview port range (default `10000`–`10999`)
   - Stale preview TTL in days (default `14`)
   - Node.js major version (`22` or `24`) and `pnpm` version
   - Optional NPM IP for `X-Forwarded-For` real IP resolution
   - GitHub Actions runner tarball URL (or `auto` for latest), Org/Repo URL, registration token (hidden input), runner name, and labels (default `preview`)

2. Register your apps:

   ```bash
   # Interactive registration:
   sudo preview-ctl add-app web

   # Or copy the ready-to-use examples:
   sudo cp examples/apps/web.conf examples/apps/web.env.tmpl /etc/preview-deployer/apps/
   sudo cp examples/apps/issx.conf examples/apps/issx.env.tmpl /etc/preview-deployer/apps/
   sudo chmod 0640 /etc/preview-deployer/apps/*
   ```

   If an app has `BASIC_AUTH="true"` (like `issx`), create its `htpasswd` file:

   ```bash
   sudo htpasswd -cB /etc/preview-deployer/htpasswd/issx.htpasswd preview
   sudo chown root:www-data /etc/preview-deployer/htpasswd/issx.htpasswd
   sudo chmod 0640 /etc/preview-deployer/htpasswd/issx.htpasswd
   ```

3. Configure **Nginx Proxy Manager**:
   - Create **one** Proxy Host for `*.domain.tld` → `http://<preview-lxc-ip>:80` using your `*.domain.tld` SSL certificate.
   - *(Optional)* In **Advanced → Custom Nginx Configuration**, restrict forwarded hosts to preview subdomains:
     ```nginx
     if ($host !~* ^preview-[a-z0-9-]+-pr-[0-9]+\.domain\.tld$) {
         return 404;
     }
     ```

4. Add [examples/workflows/preview.yaml](examples/workflows/preview.yaml) to your repo's `.github/workflows/preview.yaml` and set `APP_NAME`.
   - Comment `!deploy` on a PR to build & deploy.
   - Comment `!deploy --fresh` to wipe the PR's database and re-seed from scratch.
   - Comment `!teardown` (or close/merge the PR) to destroy the preview.

## Updating an Existing LXC

To update `preview-ctl`, `systemd` units, and `nginx` templates/404 page without re-registering the GitHub runner:

```bash
cd Preview-Deployer
git pull
sudo ./setup.sh --update
```

## `preview-ctl` Commands

```bash
sudo preview-ctl list
sudo preview-ctl status <app> <pr>
sudo preview-ctl deploy <app> <pr> <source-dir> [--fresh]
sudo preview-ctl destroy <app> <pr>
sudo preview-ctl reap [days]
sudo preview-ctl add-app <app>
```

## Security Notes

- **Fix existing workflows before adding org runners**: Ensure production deploy jobs use `runs-on: [self-hosted, deploy]` (not bare `self-hosted`) so prod deployments never route to the preview runner.
- **Network isolation**: Block the preview LXC from accessing production databases, production LXCs, or LAN devices in your Proxmox/router firewall.
