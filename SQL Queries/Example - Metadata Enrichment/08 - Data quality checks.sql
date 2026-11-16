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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 08 of 08
   Data quality checks
   -------------------------------------------------------------------------------------
   Purpose
   Data-quality checks. Run each SELECT individually; in Dataform each becomes an assertion.

   Run order / prerequisites
     Files 01-06 (7d needs forecast_fact rows).
     Run files 01 -> 08 in order (see README.md in this folder). All files are plain BigQuery SQL and can
     be adopted as views, a materialized view (file 03), scheduled queries (file 07), or Dataform .sqlx.

   PLACEHOLDERS (find-and-replace in every file before running)
     {{PROJECT_ID}}           Project hosting the CCM toolkit dataset and the new enrichment dataset
     {{CCM_DATASET}}          CCM toolkit dataset (contains gcp_billing_export_daily_summary)
     {{ENRICHMENT_DATASET}}   New dataset for these objects (created by file 01 if missing)
     {{LOCATION}}             BigQuery location of the CCM dataset (e.g. US). Must match for joins.
     {{START_DATE}}           Earliest usage date to expose (YYYY-MM-DD), e.g. 2024-08-01

   CAVEATS THAT APPLY TO THIS FILE - review before relying on results
     [C2] Starter unit conversions are rule-based guesses
          File 06 infers calculated_unit from SKU description and pricing unit with
          conversion_factor = 1.0 (cores, nodes, GiB RAM, GiB-month). Review every row against
          finance's definitions (e.g. how compute/CBT hours become cores/nodes) and add conversions
          for SKUs it does not cover (networking, operations, licenses, etc.). Check 08-7c lists
          the top uncovered SKUs.
     [C6] Ownership matching rules are assumptions
          The enriched view picks the most specific mapping row (project+sku+region > project+sku >
          project+region > project) with inclusive start / exclusive end dates. Confirm this
          matches how ownership is actually assigned. Use project IDs (not numbers) and billing
          region codes (e.g. us-west4, global), not city names. Unmatched spend is reported as
          'Unmapped'.
     [C7] Unit price precedence and basis are assumptions
          When several prices apply, region-specific beats all-region, then CONTRACT > BLENDED >
          LIST, then the latest start date. price_basis must say whether unit_price is per billing
          pricing unit or per calculated unit. Confirm the blended-rate definition with finance.
     Sections that need review are marked inline with [REVIEW REQUIRED - Cn].
   ===================================================================================== */

-- =====================================================================================
-- SECTION 7: Data-quality checks (run individually; in Dataform these become assertions)
-- =====================================================================================

-- [REVIEW REQUIRED - C6] Ownership matching rules are assumptions.
--   See the caveat list at the top of this file and in README.md.
-- 7a. Ownership rows that collide (same key and start date) -> would double count. Expect 0 rows.
SELECT gcp_project_id, sku_id, region, effective_start_date, COUNT(*) AS duplicate_rows
FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_owner_mapping_adapter`
GROUP BY 1, 2, 3, 4
HAVING COUNT(*) > 1;

-- 7b. Unmapped spend in the last complete month (target: low single-digit %).
SELECT
  ROUND(SUM(IF(mapping_match_level = 'unmapped', net_cost, 0)), 2) AS unmapped_net_cost,
  ROUND(SUM(net_cost), 2)                                           AS total_net_cost,
  ROUND(SAFE_DIVIDE(SUM(IF(mapping_match_level = 'unmapped', net_cost, 0)), SUM(net_cost)), 4) AS unmapped_share
FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_cost_enriched`
WHERE usage_month = DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 MONTH);

-- [REVIEW REQUIRED - C2] Starter unit conversions are rule-based guesses.
--   See the caveat list at the top of this file and in README.md.
-- 7c. Top SKUs by spend with no unit conversion (review / add to sku_unit_conversion).
SELECT sku_id, ANY_VALUE(sku_description) AS sku_description, ANY_VALUE(usage_pricing_unit) AS pricing_unit,
       ROUND(SUM(net_cost), 2) AS net_cost_last_month
FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_cost_enriched`
WHERE usage_month = DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 MONTH)
  AND calculated_unit IS NULL AND NOT is_commitment_fee_sku
GROUP BY 1
ORDER BY net_cost_last_month DESC
LIMIT 20;

-- 7d. Duplicate forecast rows for the same snapshot/version/month/key. Expect 0 rows.
SELECT snapshot_date, forecast_version, target_month, billing_account_id, gcp_project_id, sku_id, region, COUNT(*) AS n
FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact`
GROUP BY 1, 2, 3, 4, 5, 6, 7
HAVING COUNT(*) > 1;

-- [REVIEW REQUIRED - C7] Unit price precedence and basis are assumptions.
--   See the caveat list at the top of this file and in README.md.
-- 7e. Overlapping unit-price periods for the same SKU/region/price type. Expect 0 rows.
SELECT a.sku_id, a.region, a.price_type, a.effective_start_date AS start_a, b.effective_start_date AS start_b
FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_price` AS a
JOIN `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_price` AS b
  ON  a.sku_id = b.sku_id AND a.price_type = b.price_type
  AND a.region IS NOT DISTINCT FROM b.region
  AND a.effective_start_date < b.effective_start_date
  AND b.effective_start_date < IFNULL(a.effective_end_date, DATE '9999-12-31');
