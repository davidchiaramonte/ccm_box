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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 06 of 08
   Starter unit conversions
   -------------------------------------------------------------------------------------
   Purpose
   Seeds sku_unit_conversion with rule-based starter rows for SKUs seen in the last 90 days. Only inserts SKUs
   that are not already present, so it never overwrites reviewed rows.

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
     [C2] Starter unit conversions are rule-based guesses
          File 06 infers calculated_unit from SKU description and pricing unit with
          conversion_factor = 1.0 (cores, nodes, GiB RAM, GiB-month). Review every row against
          finance's definitions (e.g. how compute/CBT hours become cores/nodes) and add conversions
          for SKUs it does not cover (networking, operations, licenses, etc.). Check 08-7c lists
          the top uncovered SKUs.
     Sections that need review are marked inline with [REVIEW REQUIRED - Cn].
   ===================================================================================== */

-- =====================================================================================
-- SECTION 5d: Starter unit conversions (rule-based; review before relying on them)
-- Only inserts SKUs that are not already in sku_unit_conversion.
-- =====================================================================================
-- [REVIEW REQUIRED - C2] Starter unit conversions are rule-based guesses.
--   Every inserted row is tagged 'Starter rule ... - review' in notes. Review, correct, and remove that note
--   once a row is confirmed.
--   See the caveat list at the top of this file and in README.md.
MERGE `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.sku_unit_conversion` AS t
USING (
  SELECT
    sku_id,
    CASE
      WHEN pu = 'hour' AND REGEXP_CONTAINS(d, r'\b(core|cpu|vcpu)\b')  THEN 'cores'
      WHEN pu = 'hour' AND REGEXP_CONTAINS(d, r'\bnodes?\b')           THEN 'nodes'
      WHEN pu = 'gibibyte hour' AND REGEXP_CONTAINS(d, r'\b(ram|memory)\b') THEN 'GiB RAM'
      WHEN pu = 'gibibyte month'                                        THEN 'GiB-month'
    END AS calculated_unit,
    CASE WHEN pu IN ('hour', 'gibibyte hour') THEN 'MONTHLY_AVERAGE' ELSE 'NONE' END AS time_basis,
    pu AS source_pricing_unit
  FROM (
    SELECT sku_id, LOWER(ANY_VALUE(sku_description)) AS d, ANY_VALUE(usage_pricing_unit) AS pu
    FROM `{{PROJECT_ID}}.{{CCM_DATASET}}.gcp_billing_export_daily_summary`
    WHERE usage_start_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      AND NOT STARTS_WITH(sku_description, 'Commitment')
    GROUP BY sku_id
  )
) AS s
ON t.sku_id = s.sku_id
WHEN NOT MATCHED AND s.calculated_unit IS NOT NULL THEN
  INSERT (sku_id, calculated_unit, conversion_factor, time_basis, source_pricing_unit, notes, updated_at)
  VALUES (s.sku_id, s.calculated_unit, 1.0, s.time_basis, s.source_pricing_unit,
          'Starter rule from SKU description/pricing unit - review', CURRENT_TIMESTAMP());
