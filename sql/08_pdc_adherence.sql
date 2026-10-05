-- 08_pdc_adherence.sql
-- Proportion of days covered (PDC) for the three Part D Star adherence measures:
-- statins, RAS antagonists (blood pressure), and non-insulin diabetes meds.
-- Follows the PQA method as published. PQA's official NDC lists are licensed,
-- so ref/ndc_drug_class.csv is my own list built from RxNorm (see
-- docs/measure_specs.md for every rule and where I simplified).
--
-- Denominator, per measure and calendar year:
--   * 2+ fills of the class on different dates in the year
--   * first fill (index date) at least 91 days before Dec 31
--   * Part D coverage in the index month; the period ends at Dec 31 or the
--     last Part D month, whichever comes first
--   * age 18+, no hospice claim in the year, no ESRD month in the year
--   * diabetes: no insulin fill in the year
--   * RAS antagonists: no sacubitril/valsartan fill in the year
-- Numerator: days covered / days in the period. Adherent = PDC of 80% or more.

CREATE OR REPLACE TABLE mart.pdc_fills AS
WITH tagged AS (
    SELECT bene_id, fill_dt, days_supply, ingredients, 'Statins' AS measure FROM stg.pde WHERE is_statin
    UNION ALL
    SELECT bene_id, fill_dt, days_supply, ingredients, 'RAS antagonists' FROM stg.pde WHERE is_rasa
    UNION ALL
    SELECT bene_id, fill_dt, days_supply, ingredients, 'Diabetes' FROM stg.pde WHERE is_diabetes
)
-- same drug, same person, same day: keep the longest days supply (PQA rule)
SELECT
    bene_id,
    measure,
    ingredients,
    YEAR(fill_dt)       AS year,
    fill_dt,
    MAX(days_supply)    AS days_supply
FROM tagged
WHERE YEAR(fill_dt) BETWEEN 2015 AND 2022
GROUP BY ALL;


-- Who is in the denominator, and their treatment period
CREATE OR REPLACE TABLE mart.pdc_denominator AS
WITH firsts AS (
    SELECT
        bene_id, measure, year,
        MIN(fill_dt)               AS index_dt,
        COUNT(DISTINCT fill_dt)    AS fill_dates
    FROM mart.pdc_fills
    GROUP BY ALL
),
partd AS (
    SELECT bene_id, year,
           LIST(month_start ORDER BY month_start) FILTER (WHERE has_part_d) AS partd_months,
           MAX(month_start) FILTER (WHERE has_part_d)                       AS last_partd_month,
           BOOL_OR(is_esrd)                                                 AS any_esrd,
           MAX(age_end_of_year)                                             AS age_end_of_year
    FROM stg.member_month
    GROUP BY ALL
),
hospice AS (
    SELECT DISTINCT bene_id, YEAR(from_dt) AS year FROM stg.claims WHERE claim_type = 'hospice'
),
insulin AS (
    SELECT DISTINCT bene_id, YEAR(fill_dt) AS year FROM stg.pde WHERE is_insulin
),
sacubitril AS (
    SELECT DISTINCT bene_id, YEAR(fill_dt) AS year FROM stg.pde WHERE is_sacubitril
)
SELECT
    f.bene_id,
    f.measure,
    f.year,
    f.index_dt,
    f.fill_dates,
    LEAST(make_date(f.year, 12, 31), last_day(p.last_partd_month)) AS period_end,
    LEAST(make_date(f.year, 12, 31), last_day(p.last_partd_month)) - f.index_dt + 1 AS period_days,
    -- each exclusion kept as a column so I can count who dropped out and why
    f.fill_dates >= 2                                                   AS has_two_fills,
    f.index_dt <= make_date(f.year, 12, 31) - 91                        AS index_early_enough,
    list_contains(p.partd_months, date_trunc('month', f.index_dt)::DATE) AS partd_at_index,
    COALESCE(p.age_end_of_year, 0) >= 19                                AS age_18_plus,
    h.bene_id IS NOT NULL                                               AS excl_hospice,
    COALESCE(p.any_esrd, FALSE)                                         AS excl_esrd,
    f.measure = 'Diabetes'        AND i.bene_id IS NOT NULL             AS excl_insulin,
    f.measure = 'RAS antagonists' AND s.bene_id IS NOT NULL             AS excl_sacubitril
FROM firsts f
LEFT JOIN partd p      USING (bene_id, year)
LEFT JOIN hospice h    USING (bene_id, year)
LEFT JOIN insulin i    USING (bene_id, year)
LEFT JOIN sacubitril s USING (bene_id, year);


