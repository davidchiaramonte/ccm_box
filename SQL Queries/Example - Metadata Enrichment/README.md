# Example: CCM Metadata Enrichment

Plain BigQuery SQL showing how to enrich CCM toolkit billing data with FinOps planning
metadata: ownership hierarchy, unit normalization (for example, compute hours to cores),
unit prices, and versioned forecasts. It joins at the right grain and doesn't break when
months roll over.

These files are an **example to adapt**, not part of the Dataform pipeline. Dataform only
compiles `definitions/`, so nothing here runs automatically. Each object can be adopted as a
view, a materialized view, a scheduled query, or a Dataform `.sqlx` file.

## Files (run in order)

| File | Creates | Notes |
| :--- | :--- | :--- |
| `01 - Setup dataset and reference tables.sql` | Dataset plus `owner_mapping`, `sku_unit_conversion`, `sku_unit_price`, `forecast_fact` | Canonical tables you load. `forecast_fact` is **long and versioned**, replacing month-named columns (`sep26_*`, `nov26..mar28_*`). |
| `02 - Owner mapping adapter view.sql` | `vw_owner_mapping_adapter` | **The only file to edit** when the real ownership tables land in BigQuery. Keep the output column names. |
| `03 - Monthly actuals view.sql` | `vw_monthly_project_sku_cost` | Monthly CCM actuals at month × billing account × project × service × SKU × region. **Join monthly planning data here**, not to the daily summary (that duplicates costs). Candidate materialized view. |
| `04 - Enriched monthly view.sql` | `vw_monthly_cost_enriched` | Actuals + owner (most specific match) + normalized usage + unit price + cost at unit price. |
| `05 - Forecast views.sql` | `vw_forecast_vs_actual`, `vw_forecast_horizon_wide` | Latest vs. locked forecast vs. actual, lock delta, MTD linear projection, and a spreadsheet-style pivot with **stable** columns (`m00`..`m18`). |
| `06 - Starter unit conversions.sql` | Rows in `sku_unit_conversion` | Rule-based starter rows. Never overwrites existing rows. |
| `07 - Rolling growth baseline forecast (optional).sql` | Rows in `forecast_fact` | Non-ML version of the spreadsheet's forward projection. Can run as a monthly scheduled query. |
| `08 - Data quality checks.sql` | — | Run each check on its own. In Dataform, each becomes an assertion. |

## Placeholders

Find and replace these in every file before running:

| Placeholder | Meaning |
| :--- | :--- |
| `{{PROJECT_ID}}` | Project that hosts the CCM toolkit dataset and the new enrichment dataset |
| `{{CCM_DATASET}}` | CCM toolkit dataset (contains `gcp_billing_export_daily_summary`) |
| `{{ENRICHMENT_DATASET}}` | New dataset for these objects (file 01 creates it if missing) |
| `{{LOCATION}}` | BigQuery location of the CCM dataset (for example `US`). Must match, or the joins fail. |
| `{{START_DATE}}` | Earliest usage date to include (`YYYY-MM-DD`) |

## Caveats: review before relying on results

Each file repeats the caveats that apply to it in its header. Spots that need review are
marked inline with `[REVIEW REQUIRED - Cn]`.

| ID | Caveat | Where |
| :--- | :--- | :--- |
| **C1** | **Ownership source column names are assumed.** The commented example assumes column names for `mapping.sbo_finops_mapping` / `mapping.service_cat_v` and the join key between them. Confirm the real schemas first. | 02 |
| **C2** | **Starter unit conversions are rule-based guesses.** `calculated_unit` is inferred from the SKU description and pricing unit, with `conversion_factor = 1.0`. Review each row against finance's definitions, and add SKUs the rules miss (networking, operations, licenses…). Check 7c lists the top SKUs without a conversion. | 01, 04, 06, 08 |
| **C3** | **The rolling-growth forecast needs tuning.** Compounding growth can overshoot badly with short or ramping history. In testing, a ±25%/month cap produced 55× growth over 18 months. Tune `v_growth_months`, `v_growth_cap` (default ±5%/month) and `v_horizon_months`, or write your Prophet/ML output to `forecast_fact` instead. | 05, 07 |
| **C4** | **Net cost here differs from the CCM reporting view.** These files use cost + **all** credits. `vw_gcp_billing_export_daily_summary.total_net_cost` currently leaves out resource-based CUD credits and adds promotions back. Totals won't match CCM dashboards until the two definitions are aligned. Forecasts must use the same definition for lock deltas to mean anything. | 01, 03, 04, 05, 07 |
| **C5** | **The materialized-view conversion was only validated in a sandbox.** File 03 converted as written there. Validate in your own project: partition-filter requirements on the daily summary, refresh cost, and staleness settings. | 03 |
| **C6** | **Ownership matching rules are assumptions.** The most specific row wins: project+SKU+region, then project+SKU, then project+region, then project. Start dates are inclusive and end dates exclusive. Use project **IDs** and billing region **codes** (`us-west4`, `global`). Unmatched spend shows as `Unmapped`. | 01, 02, 04, 08 |
| **C7** | **Unit price precedence and basis are assumptions.** Region-specific prices beat all-region prices, then CONTRACT > BLENDED > LIST, then the latest start date. `price_basis` must state whether a price is per billing pricing unit or per calculated unit. Confirm the blended-rate definition with finance. | 01, 04, 08 |
| **C8** | **Current-month normalized usage is a partial-month average.** Monthly-average conversions divide by hours elapsed so far (data runs through yesterday). Closed months use the full month. | 04 |

## Adopting it later

- **Materialized view:** change `CREATE OR REPLACE VIEW` to `CREATE MATERIALIZED VIEW` in file 03 (see C5).
- **Dataform:**
  - Each view becomes a `type: "view"` `.sqlx` file; replace fully qualified names with `${ref(...)}`.
  - Reference tables become `type: "declaration"`, or tables built from your sources.
  - Each check in file 08 becomes an assertion.
- **Scheduled query:** file 07, monthly.
- **Build on top of it** by joining to `vw_monthly_project_sku_cost` or `vw_monthly_cost_enriched`.
