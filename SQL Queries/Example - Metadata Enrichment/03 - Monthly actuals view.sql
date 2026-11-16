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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 03 of 08
   Monthly actuals view
   -------------------------------------------------------------------------------------
   Purpose
   Creates vw_monthly_project_sku_cost: monthly CCM actuals at usage month x invoice month x billing account
   x project x service x SKU x region. This is the join target for monthly planning data (joining monthly
   data onto the CCM daily summary would fan out costs).

   Run order / prerequisites
     File 01; the CCM toolkit's gcp_billing_export_daily_summary.
     Run files 01 -> 08 in order (see README.md in this folder). All files are plain BigQuery SQL and can
     be adopted as views, a materialized view (file 03), scheduled queries (file 07), or Dataform .sqlx.

   PLACEHOLDERS (find-and-replace in every file before running)
     {{PROJECT_ID}}           Project hosting the CCM toolkit dataset and the new enrichment dataset
     {{CCM_DATASET}}          CCM toolkit dataset (contains gcp_billing_export_daily_summary)
     {{ENRICHMENT_DATASET}}   New dataset for these objects (created by file 01 if missing)
     {{LOCATION}}             BigQuery location of the CCM dataset (e.g. US). Must match for joins.
     {{START_DATE}}           Earliest usage date to expose (YYYY-MM-DD), e.g. 2024-08-01

   CAVEATS THAT APPLY TO THIS FILE - review before relying on results
     [C4] Net cost here differs from the CCM reporting view
          These files define net cost as cost + ALL credits (CUD, SUD, discounts, promotions,
          etc.). The toolkit's vw_gcp_billing_export_daily_summary.total_net_cost currently
          excludes resource-based CUD credits and adds promotions back, so totals will not match
          CCM dashboards until the two definitions are aligned. Forecasts written to forecast_fact
          must use the same definition for lock deltas to be meaningful.
     [C5] Materialized view conversion is validated in a sandbox only
          Converting vw_monthly_project_sku_cost to a materialized view worked as written in a test
          project. Validate in your project (partition-filter requirements on the CCM daily
          summary, refresh cost and staleness settings) before relying on it.
     Sections that need review are marked inline with [REVIEW REQUIRED - Cn].
   ===================================================================================== */

-- =====================================================================================
-- SECTION 4: Monthly actuals from CCM (the join target for monthly planning data)
-- Grain: usage month x invoice month x billing account x project x service x SKU x region.
-- Joining monthly planning data onto the CCM daily summary would fan out costs; join here.
--
-- [REVIEW REQUIRED - C5] Materialized view conversion is validated in a sandbox only.
--   See the caveat list at the top of this file and in README.md.
-- Materialized view note: this is a single-table aggregation over the CCM daily summary, the
-- natural MV candidate. To materialize, change CREATE OR REPLACE VIEW to
-- CREATE MATERIALIZED VIEW (validate in your project first).
-- =====================================================================================
-- [REVIEW REQUIRED - C4] Net cost here differs from the CCM reporting view.
--   net_cost below = cost + ALL credits; net_cost_excl_promotions is also provided. Align with the CCM
--   reporting view (definitions/output/03_reporting_view.sqlx) before comparing totals.
--   See the caveat list at the top of this file and in README.md.
CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_project_sku_cost`
OPTIONS (description = 'Monthly CCM actuals at project x SKU x region grain')
AS
SELECT
  DATE_TRUNC(usage_start_date, MONTH)                      AS usage_month,
  SAFE.PARSE_DATE('%Y%m', invoice_month)                   AS invoice_month,
  billing_account_id,
  project_id                                               AS gcp_project_id,
  project_name,
  service_id,
  service_description,
  sku_id,
  sku_description,
  COALESCE(NULLIF(location_region, ''), 'global')          AS region,
  usage_pricing_unit,
  STARTS_WITH(sku_description, 'Commitment')               AS is_commitment_fee_sku,
  service_description = 'Invoice'                          AS is_invoice_level,
  SUM(total_usage_amount_in_pricing_units)                 AS usage_in_pricing_units,
  SUM(IF(STARTS_WITH(sku_description, 'Commitment'), 0, total_usage_amount_in_pricing_units))
                                                           AS physical_usage_in_pricing_units,
  SUM(total_cost)                                          AS cost,
  SUM(total_credits)                                       AS credits,
  SUM(total_rcud)                                          AS resource_cud_credits,
  SUM(total_fcud_legacy)                                   AS flex_cud_legacy_credits,
  SUM(total_fee_utilization_offset_credits)                AS fee_utilization_offset_credits,
  SUM(total_sud)                                           AS sud_credits,
  SUM(total_discount)                                      AS discount_credits,
  SUM(total_promotion)                                     AS promotion_credits,
  SUM(total_cost + total_credits)                          AS net_cost,
  SUM(total_cost + total_credits - total_promotion)        AS net_cost_excl_promotions,
  SUM(total_cost_at_list)                                  AS cost_at_list
FROM `{{PROJECT_ID}}.{{CCM_DATASET}}.gcp_billing_export_daily_summary`
WHERE usage_start_date >= '{{START_DATE}}'
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13;
