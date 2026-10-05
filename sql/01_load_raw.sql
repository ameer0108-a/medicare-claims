-- 01_load_raw.sql
-- Loads the CMS synthetic files exactly as shipped. Everything comes in as text
-- (all_varchar) so codes like revenue center '0450' and NDCs keep their leading
-- zeros. Typing happens later in staging, where I can see what fails to convert.
--
-- Run from the repo folder: duckdb medicare.duckdb -f sql/01_load_raw.sql

CREATE SCHEMA IF NOT EXISTS raw;

CREATE OR REPLACE TABLE raw.carrier AS
SELECT * FROM read_csv('data/raw/carrier.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.outpatient AS
SELECT * FROM read_csv('data/raw/outpatient.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.inpatient AS
SELECT * FROM read_csv('data/raw/inpatient.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.snf AS
SELECT * FROM read_csv('data/raw/snf.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.hha AS
SELECT * FROM read_csv('data/raw/hha.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.hospice AS
SELECT * FROM read_csv('data/raw/hospice.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.dme AS
SELECT * FROM read_csv('data/raw/dme.csv', delim = '|', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.pde AS
SELECT * FROM read_csv('data/raw/pde.csv', delim = '|', header = true, all_varchar = true);

-- the * picks up all 11 yearly beneficiary files at once.
-- filename = true keeps track of which file each row came from.
CREATE OR REPLACE TABLE raw.beneficiary AS
SELECT * FROM read_csv('data/raw/beneficiary_*.csv', delim = '|', header = true, all_varchar = true, filename = true);

-- row counts, checked against the CMS user guide in docs/qa_log.md
SELECT 'carrier'     AS tbl, COUNT(*) AS n_rows FROM raw.carrier
UNION ALL SELECT 'outpatient',  COUNT(*) FROM raw.outpatient
UNION ALL SELECT 'inpatient',   COUNT(*) FROM raw.inpatient
UNION ALL SELECT 'snf',         COUNT(*) FROM raw.snf
UNION ALL SELECT 'hha',         COUNT(*) FROM raw.hha
UNION ALL SELECT 'hospice',     COUNT(*) FROM raw.hospice
UNION ALL SELECT 'dme',         COUNT(*) FROM raw.dme
UNION ALL SELECT 'pde',         COUNT(*) FROM raw.pde
UNION ALL SELECT 'beneficiary', COUNT(*) FROM raw.beneficiary;
