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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 04 of 08
   Enriched monthly view
   -------------------------------------------------------------------------------------
   Purpose
   Creates vw_monthly_cost_enriched: monthly actuals + owner hierarchy (most specific match) + normalized
   usage + unit price + cost at unit price.

   Run order / prerequisites
     Files 01-03. Produces 'Unmapped' / NULL enrichment until reference tables are loaded.
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
     [C4] Net cost here differs from the CCM reporting view
          These files define net cost as cost + ALL credits (CUD, SUD, discounts, promotions,
          etc.). The toolkit's vw_gcp_billing_export_daily_summary.total_net_cost currently
          excludes resource-based CUD credits and adds promotions back, so totals will not match
          CCM dashboards until the two definitions are aligned. Forecasts written to forecast_fact
          must use the same definition for lock deltas to be meaningful.
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
     [C8] Current-month normalized usage is a partial-month average
          For MONTHLY_AVERAGE conversions (e.g. vCPU-hours -> average cores) the divisor is hours
          elapsed in the period, so the current month reflects data through yesterday; closed
          months use the full month.
     Sections that need review are marked inline with [REVIEW REQUIRED - Cn].
   ===================================================================================== */

-- =====================================================================================
-- SECTION 5: Enriched monthly view (owner + normalized usage + unit price)
-- =====================================================================================
CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_cost_enriched`
OPTIONS (description = 'Monthly CCM actuals with owner hierarchy, normalized usage, and unit pricing')
AS
WITH monthly AS (
  SELECT
    *,
    TO_HEX(MD5(CONCAT(
      CAST(usage_month AS STRING), '|', IFNULL(CAST(invoice_month AS STRING), ''), '|',
      IFNULL(billing_account_id, ''), '|', IFNULL(gcp_project_id, ''), '|', IFNULL(project_name, ''), '|',
      IFNULL(service_id, ''), '|', IFNULL(sku_id, ''), '|', IFNULL(sku_description, ''), '|',
      region, '|', IFNULL(usage_pricing_unit, '')))) AS row_key,
-- [REVIEW REQUIRED - C8] Current-month normalized usage is a partial-month average.
--   See the caveat list at the top of this file and in README.md.
    -- Hours covered by the month (partial for the current month: through yesterday)
    24 * GREATEST(1, DATE_DIFF(LEAST(DATE_ADD(usage_month, INTERVAL 1 MONTH), CURRENT_DATE()), usage_month, DAY))
      AS hours_in_period
  FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_monthly_project_sku_cost`
  WHERE NOT is_invoice_level
),
-- [REVIEW REQUIRED - C6] Ownership matching rules are assumptions.
--   See the caveat list at the top of this file and in README.md.
owner_match AS (
  -- Most specific ownership row wins; effective dating is applied per usage month
  SELECT
    m.row_key,
    o.service_budget_owner, o.service_integration_name, o.team_app_owner, o.finance_unit,
    CASE
      WHEN o.gcp_project_id IS NULL THEN 'unmapped'
      WHEN o.sku_id IS NOT NULL AND o.region IS NOT NULL THEN 'project+sku+region'
      WHEN o.sku_id IS NOT NULL THEN 'project+sku'
      WHEN o.region IS NOT NULL THEN 'project+region'
      ELSE 'project'
    END AS mapping_match_level
  FROM monthly AS m
  LEFT JOIN `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_owner_mapping_adapter` AS o
    ON  o.gcp_project_id = m.gcp_project_id
    AND (o.sku_id IS NULL OR o.sku_id = m.sku_id)
    AND (o.region IS NULL OR o.region = m.region)
    AND m.usage_month >= IFNULL(o.effective_start_date, DATE '1900-01-01')
    AND m.usage_month <  IFNULL(o.effective_end_date,   DATE '9999-12-31')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY m.row_key
    ORDER BY IF(o.sku_id IS NOT NULL, 2, 0) + IF(o.region IS NOT NULL, 1, 0) DESC,
             o.effective_start_date DESC) = 1
),
-- [REVIEW REQUIRED - C7] Unit price precedence and basis are assumptions.
--   See the caveat list at the top of this file and in README.md.
price_match AS (
  -- Precedence: region-specific over all-region, then CONTRACT > BLENDED > LIST, latest start
  SELECT m.row_key, p.price_type, p.price_basis, p.unit_price, p.currency
  FROM monthly AS m
  JOIN `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_price` AS p
    ON  p.sku_id = m.sku_id
    AND (p.region IS NULL OR p.region = m.region)
    AND m.usage_month >= p.effective_start_date
    AND m.usage_month <  IFNULL(p.effective_end_date, DATE '9999-12-31')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY m.row_key
    ORDER BY IF(p.region IS NOT NULL, 1, 0) DESC,
             CASE p.price_type WHEN 'CONTRACT' THEN 1 WHEN 'BLENDED' THEN 2 ELSE 3 END,
             p.effective_start_date DESC) = 1
)
SELECT
  m.usage_month, m.invoice_month, m.billing_account_id, m.gcp_project_id, m.project_name,
  m.service_id, m.service_description, m.sku_id, m.sku_description, m.region,
  m.usage_pricing_unit, m.is_commitment_fee_sku,
  -- Ownership
  IFNULL(o.service_budget_owner, 'Unmapped')     AS service_budget_owner,
  IFNULL(o.service_integration_name, 'Unmapped') AS service_integration_name,
  IFNULL(o.team_app_owner, 'Unmapped')           AS team_app_owner,
  IFNULL(o.finance_unit, 'Unmapped')             AS finance_unit,
  o.mapping_match_level,
  -- Usage
  m.usage_in_pricing_units,
  m.physical_usage_in_pricing_units,
  c.calculated_unit,
  IF(c.sku_id IS NULL OR m.is_commitment_fee_sku, NULL,
     m.physical_usage_in_pricing_units * c.conversion_factor
       / IF(c.time_basis = 'MONTHLY_AVERAGE', m.hours_in_period, 1)) AS normalized_usage,
  -- Cost
  m.cost, m.credits, m.resource_cud_credits, m.flex_cud_legacy_credits, m.fee_utilization_offset_credits,
  m.sud_credits, m.discount_credits, m.promotion_credits, m.net_cost, m.net_cost_excl_promotions, m.cost_at_list,
  SAFE_DIVIDE(m.net_cost, NULLIF(m.physical_usage_in_pricing_units, 0)) AS effective_net_rate_per_pricing_unit,
  -- Unit pricing
  p.price_type, p.price_basis, p.unit_price, p.currency AS price_currency,
  CASE
    WHEN p.unit_price IS NULL OR m.is_commitment_fee_sku THEN NULL
    WHEN p.price_basis = 'PRICING_UNIT' THEN m.physical_usage_in_pricing_units * p.unit_price
    WHEN p.price_basis = 'CALCULATED_UNIT' AND c.sku_id IS NOT NULL
      THEN (m.physical_usage_in_pricing_units * c.conversion_factor
              / IF(c.time_basis = 'MONTHLY_AVERAGE', m.hours_in_period, 1)) * p.unit_price
  END AS cost_at_unit_price
FROM monthly AS m
LEFT JOIN owner_match AS o USING (row_key)
LEFT JOIN price_match AS p USING (row_key)
-- [REVIEW REQUIRED - C2] Starter unit conversions are rule-based guesses.
--   normalized_usage and CALCULATED_UNIT pricing are only as accurate as sku_unit_conversion.
--   See the caveat list at the top of this file and in README.md.
LEFT JOIN `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_conversion` AS c
  ON c.sku_id = m.sku_id;
