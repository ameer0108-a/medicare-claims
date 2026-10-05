-- 07_high_cost_and_cohorts.sql
-- Where spend is concentrated, who the high-cost members are, and whether the
-- same people stay expensive year to year (they mostly decide whether care
-- management can work).

-- One row per member per year: months, medical spend, and chronic condition flags.
-- Condition rule (close to the CMS Chronic Conditions Warehouse approach):
--   1+ inpatient, SNF, or home health claim with the code in any position, or
--   2+ outpatient or professional claims with the code on different dates,
--   within the same calendar year.
CREATE OR REPLACE TABLE mart.member_year AS
WITH months AS (
    SELECT
        bene_id,
        year,
        COUNT(*)                         AS member_months,
        MODE(enrollment_type)            AS enrollment_type,
        MAX(age_end_of_year)             AS age,
        BOOL_OR(has_part_d)              AS any_part_d
    FROM mart.member_month
    GROUP BY bene_id, year
),
spend AS (
    SELECT
        bene_id,
        YEAR(service_month)                                                 AS year,
        SUM(paid_amt)                                                       AS medical_paid,
        SUM(paid_amt) FILTER (WHERE service_category = 'Outpatient dialysis') AS dialysis_paid,
        SUM(paid_amt) FILTER (WHERE claim_type = 'inpatient')                AS inpatient_paid
    FROM mart.claims_in_window
    GROUP BY ALL
),
admits AS (
    SELECT bene_id, YEAR(admit_dt) AS year, COUNT(*) AS overnight_admits
    FROM mart.inpatient_stay
    WHERE is_overnight
    GROUP BY ALL
),
dx_hits AS (
    SELECT
        d.bene_id,
        YEAR(d.from_dt)  AS year,
        r.condition,
        COUNT(DISTINCT d.claim_id) FILTER (WHERE d.claim_type IN ('inpatient', 'snf', 'hha')) AS facility_claims,
        COUNT(DISTINCT d.from_dt)  FILTER (WHERE d.claim_type IN ('outpatient', 'carrier'))   AS ambulatory_dates
    FROM stg.claim_dx d
    JOIN ref.chronic_condition_codes r
        ON d.dx_code LIKE r.icd10_prefix || '%'
    GROUP BY ALL
),
conditions AS (
    SELECT
        bene_id,
        year,
        BOOL_OR(condition = 'diabetes')      AS has_diabetes,
        BOOL_OR(condition = 'heart_failure') AS has_heart_failure,
        BOOL_OR(condition = 'copd')          AS has_copd,
        BOOL_OR(condition = 'ckd')           AS has_ckd
    FROM dx_hits
    WHERE facility_claims >= 1 OR ambulatory_dates >= 2
    GROUP BY ALL
)
SELECT
    m.*,
    COALESCE(s.medical_paid, 0)         AS medical_paid,
    COALESCE(s.dialysis_paid, 0)        AS dialysis_paid,
    COALESCE(s.inpatient_paid, 0)       AS inpatient_paid,
    COALESCE(a.overnight_admits, 0)     AS overnight_admits,
    COALESCE(c.has_diabetes, FALSE)     AS has_diabetes,
    COALESCE(c.has_heart_failure, FALSE) AS has_heart_failure,
    COALESCE(c.has_copd, FALSE)         AS has_copd,
    COALESCE(c.has_ckd, FALSE)          AS has_ckd
FROM months m
LEFT JOIN spend s      USING (bene_id, year)
LEFT JOIN admits a     USING (bene_id, year)
LEFT JOIN conditions c USING (bene_id, year);


-- Rank members within each year. cost_rank 1 = most expensive.
CREATE OR REPLACE TABLE mart.member_year_ranked AS
SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY year ORDER BY medical_paid DESC, bene_id) AS cost_rank,
    COUNT(*)     OVER (PARTITION BY year)                                     AS members_in_year
FROM mart.member_year;


-- Share of spend from the top 1%, 5%, 10%, 20%, and the bottom 50%
CREATE OR REPLACE TABLE mart.spend_concentration AS
WITH t AS (
    SELECT *, 100.0 * cost_rank / members_in_year AS pct_rank
    FROM mart.member_year_ranked
)
SELECT
    year,
    MAX(members_in_year)                                                          AS members,
    SUM(medical_paid)                                                             AS total_paid,
    ROUND(100 * SUM(medical_paid) FILTER (WHERE pct_rank <= 1)  / SUM(medical_paid), 1) AS top_1_pct_share,
    ROUND(100 * SUM(medical_paid) FILTER (WHERE pct_rank <= 5)  / SUM(medical_paid), 1) AS top_5_pct_share,
    ROUND(100 * SUM(medical_paid) FILTER (WHERE pct_rank <= 10) / SUM(medical_paid), 1) AS top_10_pct_share,
    ROUND(100 * SUM(medical_paid) FILTER (WHERE pct_rank <= 20) / SUM(medical_paid), 1) AS top_20_pct_share,
    ROUND(100 * SUM(medical_paid) FILTER (WHERE pct_rank > 50)  / SUM(medical_paid), 1) AS bottom_50_pct_share,
    COUNT(*) FILTER (WHERE medical_paid = 0)                                      AS members_with_zero_spend
