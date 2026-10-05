-- build.sql
-- Rebuilds the whole warehouse from the CMS files in data/raw.
-- From the repo folder (close the DuckDB UI first, only one program can write at a time):
--
--   duckdb medicare.duckdb -f build.sql
--
-- Takes about a minute. The last thing it prints is the QA check summary;
-- every row should say PASS.

.read sql/01_load_raw.sql
.read sql/03_staging.sql
.read sql/04_member_months.sql
.read sql/05_inpatient_stays.sql
.read sql/06_pmpm_utilization.sql
.read sql/07_high_cost_and_cohorts.sql
.read sql/08_pdc_adherence.sql
.read sql/09_outreach_targets.sql
.read sql/qa_checks.sql
.read sql/10_exports.sql
