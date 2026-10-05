-- qa_checks.sql
-- Reconciliation checks that run at the end of every build. Each row is one
-- check with what I expected, what came out, and PASS or FAIL. If anything
-- fails, the numbers downstream can't be trusted until it's explained in
-- docs/qa_log.md.

CREATE OR REPLACE TABLE mart.qa_results AS
WITH checks AS (

    -- 1. Raw loads match the row counts I recorded on first load
    SELECT 'raw carrier rows'    AS check_name, 1121004::DOUBLE AS expected, (SELECT COUNT(*) FROM raw.carrier)::DOUBLE    AS actual
    UNION ALL SELECT 'raw outpatient rows', 575092,  (SELECT COUNT(*) FROM raw.outpatient)
    UNION ALL SELECT 'raw inpatient rows',  58066,   (SELECT COUNT(*) FROM raw.inpatient)
    UNION ALL SELECT 'raw snf rows',        12548,   (SELECT COUNT(*) FROM raw.snf)
    UNION ALL SELECT 'raw hha rows',        6215,    (SELECT COUNT(*) FROM raw.hha)
    UNION ALL SELECT 'raw hospice rows',    12107,   (SELECT COUNT(*) FROM raw.hospice)
    UNION ALL SELECT 'raw dme rows',        103828,  (SELECT COUNT(*) FROM raw.dme)
    UNION ALL SELECT 'raw pde rows',        515520,  (SELECT COUNT(*) FROM raw.pde)
    UNION ALL SELECT 'raw beneficiary rows', 86917,  (SELECT COUNT(*) FROM raw.beneficiary)

    -- 2. Staging keeps every claim exactly once
    UNION ALL SELECT 'stg claims = distinct raw claim ids',
        (SELECT COUNT(DISTINCT CLM_ID) FROM raw.carrier) + (SELECT COUNT(DISTINCT CLM_ID) FROM raw.outpatient)
      + (SELECT COUNT(DISTINCT CLM_ID) FROM raw.inpatient) + (SELECT COUNT(DISTINCT CLM_ID) FROM raw.snf)
      + (SELECT COUNT(DISTINCT CLM_ID) FROM raw.hha) + (SELECT COUNT(DISTINCT CLM_ID) FROM raw.hospice)
      + (SELECT COUNT(DISTINCT CLM_ID) FROM raw.dme),
        (SELECT COUNT(*) FROM stg.claims)
    UNION ALL SELECT 'stg duplicate claim ids', 0,
        (SELECT COUNT(*) - COUNT(DISTINCT claim_id) FROM stg.claims)
    UNION ALL SELECT 'stg lines add back to raw rows',
        1121004 + 575092 + 58066 + 12548 + 6215 + 12107 + 103828,
        (SELECT SUM(n_lines) FROM stg.claims)
    UNION ALL SELECT 'stg claims with no from date', 0,
        (SELECT COUNT(*) FROM stg.claims WHERE from_dt IS NULL OR thru_dt IS NULL)
    UNION ALL SELECT 'stg claims with no payment', 0,
        (SELECT COUNT(*) FROM stg.claims WHERE paid_amt IS NULL)
    UNION ALL SELECT 'stg pde fills with no date or days supply', 0,
        (SELECT COUNT(*) FROM stg.pde WHERE fill_dt IS NULL OR days_supply IS NULL)

    -- 3. Dollars: one payment per claim, and carrier lines add up to the header
    UNION ALL SELECT 'inpatient paid, one row per claim', 141046614.08,
        (SELECT SUM(paid_amt) FROM stg.claims WHERE claim_type = 'inpatient')
    UNION ALL SELECT 'carrier line payments = claim payments',
        (SELECT SUM(paid_amt) FROM stg.claims WHERE claim_type = 'carrier'),
        (SELECT SUM(CAST(LINE_NCH_PMT_AMT AS DECIMAL(12, 2))) FROM raw.carrier)
    UNION ALL SELECT 'claims where payment changes across lines', 0,
        (SELECT COUNT(*) FROM (SELECT CLM_ID FROM raw.outpatient GROUP BY 1 HAVING COUNT(DISTINCT CLM_PMT_AMT) > 1))

    -- 4. Member months
    UNION ALL SELECT 'duplicate person-months', 0,
        (SELECT COUNT(*) - COUNT(DISTINCT bene_id || month_start) FROM stg.member_month)
    UNION ALL SELECT '2022 A and B member months', 98100,
        (SELECT COUNT(*) FROM mart.member_month WHERE year = 2022)

    -- 5. Every 2015-2022 claim is either matched to a member month or sits in a Part A only month
    UNION ALL SELECT 'claims 2015-2022 = matched + Part A only months',
        (SELECT COUNT(*) FROM stg.claims WHERE from_dt BETWEEN DATE '2015-01-01' AND DATE '2022-12-31'),
        (SELECT COUNT(*) FROM mart.claims_in_window)
      + (SELECT COUNT(*) FROM stg.claims c JOIN stg.member_month m
           ON m.bene_id = c.bene_id AND m.month_start = c.service_month
         WHERE c.from_dt BETWEEN DATE '2015-01-01' AND DATE '2022-12-31' AND m.buyin_cd IN ('1', 'A'))

    -- 6. Stays roll up every inpatient claim and dollar
    UNION ALL SELECT 'stays cover every inpatient claim',
        (SELECT COUNT(*) FROM stg.claims WHERE claim_type = 'inpatient'),
        (SELECT SUM(n_claims) FROM mart.inpatient_stay)
    UNION ALL SELECT 'stays keep every inpatient dollar',
        (SELECT SUM(paid_amt) FROM stg.claims WHERE claim_type = 'inpatient'),
        (SELECT SUM(paid_amt) FROM mart.inpatient_stay)

    -- 7. PMPM categories add up to the yearly total
    UNION ALL SELECT '2022 category PMPM sums to total PMPM',
        (SELECT medical_pmpm FROM mart.pmpm_by_year WHERE year = 2022),
        (SELECT ROUND(SUM(pmpm), 2) FROM mart.pmpm_by_category WHERE year = 2022)

    -- 8. PDC: two members worked by hand (docs/measure_specs.md) and a range check
    UNION ALL SELECT 'PDC hand check 1 (238 / 275 days)', ROUND(238 / 275, 4),
        (SELECT pdc FROM mart.pdc_result WHERE bene_id = '-10000010285326' AND measure = 'RAS antagonists' AND year = 2022)
    UNION ALL SELECT 'PDC hand check 2 (213 / 292 days)', ROUND(213 / 292, 4),
        (SELECT pdc FROM mart.pdc_result WHERE bene_id = '-10000010283760' AND measure = 'RAS antagonists' AND year = 2022)
    UNION ALL SELECT 'PDC values outside 0 to 1', 0,
        (SELECT COUNT(*) FROM mart.pdc_result WHERE pdc < 0 OR pdc > 1)
)
SELECT
    check_name,
    expected,
    actual,
    CASE WHEN ABS(COALESCE(actual, -1) - expected) <= 0.01 THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks;

SELECT * FROM mart.qa_results;
SELECT result, COUNT(*) AS checks FROM mart.qa_results GROUP BY result;
