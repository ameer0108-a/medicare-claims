-- 09_outreach_targets.sql
-- Turns the measures into two candidate programs and the inputs for the ROI
-- model (model/outreach_roi.xlsx).
--
-- Program A: pharmacy outreach to adherence "near misses", PDC 60 to 79% in 2022.
--   They're close enough that one or two on-time refills gets them over 80%.
-- Program B: care management for last year's high-cost members, excluding ESRD.
--   ESRD cost is driven by dialysis and is better handled by a kidney care
--   program. To see what the target group does the next year without help,
--   I follow the 2021 top 5% into 2022.

-- Program A list, prioritized by how many covered days short of 80% they were
CREATE OR REPLACE TABLE mart.adherence_outreach_list AS
WITH last_fill AS (
    SELECT bene_id, measure, year, MAX(fill_dt) AS last_fill_dt, ANY_VALUE(ingredients) AS drug
    FROM mart.pdc_fills
    GROUP BY ALL
)
SELECT
    r.measure,
    r.bene_id,
    l.drug,
    r.pdc,
    CAST(CEIL(0.8 * r.period_days) AS INTEGER) - r.days_covered   AS days_short_of_80,
    l.last_fill_dt,
    ROW_NUMBER() OVER (PARTITION BY r.measure ORDER BY CEIL(0.8 * r.period_days) - r.days_covered, r.bene_id) AS priority
FROM mart.pdc_result r
JOIN last_fill l USING (bene_id, measure, year)
WHERE r.year = 2022
  AND r.pdc >= 0.6
  AND r.pdc < 0.8
ORDER BY r.measure, priority;


-- Program B: the 2021 top 5% (non-ESRD) and what happened to them in 2022
CREATE OR REPLACE TABLE mart.care_mgmt_followup AS
WITH y1 AS (
    SELECT bene_id, medical_paid AS paid_2021, overnight_admits AS admits_2021
    FROM mart.member_year_ranked
    WHERE year = 2021
      AND 100.0 * cost_rank / members_in_year <= 5
      AND enrollment_type <> 'ESRD'
)
SELECT
    y1.*,
    y2.medical_paid      AS paid_2022,
    y2.overnight_admits  AS admits_2022,
    y2.member_months     AS member_months_2022
FROM y1
JOIN mart.member_year y2
    ON y2.bene_id = y1.bene_id
   AND y2.year = 2022;


-- Every number the Excel model pulls from the data, in one place
CREATE OR REPLACE TABLE mart.roi_inputs AS
SELECT 'Statins: 2022 denominator' AS input, COUNT(*)::DOUBLE AS value FROM mart.pdc_result WHERE year = 2022 AND measure = 'Statins'
UNION ALL SELECT 'Statins: near misses (PDC 60-79%)', COUNT(*) FROM mart.adherence_outreach_list WHERE measure = 'Statins'
UNION ALL SELECT 'Statins: 2022 adherent', SUM(is_adherent::INT) FROM mart.pdc_result WHERE year = 2022 AND measure = 'Statins'
UNION ALL SELECT 'RAS antagonists: 2022 denominator', COUNT(*) FROM mart.pdc_result WHERE year = 2022 AND measure = 'RAS antagonists'
UNION ALL SELECT 'RAS antagonists: near misses (PDC 60-79%)', COUNT(*) FROM mart.adherence_outreach_list WHERE measure = 'RAS antagonists'
UNION ALL SELECT 'RAS antagonists: 2022 adherent', SUM(is_adherent::INT) FROM mart.pdc_result WHERE year = 2022 AND measure = 'RAS antagonists'
UNION ALL SELECT 'Diabetes: 2022 denominator', COUNT(*) FROM mart.pdc_result WHERE year = 2022 AND measure = 'Diabetes'
UNION ALL SELECT 'Diabetes: near misses (PDC 60-79%)', COUNT(*) FROM mart.adherence_outreach_list WHERE measure = 'Diabetes'
UNION ALL SELECT 'Diabetes: 2022 adherent', SUM(is_adherent::INT) FROM mart.pdc_result WHERE year = 2022 AND measure = 'Diabetes'
UNION ALL SELECT 'Care mgmt: 2021 top 5% non-ESRD members', COUNT(*) FROM mart.care_mgmt_followup
UNION ALL SELECT 'Care mgmt: their overnight admits in 2022', SUM(admits_2022) FROM mart.care_mgmt_followup
UNION ALL SELECT 'Care mgmt: their avg paid in 2021', ROUND(AVG(paid_2021), 0) FROM mart.care_mgmt_followup
UNION ALL SELECT 'Care mgmt: their avg paid in 2022', ROUND(AVG(paid_2022), 0) FROM mart.care_mgmt_followup
UNION ALL SELECT 'Overnight stay paid, 2022 mean', ROUND(AVG(paid_amt), 0) FROM mart.inpatient_stay WHERE is_overnight AND YEAR(admit_dt) = 2022
UNION ALL SELECT 'Overnight stay paid, 2022 median', ROUND(MEDIAN(paid_amt), 0) FROM mart.inpatient_stay WHERE is_overnight AND YEAR(admit_dt) = 2022;

SELECT * FROM mart.roi_inputs;
