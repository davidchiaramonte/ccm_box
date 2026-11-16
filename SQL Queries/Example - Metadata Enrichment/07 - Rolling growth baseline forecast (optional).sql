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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 07 of 08
   Rolling growth baseline forecast (optional)
   -------------------------------------------------------------------------------------
   Purpose
   Optional. Writes a non-ML rolling-growth baseline forecast into forecast_fact (codifies the spreadsheet's
   forward projection). Re-running on the same day replaces that day's rows. Suitable for a monthly scheduled query.

   Run order / prerequisites
     Files 01 and 03.
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
-- SECTION 6 (OPTIONAL): Rolling-growth baseline forecast -> forecast_fact
-- Codifies the spreadsheet's non-ML forward projection: last complete month x average
-- month-over-month growth of the last N complete months (capped), projected for the current
-- month (m00) through the horizon. Re-running on the same day replaces that day's rows.
-- Schedule monthly; write is_locked = TRUE rows for the forecast of record.
-- Tune the three settings below. Compounding is sensitive to the cap: with short or ramping
-- history, prefer a low cap (or set it to 0 for a flat run-rate projection).
-- =====================================================================================
-- [REVIEW REQUIRED - C3] Rolling-growth forecast settings must be tuned.
--   Tune the three settings below before using these projections.
--   See the caveat list at the top of this file and in README.md.
BEGIN
  DECLARE v_snapshot       DATE    DEFAULT CURRENT_DATE();
  DECLARE v_month          DATE    DEFAULT DATE_TRUNC(v_snapshot, MONTH);
  DECLARE v_growth_months  INT64   DEFAULT 3;     -- months of MoM growth to average (spreadsheet uses 3-6)
  DECLARE v_growth_cap     FLOAT64 DEFAULT 0.05;  -- max |monthly growth| applied (0.05 = +/-5%/month)
  DECLARE v_horizon_months INT64   DEFAULT 18;    -- forecast m00..m{horizon}

  DELETE FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact`
  WHERE snapshot_date = v_snapshot AND forecast_version = 'rolling_3m_growth';

  INSERT INTO `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact`
    (snapshot_date, forecast_version, is_locked, target_month, billing_account_id, gcp_project_id,
     sku_id, region, usage_in_pricing_units, normalized_usage, cost_forecast, model_parameters, created_at)
  WITH actuals AS (
    SELECT usage_month, billing_account_id, gcp_project_id, sku_id, region,
           SUM(physical_usage_in_pricing_units) AS usage, SUM(net_cost) AS net_cost
    FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_project_sku_cost`
    WHERE NOT is_invoice_level
      AND usage_month >= DATE_SUB(v_month, INTERVAL v_growth_months + 1 MONTH)
      AND usage_month <  v_month
    GROUP BY 1, 2, 3, 4, 5
  ),
  growth AS (
    SELECT *,
      SAFE_DIVIDE(net_cost, LAG(net_cost) OVER w) - 1 AS mom_cost_growth,
      SAFE_DIVIDE(usage,    LAG(usage)    OVER w) - 1 AS mom_usage_growth
    FROM actuals
    WINDOW w AS (PARTITION BY billing_account_id, gcp_project_id, sku_id, region ORDER BY usage_month)
  ),
  basis AS (
    SELECT
      billing_account_id, gcp_project_id, sku_id, region,
      ARRAY_AGG(STRUCT(usage, net_cost) ORDER BY usage_month DESC LIMIT 1)[OFFSET(0)] AS last_month,
      LEAST(GREATEST(IFNULL(AVG(IF(usage_month >= DATE_SUB(v_month, INTERVAL v_growth_months MONTH), mom_cost_growth, NULL)), 0), -v_growth_cap), v_growth_cap)
        AS cost_growth_rate,
      LEAST(GREATEST(IFNULL(AVG(IF(usage_month >= DATE_SUB(v_month, INTERVAL v_growth_months MONTH), mom_usage_growth, NULL)), 0), -v_growth_cap), v_growth_cap)
        AS usage_growth_rate
    FROM growth
    GROUP BY 1, 2, 3, 4
    HAVING MAX(usage_month) = DATE_SUB(v_month, INTERVAL 1 MONTH)  -- active in the last complete month
  )
  SELECT
    v_snapshot, 'rolling_3m_growth', FALSE,
    DATE_ADD(v_month, INTERVAL k MONTH),
    billing_account_id, gcp_project_id, sku_id, region,
    last_month.usage    * POW(1 + usage_growth_rate, k + 1),
    CAST(NULL AS FLOAT64),
    last_month.net_cost * POW(1 + cost_growth_rate,  k + 1),
    JSON_OBJECT('method', 'last complete month x avg MoM growth (capped)', 'growth_months', v_growth_months,
                'cost_growth_rate', cost_growth_rate, 'usage_growth_rate', usage_growth_rate,
                'growth_cap', v_growth_cap),
    CURRENT_TIMESTAMP()
  FROM basis, UNNEST(GENERATE_ARRAY(0, v_horizon_months)) AS k
  WHERE last_month.net_cost IS NOT NULL;
END;
