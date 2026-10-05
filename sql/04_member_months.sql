-- 04_member_months.sql
-- The denominator for every rate in this project.
--
-- Decisions (qa_log entries 7, 8, 16):
--   * A member month needs both Part A and Part B. Someone with Part A only
--     shouldn't have doctor or outpatient claims, so mixing those months in
--     would pull PMPM down for no real reason. ACOs count assigned months the
--     same way. This drops about 6% of months.
--   * Window is Jan 2015 to Dec 2022. Claims stop in early March 2023, and
--     2024-2025 enrollment has no claims at all.
--   * The MA contract flag is kept, not filtered. In this synthetic data about
--     60% of FFS claims land in months with a Part C contract, which can't
--     happen in real Medicare. I treat the population as traditional Medicare
--     and show the no-MA months as a sensitivity check in 06.
--   * Enrollment type follows the four groups MSSP uses for ACO benchmarks:
--     ESRD, disabled, aged dual, aged non-dual.

CREATE SCHEMA IF NOT EXISTS mart;

CREATE OR REPLACE TABLE mart.member_month AS
SELECT
    bene_id,
    month_start,
    year,
    age_end_of_year,
    sex_cd,
    state_cd,
    is_dual,
    is_esrd,
    has_ma_contract,
    has_part_d,
    CASE
        WHEN is_esrd                  THEN 'ESRD'
        WHEN mdcr_status_cd = '20'    THEN 'Disabled'
        WHEN is_dual                  THEN 'Aged dual'
        ELSE                               'Aged non-dual'
    END AS enrollment_type
FROM stg.member_month
WHERE has_part_a
  AND has_part_b
  AND month_start BETWEEN DATE '2015-01-01' AND DATE '2022-12-01';


-- Claims matched to a member month. Claims are dated by their from date.
-- Anything that falls outside an A and B month is counted in qa_checks.sql
-- and left out of PMPM, so numerator and denominator cover the same months.
CREATE OR REPLACE TABLE mart.claims_in_window AS
SELECT
    c.*,
    mm.enrollment_type,
    mm.has_ma_contract
FROM stg.claims c
JOIN mart.member_month mm
    ON  mm.bene_id = c.bene_id
    AND mm.month_start = c.service_month;


-- Quick look: members, member months, and how many members per year
SELECT
    year,
    COUNT(DISTINCT bene_id)                               AS members,
    COUNT(*)                                              AS member_months,
    ROUND(COUNT(*) / COUNT(DISTINCT bene_id), 1)          AS avg_months_per_member,
    ROUND(100.0 * AVG(has_ma_contract::INT), 1)           AS pct_months_with_ma_flag,
    ROUND(100.0 * AVG((enrollment_type = 'ESRD')::INT), 1) AS pct_esrd
FROM mart.member_month
GROUP BY year
ORDER BY year;
