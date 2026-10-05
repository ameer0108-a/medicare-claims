-- 02_first_look.sql
-- First pass through the raw tables before building anything. Not part of the
-- build. I ran these one at a time in the DuckDB UI and wrote what I found in
-- docs/qa_log.md (entries 1 to 9).

-- 1. Rows vs claims vs people per file. A claim can have many lines, so rows
--    are not claims. Carrier averages about 12 lines per claim.
SELECT 'carrier' AS file, COUNT(*) AS n_rows, COUNT(DISTINCT CLM_ID) AS claims, COUNT(DISTINCT BENE_ID) AS people FROM raw.carrier
UNION ALL SELECT 'outpatient', COUNT(*), COUNT(DISTINCT CLM_ID), COUNT(DISTINCT BENE_ID) FROM raw.outpatient
UNION ALL SELECT 'inpatient',  COUNT(*), COUNT(DISTINCT CLM_ID), COUNT(DISTINCT BENE_ID) FROM raw.inpatient
UNION ALL SELECT 'snf',        COUNT(*), COUNT(DISTINCT CLM_ID), COUNT(DISTINCT BENE_ID) FROM raw.snf
UNION ALL SELECT 'hha',        COUNT(*), COUNT(DISTINCT CLM_ID), COUNT(DISTINCT BENE_ID) FROM raw.hha
UNION ALL SELECT 'hospice',    COUNT(*), COUNT(DISTINCT CLM_ID), COUNT(DISTINCT BENE_ID) FROM raw.hospice
UNION ALL SELECT 'dme',        COUNT(*), COUNT(DISTINCT CLM_ID), COUNT(DISTINCT BENE_ID) FROM raw.dme;

-- 2. Fills and people in Part D. PDE is one row per fill, no claim/line split.
SELECT COUNT(*) AS fills, COUNT(DISTINCT BENE_ID) AS people FROM raw.pde;

-- 3. Date format. Dates are text like 25-Mar-2015, so they need strptime.
SELECT CLM_FROM_DT, CLM_THRU_DT FROM raw.inpatient LIMIT 5;

-- 4. Date range per file.
SELECT 'inpatient' AS file,
       MIN(strptime(CLM_FROM_DT, '%d-%b-%Y')) AS first_dt,
       MAX(strptime(CLM_THRU_DT, '%d-%b-%Y')) AS last_dt
FROM raw.inpatient
UNION ALL SELECT 'snf',     MIN(strptime(CLM_FROM_DT, '%d-%b-%Y')), MAX(strptime(CLM_THRU_DT, '%d-%b-%Y')) FROM raw.snf
UNION ALL SELECT 'hha',     MIN(strptime(CLM_FROM_DT, '%d-%b-%Y')), MAX(strptime(CLM_THRU_DT, '%d-%b-%Y')) FROM raw.hha
UNION ALL SELECT 'hospice', MIN(strptime(CLM_FROM_DT, '%d-%b-%Y')), MAX(strptime(CLM_THRU_DT, '%d-%b-%Y')) FROM raw.hospice
UNION ALL SELECT 'dme',     MIN(strptime(CLM_FROM_DT, '%d-%b-%Y')), MAX(strptime(CLM_THRU_DT, '%d-%b-%Y')) FROM raw.dme
UNION ALL SELECT 'pde',     MIN(strptime(SRVC_DT, '%d-%b-%Y')),     MAX(strptime(SRVC_DT, '%d-%b-%Y'))     FROM raw.pde;

-- 5. Beneficiaries by enrollment year. The population only grows.
SELECT BENE_ENROLLMT_REF_YR AS yr, COUNT(*) AS people
FROM raw.beneficiary
GROUP BY 1
ORDER BY 1;

-- 6. The double counting trap. Summing CLM_PMT_AMT over every line counts
--    the claim payment once per line.
SELECT
    SUM(CAST(CLM_PMT_AMT AS DOUBLE)) AS sum_every_row,
    (SELECT SUM(p) FROM (SELECT ANY_VALUE(CAST(CLM_PMT_AMT AS DOUBLE)) AS p
                         FROM raw.inpatient GROUP BY CLM_ID)) AS sum_one_per_claim
FROM raw.inpatient;

-- 7. Coverage codes for one month, to decide who counts as a member.
--    3 and C = Parts A and B, 1 = Part A only.
SELECT MDCR_ENTLMT_BUYIN_IND_06 AS buyin, COUNT(*) AS people
FROM raw.beneficiary
GROUP BY 1
ORDER BY 2 DESC;

-- 8. Part C (Medicare Advantage) contract in the same months as FFS claims.
--    Should never happen in real data. See qa_log entry 8.
SELECT LEFT(PTC_CNTRCT_ID_06, 1) AS ptc_prefix, COUNT(*) AS people
FROM raw.beneficiary
GROUP BY 1;

-- 9. Does the claim payment change from line to line? If not, any_value()
--    per claim is safe in staging.
SELECT COUNT(*) AS claims_with_more_than_one_payment
FROM (SELECT CLM_ID, COUNT(DISTINCT CLM_PMT_AMT) AS n
      FROM raw.inpatient GROUP BY CLM_ID)
WHERE n > 1;
