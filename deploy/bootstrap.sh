#!/usr/bin/env bash
# One-time host setup for the icb vhost. Idempotent -- safe to re-run.
#
# Assumes the droplet already exists and runs nginx (it is provisioned by the
# weektasks repo's terraform; this app is a second vhost on the same host).
# Run infra/terraform first so DNS resolves, or certbot's http-01 check fails.
#
#   ./deploy/bootstrap.sh
set -euo pipefail

SSH_TARGET="${SSH_TARGET:-root@161.35.37.2}"
FQDN="${FQDN:-icb.bob-productions.dev}"
EMAIL="${EMAIL:-pineapplesuprise@gmail.com}"

cd "$(dirname "$0")/.."

echo "==> check DNS"
resolved=$(dig +short "$FQDN" | tail -1)
if [[ -z "$resolved" ]]; then
	echo "!! $FQDN does not resolve yet -- run infra/terraform first, then wait." >&2
	exit 1
fi
echo "    $FQDN -> $resolved"

echo "==> install vhost"
# Only installed when absent. certbot rewrites this file in place to add the 443
# block, so overwriting it on every run would throw the TLS config away -- and
# the certbot step below would then skip, because the certificate still exists.
scp deploy/nginx-icb.conf "$SSH_TARGET:/tmp/nginx-icb.conf"
ssh "$SSH_TARGET" "set -e
  mkdir -p /var/www/icb
  chown www-data:www-data /var/www/icb
  if [ -f /etc/nginx/sites-available/$FQDN ]; then
    echo '    vhost already installed, leaving it (certbot owns it now)'
  else
    install -m 644 /tmp/nginx-icb.conf /etc/nginx/sites-available/$FQDN
  fi
  rm -f /tmp/nginx-icb.conf
  ln -sfn /etc/nginx/sites-available/$FQDN /etc/nginx/sites-enabled/$FQDN
  # -t before any reload: a bad config would take the existing tasks site down
  # with it, since both vhosts live in the same nginx.
  nginx -t
  systemctl reload nginx"

echo "==> TLS"
# --nginx rewrites only this vhost's file to add the 443 server block and the
# redirect. Existing certificates and vhosts are left alone.
ssh "$SSH_TARGET" "set -e
  if [ ! -d /etc/letsencrypt/live/$FQDN ]; then
    certbot --nginx -d $FQDN --non-interactive --agree-tos -m $EMAIL --redirect
  elif ! grep -q ssl_certificate /etc/nginx/sites-available/$FQDN; then
    # Certificate exists but is not wired into the vhost. --reinstall installs
    # the existing one rather than issuing a new one, so no rate limit is spent.
    echo '    certificate present but not installed, reinstalling'
    certbot --nginx -d $FQDN --non-interactive --agree-tos -m $EMAIL --redirect --reinstall
  else
    echo '    certificate already installed'
  fi
  nginx -t
  systemctl reload nginx"

echo "==> done. Now run ./deploy/deploy.sh to ship the build."
