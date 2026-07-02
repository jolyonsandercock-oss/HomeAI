#!/usr/bin/env python3
"""Remove sparklines from page.tsx."""

path = "/home_ai/services/homeai-frontend/app/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Remove SparkLine import
content = content.replace("import { SparkLine } from '@/components/ui/SparkLine';\n", "")

# 2. Remove revSpark, labSpark, occSpark declarations
content = content.replace("  // U185 — sparklines: 7-day arrays { values: number[] }\n", "")
content = content.replace("  const revSpark    = useSlug<{ values: number[] }>('revenue_spark_7d',    {}, { refetchInterval: 10 * 60_000 });\n", "")
content = content.replace("  const labSpark    = useSlug<{ values: number[] }>('labour_pct_spark_7d', {}, { refetchInterval: 10 * 60_000 });\n", "")
content = content.replace("  const occSpark    = useSlug<{ values: number[] }>('occupancy_spark_7d',  {}, { refetchInterval: 10 * 60_000 });\n", "")

# 3. Remove the revenue sparkline JSX block
old_rev = """              {/* U185 — 7-day sparkline */}
              {revSpark.data?.[0]?.values && revSpark.data[0].values.length > 1 && (
                <div className=\"mt-2 h-6 opacity-60\">
                  <SparkLine values={revSpark.data[0].values.map(v => Number(v) || 0)} />
                </div>
              )}
"""
content = content.replace(old_rev, "")

# 4. Remove the labour sparkline JSX block
old_lab = """              {/* U185 — 7-day labour% sparkline */}
              {labSpark.data?.[0]?.values && labSpark.data[0].values.length > 1 && (
                <div className=\"mt-2 h-6 opacity-60\">
                  <SparkLine values={labSpark.data[0].values.map(v => Number(v) || 0)} colour=\"#fbbf24\" />
                </div>
              )}
"""
content = content.replace(old_lab, "")

# 5. Remove occSpark from KPICard
content = content.replace('              spark={occSpark.data?.[0]?.values?.map(v => Number(v) || 0)} />\n', "              />\n")

# 6. Remove reviews sparkline JSX block
old_rev_spk = """                  <div className=\"mt-2 h-10 opacity-60\">
                    <SparkLine values={(reviewsSpk.data[0].rating_spark || []).map(v => Number(v) || 0)} />
                  </div>
"""
content = content.replace(old_rev_spk, "\n")

with open(path, "w") as f:
    f.write(content)

# Verify no SparkLine references remain
if "SparkLine" in content:
    count = content.count("SparkLine")
    print(f"WARNING: {count} SparkLine references remain!")
else:
    print("All sparklines removed successfully")