FROM t
GROUP BY year
ORDER BY year;


-- Who is in the top 5% vs everyone else (2022)
CREATE OR REPLACE TABLE mart.top5_profile AS
SELECT
    CASE WHEN 100.0 * cost_rank / members_in_year <= 5 THEN 'Top 5%' ELSE 'Other 95%' END AS cost_group,
    COUNT(*)                                                       AS members,
    ROUND(AVG(medical_paid), 0)                                    AS avg_paid,
    ROUND(MEDIAN(medical_paid), 0)                                 AS median_paid,
    ROUND(100.0 * AVG((enrollment_type = 'ESRD')::INT), 1)         AS pct_esrd,
    ROUND(100.0 * AVG((dialysis_paid > 0)::INT), 1)                AS pct_any_dialysis,
    ROUND(100.0 * SUM(dialysis_paid) / SUM(medical_paid), 1)       AS pct_spend_dialysis,
    ROUND(100.0 * SUM(inpatient_paid) / SUM(medical_paid), 1)      AS pct_spend_inpatient,
    ROUND(AVG(overnight_admits), 2)                                AS avg_overnight_admits,
    ROUND(100.0 * AVG(has_diabetes::INT), 1)                       AS pct_diabetes,
    ROUND(100.0 * AVG(has_heart_failure::INT), 1)                  AS pct_heart_failure,
    ROUND(100.0 * AVG(has_copd::INT), 1)                           AS pct_copd,
    ROUND(100.0 * AVG(has_ckd::INT), 1)                            AS pct_ckd,
    ROUND(AVG(age), 1)                                             AS avg_age
FROM mart.member_year_ranked
WHERE year = 2022
GROUP BY 1;


-- Persistence: of the 2021 top 5%, where did they land in 2022?
-- If most fall out on their own, a program that enrolls last year's top 5%
-- will look like it worked even if it did nothing (regression to the mean).
CREATE OR REPLACE TABLE mart.top5_persistence AS
WITH y1 AS (
    SELECT bene_id, 100.0 * cost_rank / members_in_year AS pct_rank_2021, medical_paid AS paid_2021
    FROM mart.member_year_ranked WHERE year = 2021
),
y2 AS (
    SELECT bene_id, 100.0 * cost_rank / members_in_year AS pct_rank_2022, medical_paid AS paid_2022, enrollment_type
    FROM mart.member_year_ranked WHERE year = 2022
)
SELECT
    CASE
        WHEN y2.bene_id IS NULL        THEN 'Not enrolled in 2022'
        WHEN y2.pct_rank_2022 <= 5     THEN 'Still top 5%'
        WHEN y2.pct_rank_2022 <= 20    THEN 'Top 6-20%'
        ELSE                                'Below top 20%'
    END                                                         AS where_in_2022,
    COUNT(*)                                                    AS members,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_2021_top5,
    ROUND(AVG(y1.paid_2021), 0)                                 AS avg_paid_2021,
    ROUND(AVG(y2.paid_2022), 0)                                 AS avg_paid_2022,
    ROUND(100.0 * AVG((y2.enrollment_type = 'ESRD')::INT), 1)   AS pct_esrd
FROM y1
LEFT JOIN y2 USING (bene_id)
WHERE y1.pct_rank_2021 <= 5
GROUP BY 1
ORDER BY members DESC;


-- Chronic condition cohorts (2022). Groups overlap; one person can be in several.
CREATE OR REPLACE TABLE mart.cohort_summary AS
WITH flags AS (
    SELECT bene_id, member_months, medical_paid, overnight_admits, 'Diabetes' AS cohort FROM mart.member_year WHERE year = 2022 AND has_diabetes
    UNION ALL
    SELECT bene_id, member_months, medical_paid, overnight_admits, 'Heart failure' FROM mart.member_year WHERE year = 2022 AND has_heart_failure
    UNION ALL
    SELECT bene_id, member_months, medical_paid, overnight_admits, 'COPD' FROM mart.member_year WHERE year = 2022 AND has_copd
    UNION ALL
    SELECT bene_id, member_months, medical_paid, overnight_admits, 'CKD' FROM mart.member_year WHERE year = 2022 AND has_ckd
    UNION ALL
    SELECT bene_id, member_months, medical_paid, overnight_admits, 'None of the four' FROM mart.member_year
    WHERE year = 2022 AND NOT (has_diabetes OR has_heart_failure OR has_copd OR has_ckd)
    UNION ALL
    SELECT bene_id, member_months, medical_paid, overnight_admits, 'All members' FROM mart.member_year WHERE year = 2022
)
SELECT
    cohort,
    COUNT(*)                                                         AS members,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM mart.member_year WHERE year = 2022), 1) AS prevalence_pct,
    ROUND(SUM(medical_paid) / SUM(member_months), 2)                 AS pmpm,
    ROUND(SUM(overnight_admits) * 12000.0 / SUM(member_months), 1)   AS admits_per_1000
FROM flags
GROUP BY cohort
ORDER BY pmpm DESC;


SELECT * FROM mart.spend_concentration;
SELECT * FROM mart.top5_profile;
SELECT * FROM mart.top5_persistence;
SELECT * FROM mart.cohort_summary;