-- Days covered.
-- Early refills of the same drug get pushed forward so the leftover pills are
-- counted after the current supply runs out, not double counted. The window
-- trick: a fill's shifted end date = (latest of fill_date minus supply already
-- dispensed before it) + all supply dispensed so far - 1. Worked example in
-- docs/measure_specs.md.
CREATE OR REPLACE TABLE mart.pdc_result AS
WITH eligible AS (
    SELECT *
    FROM mart.pdc_denominator
    WHERE has_two_fills AND index_early_enough AND partd_at_index AND age_18_plus
      AND NOT excl_hospice AND NOT excl_esrd AND NOT excl_insulin AND NOT excl_sacubitril
),
running AS (
    SELECT
        f.bene_id, f.measure, f.year, f.ingredients, f.fill_dt, f.days_supply,
        CAST(SUM(f.days_supply) OVER (
            PARTITION BY f.bene_id, f.measure, f.year, f.ingredients
            ORDER BY f.fill_dt
            ROWS UNBOUNDED PRECEDING
        ) AS INTEGER) AS supply_through_this_fill
    FROM mart.pdc_fills f
    JOIN eligible e
        ON  e.bene_id = f.bene_id
        AND e.measure = f.measure
        AND e.year = f.year
),
shifted AS (
    SELECT
        *,
        MAX(fill_dt - (supply_through_this_fill - days_supply)) OVER (
            PARTITION BY bene_id, measure, year, ingredients
            ORDER BY fill_dt
            ROWS UNBOUNDED PRECEDING
        ) + (supply_through_this_fill - 1) AS adj_end
    FROM running
),
covered_days AS (
    -- one row per covered day; DISTINCT handles overlap between different drugs in a class
    SELECT DISTINCT
        s.bene_id, s.measure, s.year,
        CAST(UNNEST(generate_series(s.adj_end - (s.days_supply - 1), s.adj_end, INTERVAL 1 DAY)) AS DATE) AS covered_day
    FROM shifted s
)
SELECT
    e.bene_id,
    e.measure,
    e.year,
    e.index_dt,
    e.period_end,
    e.period_days,
    COUNT(c.covered_day)                                     AS days_covered,
    ROUND(COUNT(c.covered_day) / e.period_days, 4)           AS pdc,
    COUNT(c.covered_day) / e.period_days >= 0.8              AS is_adherent
FROM eligible e
LEFT JOIN covered_days c
    ON  c.bene_id = e.bene_id
    AND c.measure = e.measure
    AND c.year = e.year
    AND c.covered_day BETWEEN e.index_dt AND e.period_end
GROUP BY e.bene_id, e.measure, e.year, e.index_dt, e.period_end, e.period_days;


-- Measure rates by year
CREATE OR REPLACE TABLE mart.pdc_rates AS
SELECT
    measure,
    year,
    COUNT(*)                                      AS denominator,
    SUM(is_adherent::INT)                         AS adherent,
    ROUND(100.0 * AVG(is_adherent::INT), 1)       AS adherence_rate_pct,
    ROUND(100.0 * MEDIAN(pdc), 1)                 AS median_pdc_pct,
    COUNT(*) FILTER (WHERE pdc >= 0.6 AND pdc < 0.8) AS near_miss_60_79,
    COUNT(*) FILTER (WHERE pdc < 0.6)             AS below_60
FROM mart.pdc_result
GROUP BY ALL
ORDER BY measure, year;


-- Exclusion waterfall for the most recent year (goes in the QA log)
CREATE OR REPLACE TABLE mart.pdc_waterfall AS
SELECT
    measure,
    COUNT(*)                                                                       AS any_fill,
    COUNT(*) FILTER (WHERE has_two_fills)                                          AS two_plus_fills,
    COUNT(*) FILTER (WHERE has_two_fills AND index_early_enough)                   AS index_by_oct_1,
    COUNT(*) FILTER (WHERE has_two_fills AND index_early_enough AND partd_at_index AND age_18_plus) AS enrolled_and_18,
    COUNT(*) FILTER (WHERE has_two_fills AND index_early_enough AND partd_at_index AND age_18_plus
                       AND NOT excl_hospice AND NOT excl_esrd)                     AS after_hospice_esrd,
    COUNT(*) FILTER (WHERE has_two_fills AND index_early_enough AND partd_at_index AND age_18_plus
                       AND NOT excl_hospice AND NOT excl_esrd
                       AND NOT excl_insulin AND NOT excl_sacubitril)               AS final_denominator
FROM mart.pdc_denominator
WHERE year = 2022
GROUP BY measure;


SELECT * FROM mart.pdc_waterfall;
SELECT * FROM mart.pdc_rates WHERE year >= 2020;
