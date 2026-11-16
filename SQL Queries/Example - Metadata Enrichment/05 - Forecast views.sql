/*
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
*/

/* =====================================================================================
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 05 of 08
   Forecast views
   -------------------------------------------------------------------------------------
   Purpose
   Creates vw_forecast_vs_actual (latest and locked forecasts vs. actuals, lock delta, MTD linear projection)
   and vw_forecast_horizon_wide (spreadsheet-style pivot with stable m00..m18 columns).

   Run order / prerequisites
     Files 01 and 03. Returns rows once forecast_fact is populated (file 07 or your own forecasts).
     Run files 01 -> 08 in order (see README.md in this folder). All files are plain BigQuery SQL and can
     be adopted as views, a materialized view (file 03), scheduled queries (file 07), or Dataform .sqlx.

   PLACEHOLDERS (find-and-replace in every file before running)
     {{PROJECT_ID}}           Project hosting the CCM toolkit dataset and the new enrichment dataset
     {{CCM_DATASET}}          CCM toolkit dataset (contains gcp_billing_export_daily_summary)
     {{ENRICHMENT_DATASET}}   New dataset for these objects (created by file 01 if missing)
     {{LOCATION}}             BigQuery location of the CCM dataset (e.g. US). Must match for joins.
     {{START_DATE}}           Earliest usage date to expose (YYYY-MM-DD), e.g. 2024-08-01

   CAVEATS THAT APPLY TO THIS FILE - review before relying on results
     [C3] Rolling-growth forecast settings must be tuned
          File 07 compounds the average month-over-month growth. With short or ramping history it
          can overshoot badly (a +/-25%/month cap produced 55x growth over 18 months in testing).
          Tune v_growth_months, v_growth_cap (default +/-5%/month), and v_horizon_months to your
          history, or replace the file with your Prophet/ML output written to forecast_fact.
     [C4] Net cost here differs from the CCM reporting view
          These files define net cost as cost + ALL credits (CUD, SUD, discounts, promotions,
          etc.). The toolkit's vw_gcp_billing_export_daily_summary.total_net_cost currently
          excludes resource-based CUD credits and adds promotions back, so totals will not match
          CCM dashboards until the two definitions are aligned. Forecasts written to forecast_fact
          must use the same definition for lock deltas to be meaningful.
     Sections that need review are marked inline with [REVIEW REQUIRED - Cn].
   ===================================================================================== */

-- =====================================================================================
-- SECTION 5b: Forecast vs. actual (latest and locked forecasts, lock delta, MTD linear)
-- =====================================================================================
-- [REVIEW REQUIRED - C4] Net cost here differs from the CCM reporting view.
--   lock_delta compares actual net cost (cost + all credits) with locked cost_forecast; both must use
--   the same definition.
--   See the caveat list at the top of this file and in README.md.
CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_forecast_vs_actual`
OPTIONS (description = 'Latest and locked forecasts vs. actuals by month x project x SKU x region')
AS
WITH actual AS (
  SELECT
    usage_month AS target_month, billing_account_id, gcp_project_id, sku_id, region,
    SUM(physical_usage_in_pricing_units) AS actual_usage_in_pricing_units,
    SUM(net_cost)                        AS actual_net_cost
  FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_project_sku_cost`
  WHERE NOT is_invoice_level
  GROUP BY 1, 2, 3, 4, 5
),
latest AS (
  SELECT * FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact`
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY forecast_version, target_month, billing_account_id, gcp_project_id, sku_id, region
    ORDER BY snapshot_date DESC, created_at DESC) = 1
),
locked AS (
  SELECT * FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact`
  WHERE is_locked
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY forecast_version, target_month, billing_account_id, gcp_project_id, sku_id, region
    ORDER BY snapshot_date DESC, created_at DESC) = 1
)
SELECT
  f.forecast_version, f.target_month, f.billing_account_id, f.gcp_project_id, f.sku_id, f.region,
  f.snapshot_date                       AS latest_snapshot_date,
  f.usage_in_pricing_units              AS latest_forecast_usage,
  f.cost_forecast                       AS latest_cost_forecast,
  l.snapshot_date                       AS locked_snapshot_date,
  l.cost_forecast                       AS locked_cost_forecast,
  a.actual_usage_in_pricing_units,
  a.actual_net_cost,
  a.actual_net_cost - l.cost_forecast   AS lock_delta,
  SAFE_DIVIDE(a.actual_net_cost - l.cost_forecast, l.cost_forecast) AS lock_delta_pct,
  -- Linear month-to-date projection for the current month (data is complete through yesterday)
  IF(f.target_month = DATE_TRUNC(CURRENT_DATE(), MONTH),
     SAFE_DIVIDE(a.actual_net_cost, GREATEST(1, DATE_DIFF(CURRENT_DATE(), f.target_month, DAY)))
       * DATE_DIFF(DATE_ADD(f.target_month, INTERVAL 1 MONTH), f.target_month, DAY),
     NULL)                              AS mtd_linear_projection
FROM latest AS f
LEFT JOIN locked AS l
  ON  l.forecast_version = f.forecast_version AND l.target_month = f.target_month
  AND l.billing_account_id IS NOT DISTINCT FROM f.billing_account_id
  AND l.gcp_project_id = f.gcp_project_id AND l.sku_id = f.sku_id AND l.region = f.region
LEFT JOIN actual AS a
  ON  a.target_month = f.target_month
  AND (f.billing_account_id IS NULL OR a.billing_account_id = f.billing_account_id)
  AND a.gcp_project_id = f.gcp_project_id AND a.sku_id = f.sku_id AND a.region = f.region;


-- =====================================================================================
-- SECTION 5c: Spreadsheet-style horizon with STABLE column names
-- m00 = snapshot month, m01 = next month, ... m18. Column names never change month to month.
-- =====================================================================================
-- [REVIEW REQUIRED - C3] Rolling-growth forecast settings must be tuned.
--   If file 07 is used, the horizon reflects its growth settings; review them before sharing projections.
--   See the caveat list at the top of this file and in README.md.
CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_forecast_horizon_wide`
OPTIONS (description = 'Latest snapshot per forecast version pivoted to m00..m18 cost and usage columns')
AS
SELECT *
FROM (
  SELECT
    forecast_version, snapshot_date, billing_account_id, gcp_project_id, sku_id, region,
    DATE_DIFF(target_month, DATE_TRUNC(snapshot_date, MONTH), MONTH) AS month_offset,
    cost_forecast, usage_in_pricing_units
  FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact`
  WHERE TRUE
  QUALIFY snapshot_date = MAX(snapshot_date) OVER (PARTITION BY forecast_version)
)
PIVOT (
  SUM(cost_forecast) AS cost, SUM(usage_in_pricing_units) AS usage
  FOR month_offset IN (0 AS m00, 1 AS m01, 2 AS m02, 3 AS m03, 4 AS m04, 5 AS m05, 6 AS m06,
                       7 AS m07, 8 AS m08, 9 AS m09, 10 AS m10, 11 AS m11, 12 AS m12,
                       13 AS m13, 14 AS m14, 15 AS m15, 16 AS m16, 17 AS m17, 18 AS m18)
);
