#!/usr/bin/env bash
# Build the WASM version locally, pre-compress it, ship it to the droplet.
# Run from the repo root, after deploy/bootstrap.sh has set the host up once.
#
#   ./deploy/deploy.sh
#   SSH_TARGET=root@161.35.37.2 ./deploy/deploy.sh
set -euo pipefail

# The droplet is provisioned by the weektasks repo's terraform; this app is just
# another vhost on it. Override if that ever moves.
SSH_TARGET="${SSH_TARGET:-root@161.35.37.2}"
SITE_DIR=/var/www/icb
STAGE=/tmp/icb-deploy

cd "$(dirname "$0")/.."

echo "==> build web"
./build_web.sh >/dev/null

echo "==> pre-compress"
# nginx has gzip_static, so shipping a .gz next to each file means the 11 MB
# asset bundle goes out as ~1.8 MB with no per-request compression cost.
rm -f build/web/*.gz
for f in build/web/*; do
	# Skip already-compressed formats. Gzipping a PNG buys nothing, and the
	# link-preview image is better served plain -- some scrapers are fussy about
	# a Content-Encoding they did not ask for.
	case "$f" in
	*.png | *.jpg | *.gz) continue ;;
	esac
	gzip -9 -k "$f"
done
du -sh build/web | cut -f1 | sed 's/^/    total on disk: /'

echo "==> upload"
ssh "$SSH_TARGET" "rm -rf $STAGE && mkdir -p $STAGE"
rsync -az --delete build/web/ "$SSH_TARGET:$STAGE/"

echo "==> install"
# Swapped in place: it is a static site, so there is no service to stop. --delete
# on the rsync above means removed files do not linger in the staging dir.
ssh "$SSH_TARGET" "set -e
  mkdir -p $SITE_DIR
  rsync -a --delete $STAGE/ $SITE_DIR/
  chown -R www-data:www-data $SITE_DIR
  find $SITE_DIR -type f -exec chmod 644 {} +
  find $SITE_DIR -type d -exec chmod 755 {} +
  nginx -t
  rm -rf $STAGE"

echo "==> live: https://icb.bob-productions.dev"
