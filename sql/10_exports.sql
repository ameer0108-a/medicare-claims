-- 10_exports.sql
-- Writes the summary tables out for the dashboard (docs/data, JSON) and for
-- Tableau or Excel (exports, CSV). Everything here is aggregated except the
-- outreach worklist and member_year, which use synthetic IDs only.

-- CSV extracts
COPY (SELECT * FROM mart.pmpm_by_year ORDER BY year)                         TO 'exports/pmpm_by_year.csv'            (HEADER);
COPY (SELECT * FROM mart.pmpm_by_category ORDER BY year, service_category)   TO 'exports/pmpm_by_category.csv'        (HEADER);
COPY (SELECT * FROM mart.pmpm_by_enrollment_type ORDER BY year, enrollment_type) TO 'exports/pmpm_by_enrollment_type.csv' (HEADER);
COPY (SELECT * FROM mart.utilization_by_year ORDER BY year)                  TO 'exports/utilization_by_year.csv'     (HEADER);
COPY (SELECT * FROM mart.spend_concentration ORDER BY year)                  TO 'exports/spend_concentration.csv'     (HEADER);
COPY (SELECT * FROM mart.top5_profile)                                       TO 'exports/top5_profile_2022.csv'       (HEADER);
COPY (SELECT * FROM mart.top5_persistence)                                   TO 'exports/top5_persistence_2021_2022.csv' (HEADER);
COPY (SELECT * FROM mart.cohort_summary)                                     TO 'exports/cohort_summary_2022.csv'     (HEADER);
COPY (SELECT * FROM mart.pdc_rates ORDER BY measure, year)                   TO 'exports/pdc_rates.csv'               (HEADER);
COPY (SELECT * FROM mart.pdc_waterfall)                                      TO 'exports/pdc_waterfall_2022.csv'      (HEADER);
COPY (SELECT * FROM mart.adherence_outreach_list)                            TO 'exports/adherence_outreach_list_2022.csv' (HEADER);
COPY (SELECT * FROM mart.roi_inputs)                                         TO 'exports/roi_inputs.csv'              (HEADER);
COPY (SELECT * FROM mart.qa_results)                                         TO 'exports/qa_results.csv'              (HEADER);

-- member-level table for Tableau (one row per member per year)
COPY (
    SELECT bene_id, year, enrollment_type, age, member_months, medical_paid, dialysis_paid,
           inpatient_paid, overnight_admits, has_diabetes, has_heart_failure, has_copd, has_ckd,
           cost_rank, members_in_year
    FROM mart.member_year_ranked
    ORDER BY year, cost_rank
) TO 'exports/member_year.csv' (HEADER);

-- PDC distribution in 10-point bands, for the adherence chart
CREATE OR REPLACE TABLE mart.pdc_bands AS
SELECT
    measure,
    CASE
        WHEN pdc < 0.4 THEN 'Under 40%'
        WHEN pdc < 0.6 THEN '40-59%'
        WHEN pdc < 0.8 THEN '60-79%'
        ELSE '80%+'
    END AS pdc_band,
    COUNT(*) AS members
FROM mart.pdc_result
WHERE year = 2022
GROUP BY ALL;
COPY (SELECT * FROM mart.pdc_bands ORDER BY measure, pdc_band) TO 'exports/pdc_bands_2022.csv' (HEADER);

-- JSON for the web dashboard
COPY (SELECT * FROM mart.pmpm_by_year ORDER BY year)                        TO 'docs/data/pmpm_by_year.json'          (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.pmpm_by_category ORDER BY year, service_category)  TO 'docs/data/pmpm_by_category.json'      (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.pmpm_by_enrollment_type WHERE year = 2022)         TO 'docs/data/enrollment_type_2022.json'  (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.utilization_by_year ORDER BY year)                 TO 'docs/data/utilization_by_year.json'   (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.spend_concentration ORDER BY year)                 TO 'docs/data/spend_concentration.json'   (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.top5_persistence)                                  TO 'docs/data/top5_persistence.json'      (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.cohort_summary)                                    TO 'docs/data/cohort_summary.json'        (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.pdc_rates ORDER BY measure, year)                  TO 'docs/data/pdc_rates.json'             (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.pdc_bands)                                         TO 'docs/data/pdc_bands.json'             (FORMAT JSON, ARRAY true);
COPY (SELECT * FROM mart.roi_inputs)                                        TO 'docs/data/roi_inputs.json'            (FORMAT JSON, ARRAY true);
