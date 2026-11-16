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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 01 of 08
   Setup dataset and reference tables
   -------------------------------------------------------------------------------------
   Purpose
   Creates the enrichment dataset and the four reference tables you load: owner_mapping, sku_unit_conversion,
   sku_unit_price, and forecast_fact (long, versioned forecasts that replace month-named columns).

   Run order / prerequisites
     None (run first). Idempotent: CREATE ... IF NOT EXISTS.
     Run files 01 -> 08 in order (see README.md in this folder). All files are plain BigQuery SQL and can
     be adopted as views, a materialized view (file 03), scheduled queries (file 07), or Dataform .sqlx.

   PLACEHOLDERS (find-and-replace in every file before running)
     {{PROJECT_ID}}           Project hosting the CCM toolkit dataset and the new enrichment dataset
     {{CCM_DATASET}}          CCM toolkit dataset (contains gcp_billing_export_daily_summary)
     {{ENRICHMENT_DATASET}}   New dataset for these objects (created by file 01 if missing)
     {{LOCATION}}             BigQuery location of the CCM dataset (e.g. US). Must match for joins.
     {{START_DATE}}           Earliest usage date to expose (YYYY-MM-DD), e.g. 2024-08-01

   CAVEATS (ALL FILES) - review before relying on results
     [C1] Ownership source column names are ASSUMED
          The commented example in file 02 assumes column names for mapping.sbo_finops_mapping and
          mapping.service_cat_v. Confirm the real schemas (and the join key between them) before
          pointing vw_owner_mapping_adapter at those tables.
     [C2] Starter unit conversions are rule-based guesses
          File 06 infers calculated_unit from SKU description and pricing unit with
          conversion_factor = 1.0 (cores, nodes, GiB RAM, GiB-month). Review every row against
          finance's definitions (e.g. how compute/CBT hours become cores/nodes) and add conversions
          for SKUs it does not cover (networking, operations, licenses, etc.). Check 08-7c lists
          the top uncovered SKUs.
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
     [C5] Materialized view conversion is validated in a sandbox only
          Converting vw_monthly_project_sku_cost to a materialized view worked as written in a test
          project. Validate in your project (partition-filter requirements on the CCM daily
          summary, refresh cost and staleness settings) before relying on it.
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
-- SECTION 1: Dataset
-- =====================================================================================
CREATE SCHEMA IF NOT EXISTS `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}`
OPTIONS (location = '{{LOCATION}}', description = 'CCM metadata enrichment (ownership, unit normalization, pricing, forecasts)');


-- =====================================================================================
-- SECTION 2: Reference tables (canonical shapes; you load these)
-- =====================================================================================

-- Ownership hierarchy. One row per key and effective period.
-- Match precedence: project+sku+region > project+sku > project+region > project.
-- Leave sku_id / region NULL to apply a row to all SKUs / regions in the project.
-- [REVIEW REQUIRED - C6] Ownership matching rules are assumptions.
--   See the caveat list at the top of this file and in README.md.
CREATE TABLE IF NOT EXISTS `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.owner_mapping` (
  gcp_project_id            STRING NOT NULL OPTIONS (description = 'GCP project ID (not number)'),
  sku_id                    STRING          OPTIONS (description = 'Optional SKU override (NULL = all SKUs)'),
  region                    STRING          OPTIONS (description = 'Optional region override, e.g. us-west4 or global (NULL = all regions)'),
  service_budget_owner      STRING,
  service_integration_name  STRING,
  team_app_owner            STRING,
  finance_unit              STRING,
  effective_start_date      DATE            OPTIONS (description = 'Inclusive; NULL = since the beginning'),
  effective_end_date        DATE            OPTIONS (description = 'Exclusive; NULL = still active'),
  source_system             STRING          OPTIONS (description = 'e.g. sbo_finops_mapping, service_cat_v, manual'),
  updated_at                TIMESTAMP
)
OPTIONS (description = 'Ownership hierarchy used to attribute CCM costs to owners/teams');

