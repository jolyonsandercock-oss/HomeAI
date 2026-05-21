#!/bin/bash
# /home_ai/scripts/u196-oracles.sh
# U196 + U197 — Beer Garden + Ice Cream oracles.
#
# Pulls Tintagel weather from Open-Meteo (free, no API key) and combines
# with same-DoW historical revenue to produce a one-line recommendation.
# Surfaces as Telegram lines on the daily digest 07:30.

set -uo pipefail
LOG=/home_ai/logs/u196-oracles.log

# Tintagel coordinates: 50.661 N, -4.752 W
WEATHER=$(curl -s "https://api.open-meteo.com/v1/forecast?latitude=50.661&longitude=-4.752&daily=temperature_2m_max,precipitation_sum,weather_code&timezone=Europe%2FLondon&forecast_days=1" 2>/dev/null)

if [ -z "$WEATHER" ]; then
  echo "$(date -Iseconds)  weather fetch failed" >> "$LOG"
  exit 1
fi

TEMP=$(echo "$WEATHER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['daily']['temperature_2m_max'][0])")
RAIN=$(echo "$WEATHER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['daily']['precipitation_sum'][0])")
WCODE=$(echo "$WEATHER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['daily']['weather_code'][0])")

DOW=$(date '+%w')

# Pull same-DoW historical averages
BASELINE=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
SELECT json_build_object(
  'beer_avg', (SELECT avg_daily FROM (
    SELECT (sql_template)::text AS x FROM query_whitelist WHERE slug='beer_garden_dow_baseline'
  ) sub, LATERAL (SELECT avg_daily FROM beer_garden_dow_baseline_view WHERE dow=$DOW LIMIT 1) v)
  ,
  'cafe_avg', null
)" 2>/dev/null || echo '{}')

# Simpler: direct query
BEER_AVG=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
WITH dow_data AS (
  SELECT report_date, SUM(value) AS daily
    FROM touchoffice_department_sales
   WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
     AND site = 'malthouse'
     AND EXTRACT(DOW FROM report_date) = $DOW
   GROUP BY report_date
)
SELECT ROUND(AVG(daily)::numeric, 0) FROM dow_data;
" | tr -d ' ')

CAFE_AVG=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
WITH dow_data AS (
  SELECT report_date, SUM(value) AS daily
    FROM touchoffice_department_sales
   WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
     AND site = 'sandwich'
     AND EXTRACT(DOW FROM report_date) = $DOW
   GROUP BY report_date
)
SELECT ROUND(AVG(daily)::numeric, 0) FROM dow_data;
" | tr -d ' ')

# Heuristic: sunny + warm + dry = uplift; wet/cold = downlift
MOOD="neutral"
BEER_TAG=""
CAFE_TAG=""

if (( $(echo "$TEMP >= 18" | bc -l) )) && (( $(echo "$RAIN < 1" | bc -l) )); then
  MOOD="favourable"
  BEER_TAG="🌞 Beer garden weather (${TEMP}°C, dry) — expect uplift vs baseline £${BEER_AVG:-?}"
  CAFE_TAG="🍦 Ice cream weather — cafe likely above baseline £${CAFE_AVG:-?}"
elif (( $(echo "$RAIN > 5" | bc -l) )) || (( $(echo "$TEMP < 8" | bc -l) )); then
  MOOD="adverse"
  BEER_TAG="🌧️ Wet/cold (${TEMP}°C, ${RAIN}mm) — beer garden quiet, indoor only. Baseline £${BEER_AVG:-?}"
  CAFE_TAG="❄️ Cold/wet — cafe likely below baseline £${CAFE_AVG:-?}"
else
  BEER_TAG="🌤️ Mixed weather (${TEMP}°C, ${RAIN}mm) — beer garden marginal. Baseline £${BEER_AVG:-?}"
  CAFE_TAG="☁️ Average weather — cafe near baseline £${CAFE_AVG:-?}"
fi

echo "$(date -Iseconds)  weather=${TEMP}°C/${RAIN}mm mood=$MOOD" >> "$LOG"
echo "$BEER_TAG" >> "$LOG"
echo "$CAFE_TAG" >> "$LOG"

# Output for cron capture / Telegram digest
cat <<EOF
$BEER_TAG
$CAFE_TAG
EOF
