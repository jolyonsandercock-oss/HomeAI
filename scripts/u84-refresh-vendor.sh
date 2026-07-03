#!/bin/bash
# Re-download pinned vendor assets and verify checksums against MANIFEST.txt.
# Quarterly refresh (per U84 §25 vendor + offline strategy).
set -euo pipefail
cd /home_ai/services/build-dashboard/static/vendor

declare -A urls=(
  [tailwind-3.4.min.js]="https://cdn.tailwindcss.com/3.4.0"
  [alpine-3.14.min.js]="https://unpkg.com/alpinejs@3.14.1/dist/cdn.min.js"
  [tabulator-6.2.5.min.js]="https://unpkg.com/tabulator-tables@6.2.5/dist/js/tabulator.min.js"
  [tabulator-6.2.5.min.css]="https://unpkg.com/tabulator-tables@6.2.5/dist/css/tabulator_midnight.min.css"
  [tabulator-5.5.4.min.js]="https://unpkg.com/tabulator-tables@5.5.4/dist/js/tabulator.min.js"
  [tabulator-5.5.4.min.css]="https://unpkg.com/tabulator-tables@5.5.4/dist/css/tabulator.min.css"
  [tabulator-5.6.1.min.js]="https://cdn.jsdelivr.net/npm/tabulator-tables@5.6.1/dist/js/tabulator.min.js"
  [tabulator-5.6.1_midnight.min.css]="https://cdn.jsdelivr.net/npm/tabulator-tables@5.6.1/dist/css/tabulator_midnight.min.css"
  [d3-7.9.min.js]="https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js"
)

echo "── Refreshing vendor assets:"
for f in "${!urls[@]}"; do
  url="${urls[$f]}"
  echo "  $f  ←  $url"
  # Keep last copy as -prev for rollback
  [ -f "$f" ] && cp "$f" "${f%.js}-prev.js" 2>/dev/null || true
  curl -sLfo "$f.tmp" "$url"
  mv "$f.tmp" "$f"
done

echo
echo "── New checksums (update MANIFEST.txt with these):"
sha256sum *.js *.css | grep -v -- '-prev'

echo
echo "── Compare against MANIFEST.txt:"
diff <(sha256sum *.js *.css | grep -v -- '-prev' | sort) \
     <(grep -v '^#' MANIFEST.txt | grep -v '^$' | awk '{print $2"  "$1}' | sort) \
     || echo "  (differences shown above — verify, then update MANIFEST.txt)"

echo
echo "── Done. If hashes changed, bump service worker cache name (sw.js CACHE)"
echo "   and smoke test every primary screen before deploying."