-- SKU unit normalization (e.g. compute/CBT hours -> cores/nodes).
-- normalized_usage = usage_in_pricing_units * conversion_factor
--                    / (hours in period, when time_basis = 'MONTHLY_AVERAGE')
-- [REVIEW REQUIRED - C2] Starter unit conversions are rule-based guesses.
--   Units and factors are finance-specific; file 06 only seeds starter guesses.
--   See the caveat list at the top of this file and in README.md.
CREATE TABLE IF NOT EXISTS `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_conversion` (
  sku_id               STRING  NOT NULL,
  calculated_unit      STRING  NOT NULL OPTIONS (description = 'Finance unit, e.g. cores, nodes, GiB RAM, GiB-month'),
  conversion_factor    FLOAT64 NOT NULL OPTIONS (description = 'Multiplier applied to usage in pricing units'),
  time_basis           STRING  NOT NULL OPTIONS (description = 'MONTHLY_AVERAGE (divide by hours in period) or NONE'),
  source_pricing_unit  STRING           OPTIONS (description = 'Billing pricing unit the factor applies to, e.g. hour'),
  notes                STRING,
  updated_at           TIMESTAMP
)
OPTIONS (description = 'Converts billing usage to finance/calculated units');

-- Unit prices (blended rates for compute/tiered SKUs, contractual prices).
-- price_basis says whether unit_price is per billing pricing unit or per calculated unit.
-- [REVIEW REQUIRED - C7] Unit price precedence and basis are assumptions.
--   See the caveat list at the top of this file and in README.md.
CREATE TABLE IF NOT EXISTS `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_price` (
  sku_id                STRING  NOT NULL,
  region                STRING           OPTIONS (description = 'NULL = all regions'),
  price_type            STRING  NOT NULL OPTIONS (description = 'CONTRACT, BLENDED, or LIST (precedence in that order)'),
  price_basis           STRING  NOT NULL OPTIONS (description = 'PRICING_UNIT or CALCULATED_UNIT'),
  unit_price            FLOAT64 NOT NULL,
  currency              STRING,
  effective_start_date  DATE    NOT NULL OPTIONS (description = 'Inclusive'),
  effective_end_date    DATE             OPTIONS (description = 'Exclusive; NULL = still active'),
  notes                 STRING,
  updated_at            TIMESTAMP
)
OPTIONS (description = 'Effective-dated unit prices used to compute cost at unit price');

-- Forecasts in LONG, versioned form. One row per snapshot x version x target month x key.
-- Replaces wide, month-named columns (sep26_*, oct26_*, nov26..mar28_*) whose names change
-- every month. "Locking" a forecast = writing rows with is_locked = TRUE for that snapshot.
-- [REVIEW REQUIRED - C4] Net cost here differs from the CCM reporting view.
--   cost_forecast must use the same net cost definition as vw_monthly_project_sku_cost.
--   See the caveat list at the top of this file and in README.md.
CREATE TABLE IF NOT EXISTS `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.forecast_fact` (
  snapshot_date           DATE    NOT NULL OPTIONS (description = 'When the forecast was produced'),
  forecast_version        STRING  NOT NULL OPTIONS (description = 'e.g. prophet_daily, rolling_3m_growth, finance_plan'),
  is_locked               BOOL    NOT NULL OPTIONS (description = 'TRUE for the locked/committed forecast of record'),
  target_month            DATE    NOT NULL OPTIONS (description = 'First day of the forecasted month'),
  billing_account_id      STRING,
  gcp_project_id          STRING  NOT NULL,
  sku_id                  STRING  NOT NULL,
  region                  STRING  NOT NULL,
  usage_in_pricing_units  FLOAT64,
  normalized_usage        FLOAT64,
  cost_forecast           FLOAT64,
  model_parameters        JSON             OPTIONS (description = 'growth_rate, seasonality flags, model id, etc.'),
  created_at              TIMESTAMP
)
PARTITION BY snapshot_date
CLUSTER BY gcp_project_id, sku_id
OPTIONS (description = 'Versioned monthly forecasts (long format)');
