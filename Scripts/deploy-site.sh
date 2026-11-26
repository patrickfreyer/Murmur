#!/bin/zsh
# Builds the website (docs/index.html + the assets it uses) into site-dist/ and publishes it to
# Cloudflare Pages on the personal account.
#   Scripts/deploy-site.sh                 build + deploy
#   Scripts/deploy-site.sh --build-only    build site-dist/ for a local preview
#   SITE_URL=https://example.app PROJECT=name Scripts/deploy-site.sh
# --force keeps classic Pages (wrangler 4.168+ otherwise delegates to Workers and fails).
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${PROJECT:-undersay}"
export CLOUDFLARE_ACCOUNT_ID=116092b8ab67eb99b520552e6655f045   # personal account, never Telarron
SITE_URL="${SITE_URL:-https://$PROJECT.pages.dev}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DOWNLOAD_URL="https://github.com/patrickfreyer/Undersay/releases/download/v$VERSION/Undersay-$VERSION.zip"
OUT=site-dist

rm -rf "$OUT"
mkdir -p "$OUT/screenshots"
cp docs/icon.png "$OUT/"
cp docs/screenshots/{home,meeting,voices}.jpg "$OUT/screenshots/"
sed -e "s#https://SITE_URL#${SITE_URL}#g" -e "s#DOWNLOAD_URL#${DOWNLOAD_URL}#g" -e "s#VERSION#${VERSION}#g" \
  docs/index.html > "$OUT/index.html"
cat > "$OUT/_headers" <<'H'
/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()
/screenshots/*
  Cache-Control: public, max-age=604800
H
cat > "$OUT/robots.txt" <<R
User-agent: *
Allow: /
Sitemap: ${SITE_URL}/sitemap.xml
R
cat > "$OUT/sitemap.xml" <<S
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${SITE_URL}/</loc></url></urlset>
S
[[ "${1:-}" == "--build-only" ]] && { echo "Built $OUT for $SITE_URL"; exit 0; }

npx --yes wrangler pages project list 2>/dev/null | grep -q " $PROJECT " ||
  npx --yes wrangler pages project create "$PROJECT" --production-branch main --force
npx --yes wrangler pages deploy "$OUT" --project-name "$PROJECT" --branch main --commit-dirty=true
echo "Live at $SITE_URL"
