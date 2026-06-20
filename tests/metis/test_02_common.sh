set -euo pipefail
source "$(dirname "$0")/../../scripts/metis/common.sh"
val=$(metis_psql_value "SELECT 1+1")
[ "$val" = "2" ] || { echo "FAIL: expected 2, got '$val'"; exit 1; }
echo "PASS"
