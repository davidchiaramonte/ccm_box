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
   EXAMPLE: CCM METADATA ENRICHMENT - FILE 02 of 08
   Owner mapping adapter view
   -------------------------------------------------------------------------------------
   Purpose
   Creates vw_owner_mapping_adapter, the ONLY place that needs editing when the real ownership tables
   (mapping.sbo_finops_mapping / mapping.service_cat_v) land in BigQuery. Output column names must not change.

   Run order / prerequisites
     File 01.
     Run files 01 -> 08 in order (see README.md in this folder). All files are plain BigQuery SQL and can
     be adopted as views, a materialized view (file 03), scheduled queries (file 07), or Dataform .sqlx.

   PLACEHOLDERS (find-and-replace in every file before running)
     {{PROJECT_ID}}           Project hosting the CCM toolkit dataset and the new enrichment dataset
     {{CCM_DATASET}}          CCM toolkit dataset (contains gcp_billing_export_daily_summary)
     {{ENRICHMENT_DATASET}}   New dataset for these objects (created by file 01 if missing)
     {{LOCATION}}             BigQuery location of the CCM dataset (e.g. US). Must match for joins.
     {{START_DATE}}           Earliest usage date to expose (YYYY-MM-DD), e.g. 2024-08-01

   CAVEATS THAT APPLY TO THIS FILE - review before relying on results
     [C1] Ownership source column names are ASSUMED
          The commented example in file 02 assumes column names for mapping.sbo_finops_mapping and
          mapping.service_cat_v. Confirm the real schemas (and the join key between them) before
          pointing vw_owner_mapping_adapter at those tables.
     [C6] Ownership matching rules are assumptions
          The enriched view picks the most specific mapping row (project+sku+region > project+sku >
          project+region > project) with inclusive start / exclusive end dates. Confirm this
          matches how ownership is actually assigned. Use project IDs (not numbers) and billing
          region codes (e.g. us-west4, global), not city names. Unmatched spend is reported as
          'Unmapped'.
     Sections that need review are marked inline with [REVIEW REQUIRED - Cn].
   ===================================================================================== */

-- =====================================================================================
-- SECTION 3: Adapter view for the ownership source
-- When mapping.sbo_finops_mapping / mapping.service_cat_v land in BigQuery, replace the
-- FROM clause below (keep the output column names) and nothing downstream changes.
-- =====================================================================================
-- [REVIEW REQUIRED - C6] Ownership matching rules are assumptions.
--   See the caveat list at the top of this file and in README.md.
CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.vw_owner_mapping_adapter`
OPTIONS (description = 'Canonical ownership mapping. Edit the FROM clause to point at the real source tables.')
AS
SELECT
  gcp_project_id,
  NULLIF(sku_id, '')  AS sku_id,
  NULLIF(region, '')  AS region,
  service_budget_owner,
  service_integration_name,
  team_app_owner,
  finance_unit,
  effective_start_date,
  effective_end_date
FROM `{{PROJECT_ID}}.{{ENRICHMENT_DATASET}}.owner_mapping`;
-- [REVIEW REQUIRED - C1] Ownership source column names are ASSUMED.
--   The column names and the join key in the example below are placeholders. Replace them with the real
--   schema; keep the output column names and types exactly as in the active SELECT above.
--   See the caveat list at the top of this file and in README.md.
/* Example once the source tables exist (column names are assumptions - confirm with the owners):
SELECT
  s.gcp_project_id,
  CAST(NULL AS STRING)        AS sku_id,
  CAST(NULL AS STRING)        AS region,
  s.service_budget_owner,
  c.service_integration_name,
  c.team_app_owner,
  s.finance_unit,
  CAST(NULL AS DATE)          AS effective_start_date,
  CAST(NULL AS DATE)          AS effective_end_date
FROM `<project>.mapping.sbo_finops_mapping` AS s
LEFT JOIN `<project>.mapping.service_cat_v` AS c USING (gcp_project_id);
*/
