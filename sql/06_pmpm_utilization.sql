-- 06_pmpm_utilization.sql
-- Cost per member per month (PMPM) and utilization per 1,000 members per year.
--
-- PMPM = Medicare paid dollars / member months.
-- Per 1,000 = events / member months * 12,000 (annualized per 1,000 members).
-- Dollars are Medicare paid (CLM_PMT_AMT), not allowed. The institutional
-- files have no allowed amount, so paid is the only measure available on
-- every claim type. Part D is reported on its own because it has its own
-- denominator (months with a Part D contract) and ACO benchmarks don't include it.

-- member months per year, overall and with the MA-flagged months removed
CREATE OR REPLACE TABLE mart.member_months_by_year AS
SELECT
    year,
    COUNT(*)                                        AS member_months,
    COUNT(*) FILTER (WHERE NOT has_ma_contract)     AS member_months_no_ma,
    COUNT(*) FILTER (WHERE has_part_d)              AS partd_member_months,
    COUNT(DISTINCT bene_id)                         AS members
FROM mart.member_month
GROUP BY year;


-- PMPM by service category and year
CREATE OR REPLACE TABLE mart.pmpm_by_category AS
WITH spend AS (
    SELECT YEAR(service_month) AS year, service_category, SUM(paid_amt) AS paid
    FROM mart.claims_in_window
    GROUP BY ALL
)
SELECT
    s.year,
    s.service_category,
    s.paid,
    m.member_months,
    ROUND(s.paid / m.member_months, 2) AS pmpm
FROM spend s
JOIN mart.member_months_by_year m USING (year)
ORDER BY s.year, s.paid DESC;


-- Total medical PMPM by year, plus the MA sensitivity and Part D on the side
CREATE OR REPLACE TABLE mart.pmpm_by_year AS
WITH medical AS (
    SELECT
        YEAR(service_month)                              AS year,
        SUM(paid_amt)                                    AS paid,
        SUM(paid_amt) FILTER (WHERE NOT has_ma_contract) AS paid_no_ma
    FROM mart.claims_in_window
    GROUP BY 1
),
rx AS (
    SELECT YEAR(p.fill_dt) AS year, SUM(p.plan_paid) AS rx_plan_paid, SUM(p.gross_cost) AS rx_gross
    FROM stg.pde p
    JOIN mart.member_month mm
        ON mm.bene_id = p.bene_id
       AND mm.month_start = date_trunc('month', p.fill_dt)
       AND mm.has_part_d
    GROUP BY 1
)
SELECT
    m.year,
    y.members,
    y.member_months,
    m.paid                                                    AS medical_paid,
    ROUND(m.paid / y.member_months, 2)                        AS medical_pmpm,
    ROUND(m.paid_no_ma / y.member_months_no_ma, 2)            AS medical_pmpm_no_ma_months,
    ROUND(r.rx_plan_paid / y.partd_member_months, 2)          AS partd_plan_paid_pmpm,
    ROUND(100.0 * (m.paid / y.member_months)
          / LAG(m.paid / y.member_months) OVER (ORDER BY m.year) - 100, 1) AS medical_pmpm_change_pct
FROM medical m
JOIN mart.member_months_by_year y USING (year)
LEFT JOIN rx r USING (year)
ORDER BY m.year;


-- PMPM by MSSP enrollment type (2022)
CREATE OR REPLACE TABLE mart.pmpm_by_enrollment_type AS
WITH mm AS (
    SELECT year, enrollment_type, COUNT(*) AS member_months, COUNT(DISTINCT bene_id) AS members
    FROM mart.member_month
    GROUP BY ALL
),
spend AS (
    SELECT YEAR(service_month) AS year, enrollment_type, SUM(paid_amt) AS paid
    FROM mart.claims_in_window
    GROUP BY ALL
)
SELECT
    mm.year,
    mm.enrollment_type,
    mm.members,
    mm.member_months,
    COALESCE(s.paid, 0)                                         AS paid,
    ROUND(COALESCE(s.paid, 0) / mm.member_months, 2)            AS pmpm,
    ROUND(100.0 * mm.member_months / SUM(mm.member_months) OVER (PARTITION BY mm.year), 1) AS pct_of_member_months,
    ROUND(100.0 * COALESCE(s.paid, 0) / SUM(s.paid) OVER (PARTITION BY mm.year), 1)        AS pct_of_spend
FROM mm
LEFT JOIN spend s USING (year, enrollment_type)
ORDER BY mm.year, pmpm DESC;


-- Utilization per 1,000 by year
-- No ED measure: the outpatient file has no ER revenue codes (045x, 0981) and the
-- carrier file has no ER visit codes (99281-99285) or place of service 23.
-- See qa_log entry 15.
CREATE OR REPLACE TABLE mart.utilization_by_year AS
WITH ab AS (
    SELECT bene_id, month_start FROM mart.member_month
),
stays AS (
    SELECT YEAR(s.admit_dt) AS year,
           COUNT(*) FILTER (WHERE s.is_overnight)                AS overnight_admits,
           SUM(s.los_days) FILTER (WHERE s.is_overnight)         AS inpatient_days,
           COUNT(*) FILTER (WHERE NOT s.is_overnight)            AS same_day_stays
    FROM mart.inpatient_stay s
    JOIN ab ON ab.bene_id = s.bene_id AND ab.month_start = date_trunc('month', s.admit_dt)
    GROUP BY 1
),
other AS (
    SELECT YEAR(service_month) AS year,
           SUM(covered_days) FILTER (WHERE claim_type = 'snf')            AS snf_days,
           COUNT(*) FILTER (WHERE service_category = 'Outpatient dialysis') AS dialysis_claims,
           COUNT(*) FILTER (WHERE service_category = 'Outpatient other')    AS outpatient_other_claims,
           COUNT(*) FILTER (WHERE claim_type = 'carrier')                   AS professional_claims
    FROM mart.claims_in_window
    GROUP BY 1
),
readmits AS (
    SELECT discharge_year AS year, ROUND(100.0 * AVG(readmit_30::INT), 1) AS readmit_rate_pct
    FROM mart.readmission
    GROUP BY 1
)
SELECT
    y.year,
    y.member_months,
    ROUND(s.overnight_admits        * 12000.0 / y.member_months, 1) AS admits_per_1000,
    ROUND(s.inpatient_days          * 12000.0 / y.member_months, 1) AS inpatient_days_per_1000,
    ROUND(s.same_day_stays          * 12000.0 / y.member_months, 1) AS same_day_inpatient_per_1000,
    ROUND(o.snf_days                * 12000.0 / y.member_months, 1) AS snf_days_per_1000,
    ROUND(o.dialysis_claims         * 12000.0 / y.member_months, 1) AS dialysis_claims_per_1000,
    ROUND(o.outpatient_other_claims * 12000.0 / y.member_months, 1) AS outpatient_visits_per_1000,
    ROUND(o.professional_claims     * 12000.0 / y.member_months, 1) AS professional_claims_per_1000,
    r.readmit_rate_pct
FROM mart.member_months_by_year y
JOIN stays s USING (year)
JOIN other o USING (year)
LEFT JOIN readmits r USING (year)
ORDER BY y.year;


SELECT * FROM mart.pmpm_by_year;
SELECT * FROM mart.utilization_by_year;
