-- 05_inpatient_stays.sql
-- Rolls inpatient claims up into hospital stays, then flags 30-day readmissions.
--
-- Two things about this data drive the design (qa_log entries 12 to 14):
--   * 73% of inpatient claims start and end on the same day, mostly DRG 951
--     with Z-code principal diagnoses and a median payment under $1,000. Real
--     Medicare stays are almost never zero nights. Their dollars stay in
--     inpatient spend, but they don't count as admissions here.
--   * Every claim has discharge status 01 (home), so transfers can't be read
--     from the claim. Claims for the same person that overlap or touch on the
--     same day are merged into one stay instead.

CREATE OR REPLACE TABLE mart.inpatient_stay AS
WITH ip AS (
    SELECT claim_id, bene_id, from_dt, thru_dt, paid_amt, drg_cd, principal_dx, provider_id
    FROM stg.claims
    WHERE claim_type = 'inpatient'
),
-- latest discharge seen so far for this person, not counting the current claim
running AS (
    SELECT
        *,
        MAX(thru_dt) OVER (
            PARTITION BY bene_id
            ORDER BY from_dt, thru_dt, claim_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_thru
    FROM ip
),
-- a claim starts a new stay unless it begins on or before that discharge
islands AS (
    SELECT
        *,
        SUM(CASE WHEN prior_max_thru IS NULL OR from_dt > prior_max_thru THEN 1 ELSE 0 END)
            OVER (PARTITION BY bene_id ORDER BY from_dt, thru_dt, claim_id) AS stay_num
    FROM running
)
SELECT
    bene_id || '-' || stay_num                     AS stay_id,
    bene_id,
    stay_num,
    MIN(from_dt)                                   AS admit_dt,
    MAX(thru_dt)                                   AS discharge_dt,
    MAX(thru_dt) - MIN(from_dt)                    AS los_days,
    MAX(thru_dt) > MIN(from_dt)                    AS is_overnight,
    COUNT(*)                                       AS n_claims,
    SUM(paid_amt)                                  AS paid_amt,
    ARG_MIN(drg_cd, from_dt)                       AS first_drg,
    ARG_MIN(principal_dx, from_dt)                 AS first_principal_dx
FROM islands
GROUP BY bene_id, stay_num;


-- 30-day all-cause readmissions
-- Index stay: overnight, discharged 2015 through 2022, and the person has Part A
-- and B in the discharge month and the month after (so a readmission could show up).
-- Readmission: the next overnight stay admitted 1 to 30 days after discharge.
-- Not done: CMS's planned readmission algorithm. Noted in limitations.
CREATE OR REPLACE TABLE mart.readmission AS
WITH overnight AS (
    SELECT
        *,
        LEAD(admit_dt) OVER (PARTITION BY bene_id ORDER BY admit_dt) AS next_admit_dt,
        LEAD(stay_id)  OVER (PARTITION BY bene_id ORDER BY admit_dt) AS next_stay_id
    FROM mart.inpatient_stay
    WHERE is_overnight
),
ab_months AS (
    SELECT bene_id, month_start
    FROM stg.member_month
    WHERE has_part_a AND has_part_b
)
SELECT
    o.stay_id,
    o.bene_id,
    o.admit_dt,
    o.discharge_dt,
    YEAR(o.discharge_dt)                                        AS discharge_year,
    o.los_days,
    o.paid_amt,
    o.next_admit_dt,
    o.next_admit_dt - o.discharge_dt                            AS days_to_next_admit,
    COALESCE(o.next_admit_dt - o.discharge_dt BETWEEN 1 AND 30, FALSE) AS readmit_30
FROM overnight o
JOIN ab_months m1
    ON m1.bene_id = o.bene_id
   AND m1.month_start = date_trunc('month', o.discharge_dt)
JOIN ab_months m2
    ON m2.bene_id = o.bene_id
   AND m2.month_start = date_trunc('month', o.discharge_dt) + INTERVAL 1 MONTH
WHERE o.discharge_dt BETWEEN DATE '2015-01-01' AND DATE '2022-12-31';


-- Rate by year
SELECT
    discharge_year,
    COUNT(*)                                     AS index_stays,
    SUM(readmit_30::INT)                         AS readmits,
    ROUND(100.0 * AVG(readmit_30::INT), 1)       AS readmit_rate_pct
FROM mart.readmission
GROUP BY discharge_year
ORDER BY discharge_year;
