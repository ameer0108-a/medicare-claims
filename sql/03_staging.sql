-- 03_staging.sql
-- Turns the raw text tables into typed tables I can analyze.
--   stg.claims        one row per claim, all 7 claim files stacked
--   stg.claim_dx      one row per claim per diagnosis code
--   stg.pde           one row per Part D fill, with drug class flags
--   stg.member_month  one row per person per enrolled month
--
-- Header fields (dates, payment, diagnoses) repeat on every line of a claim.
-- They never change within a claim (qa_log entry 9), so ANY_VALUE() per claim
-- is safe. A header field should never be SUMmed across lines.

CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS ref;

-- try_strptime returns NULL instead of erroring. qa_checks.sql counts NULL
-- dates so a bad value can't slip through quietly.
CREATE OR REPLACE MACRO cms_date(s) AS CAST(try_strptime(s, '%d-%b-%Y') AS DATE);
CREATE OR REPLACE MACRO money(s) AS TRY_CAST(s AS DECIMAL(12, 2));


-- Reference tables ------------------------------------------------------------

-- NDC9 (labeler + product) to drug class. Built from RxNorm, see docs/measure_specs.md
CREATE OR REPLACE TABLE ref.ndc_drug_class AS
SELECT * FROM read_csv('ref/ndc_drug_class.csv', header = true, types = {'ndc9': 'VARCHAR'});

CREATE OR REPLACE TABLE ref.chronic_condition_codes AS
SELECT * FROM read_csv('ref/chronic_condition_codes.csv', header = true, all_varchar = true);


-- Claims ----------------------------------------------------------------------

CREATE OR REPLACE TABLE stg.claims AS
WITH inpatient AS (
    SELECT
        CLM_ID                                   AS claim_id,
        ANY_VALUE(BENE_ID)                       AS bene_id,
        'inpatient'                              AS claim_type,
        cms_date(ANY_VALUE(CLM_FROM_DT))         AS from_dt,
        cms_date(ANY_VALUE(CLM_THRU_DT))         AS thru_dt,
        cms_date(ANY_VALUE(CLM_ADMSN_DT))        AS admit_dt,
        cms_date(ANY_VALUE(NCH_BENE_DSCHRG_DT))  AS discharge_dt,
        money(ANY_VALUE(CLM_PMT_AMT))            AS paid_amt,
        money(ANY_VALUE(CLM_TOT_CHRG_AMT))       AS charge_amt,
        ANY_VALUE(PRNCPAL_DGNS_CD)               AS principal_dx,
        ANY_VALUE(CLM_DRG_CD)                    AS drg_cd,
        ANY_VALUE(PRVDR_NUM)                     AS provider_id,
        TRY_CAST(ANY_VALUE(CLM_UTLZTN_DAY_CNT) AS INTEGER) AS covered_days,
        FALSE                                    AS is_dialysis,
        COUNT(*)                                 AS n_lines
    FROM raw.inpatient
    GROUP BY CLM_ID
),
outpatient AS (
    SELECT
        CLM_ID, ANY_VALUE(BENE_ID), 'outpatient',
        cms_date(ANY_VALUE(CLM_FROM_DT)), cms_date(ANY_VALUE(CLM_THRU_DT)),
        NULL, NULL,
        money(ANY_VALUE(CLM_PMT_AMT)), money(ANY_VALUE(CLM_TOT_CHRG_AMT)),
        ANY_VALUE(PRNCPAL_DGNS_CD), NULL, ANY_VALUE(PRVDR_NUM), NULL,
        -- revenue centers are all '0001' in this data (qa_log entry 15),
        -- so dialysis has to be found by HCPCS code instead
        BOOL_OR(HCPCS_CD IN ('90935', '90937', '90945', '90947', '90999')),
        COUNT(*)
    FROM raw.outpatient
    GROUP BY CLM_ID
),
snf AS (
    SELECT
        CLM_ID, ANY_VALUE(BENE_ID), 'snf',
        cms_date(ANY_VALUE(CLM_FROM_DT)), cms_date(ANY_VALUE(CLM_THRU_DT)),
        cms_date(ANY_VALUE(CLM_ADMSN_DT)), cms_date(ANY_VALUE(NCH_BENE_DSCHRG_DT)),
        money(ANY_VALUE(CLM_PMT_AMT)), money(ANY_VALUE(CLM_TOT_CHRG_AMT)),
        ANY_VALUE(PRNCPAL_DGNS_CD), ANY_VALUE(CLM_DRG_CD), ANY_VALUE(PRVDR_NUM),
        TRY_CAST(ANY_VALUE(CLM_UTLZTN_DAY_CNT) AS INTEGER),
        FALSE, COUNT(*)
    FROM raw.snf
    GROUP BY CLM_ID
),
hha AS (
    SELECT
        CLM_ID, ANY_VALUE(BENE_ID), 'hha',
        cms_date(ANY_VALUE(CLM_FROM_DT)), cms_date(ANY_VALUE(CLM_THRU_DT)),
        cms_date(ANY_VALUE(CLM_ADMSN_DT)), NULL,
        money(ANY_VALUE(CLM_PMT_AMT)), money(ANY_VALUE(CLM_TOT_CHRG_AMT)),
        ANY_VALUE(PRNCPAL_DGNS_CD), NULL, ANY_VALUE(PRVDR_NUM), NULL,
        FALSE, COUNT(*)
    FROM raw.hha
    GROUP BY CLM_ID
),
hospice AS (
    SELECT
        CLM_ID, ANY_VALUE(BENE_ID), 'hospice',
        cms_date(ANY_VALUE(CLM_FROM_DT)), cms_date(ANY_VALUE(CLM_THRU_DT)),
        NULL, cms_date(ANY_VALUE(NCH_BENE_DSCHRG_DT)),
        money(ANY_VALUE(CLM_PMT_AMT)), money(ANY_VALUE(CLM_TOT_CHRG_AMT)),
        ANY_VALUE(PRNCPAL_DGNS_CD), NULL, ANY_VALUE(PRVDR_NUM),
        TRY_CAST(ANY_VALUE(CLM_UTLZTN_DAY_CNT) AS INTEGER),
        FALSE, COUNT(*)
    FROM raw.hospice
    GROUP BY CLM_ID
),
carrier AS (
    SELECT
        CLM_ID, ANY_VALUE(BENE_ID), 'carrier',
        cms_date(ANY_VALUE(CLM_FROM_DT)), cms_date(ANY_VALUE(CLM_THRU_DT)),
        NULL, NULL,
        money(ANY_VALUE(CLM_PMT_AMT)), money(ANY_VALUE(NCH_CARR_CLM_SBMTD_CHRG_AMT)),
        ANY_VALUE(PRNCPAL_DGNS_CD), NULL, ANY_VALUE(CARR_CLM_BLG_NPI_NUM), NULL,
        FALSE, COUNT(*)
    FROM raw.carrier
    GROUP BY CLM_ID
),
dme AS (
    SELECT
        CLM_ID, ANY_VALUE(BENE_ID), 'dme',
        cms_date(ANY_VALUE(CLM_FROM_DT)), cms_date(ANY_VALUE(CLM_THRU_DT)),
        NULL, NULL,
        money(ANY_VALUE(CLM_PMT_AMT)), money(ANY_VALUE(NCH_CARR_CLM_SBMTD_CHRG_AMT)),
        ANY_VALUE(PRNCPAL_DGNS_CD), NULL, ANY_VALUE(PRVDR_NUM), NULL,
        FALSE, COUNT(*)
    FROM raw.dme
    GROUP BY CLM_ID
),
stacked AS (
    SELECT * FROM inpatient
    UNION ALL SELECT * FROM outpatient
    UNION ALL SELECT * FROM snf
    UNION ALL SELECT * FROM hha
    UNION ALL SELECT * FROM hospice
    UNION ALL SELECT * FROM carrier
    UNION ALL SELECT * FROM dme
)
SELECT
    *,
    CASE claim_type
        WHEN 'inpatient'  THEN 'Inpatient'
        WHEN 'outpatient' THEN CASE WHEN is_dialysis THEN 'Outpatient dialysis' ELSE 'Outpatient other' END
        WHEN 'carrier'    THEN 'Professional'
        WHEN 'snf'        THEN 'SNF'
        WHEN 'hha'        THEN 'Home health'
        WHEN 'hospice'    THEN 'Hospice'
        WHEN 'dme'        THEN 'DME'
    END AS service_category,
    date_trunc('month', from_dt)::DATE AS service_month
FROM stacked;


-- Diagnosis codes, long format -------------------------------------------------
-- Wide columns (ICD_DGNS_CD1 to 25) are hard to search, so I unpivot them.
-- The principal diagnosis usually repeats as ICD_DGNS_CD1; GROUP BY removes the repeat.

CREATE OR REPLACE TABLE stg.claim_dx AS
WITH wide AS (
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.inpatient  GROUP BY CLM_ID
    UNION ALL BY NAME
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.outpatient GROUP BY CLM_ID
    UNION ALL BY NAME
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.snf        GROUP BY CLM_ID
    UNION ALL BY NAME
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.hha        GROUP BY CLM_ID
    UNION ALL BY NAME
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.hospice    GROUP BY CLM_ID
    UNION ALL BY NAME
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.carrier    GROUP BY CLM_ID
    UNION ALL BY NAME
    SELECT CLM_ID AS claim_id, ANY_VALUE(PRNCPAL_DGNS_CD) AS principal, ANY_VALUE(COLUMNS('^ICD_DGNS_CD\d+$')) FROM raw.dme        GROUP BY CLM_ID
),
long AS (
    UNPIVOT wide
    ON COLUMNS(* EXCLUDE (claim_id))
    INTO NAME dx_position VALUE dx_code
)
SELECT
    l.claim_id,
    c.bene_id,
    c.claim_type,
    c.from_dt,
    l.dx_code,
    BOOL_OR(l.dx_position = 'principal') AS is_principal
FROM long l
JOIN stg.claims c USING (claim_id)
WHERE l.dx_code <> ''
GROUP BY ALL;


-- Part D fills -----------------------------------------------------------------

CREATE OR REPLACE TABLE stg.pde AS
SELECT
    p.PDE_ID                                        AS pde_id,
    p.BENE_ID                                       AS bene_id,
    cms_date(p.SRVC_DT)                             AS fill_dt,
    p.PROD_SRVC_ID                                  AS ndc11,
    LEFT(p.PROD_SRVC_ID, 9)                         AS ndc9,
    CAST(p.DAYS_SUPLY_NUM AS INTEGER)               AS days_supply,
    TRY_CAST(p.QTY_DSPNSD_NUM AS DOUBLE)            AS qty,
    money(p.TOT_RX_CST_AMT)                         AS gross_cost,
    COALESCE(money(p.CVRD_D_PLAN_PD_AMT), 0)
      + COALESCE(money(p.NCVRD_PLAN_PD_AMT), 0)     AS plan_paid,
    money(p.PTNT_PAY_AMT)                           AS patient_pay,
    p.BRND_GNRC_CD                                  AS brand_generic,
    COALESCE(d.is_statin, 0) = 1                    AS is_statin,
    COALESCE(d.is_rasa, 0) = 1                      AS is_rasa,
    COALESCE(d.is_diabetes, 0) = 1                  AS is_diabetes,
    COALESCE(d.is_insulin, 0) = 1                   AS is_insulin,
    COALESCE(d.is_sacubitril, 0) = 1                AS is_sacubitril,
    d.ingredients
FROM raw.pde p
LEFT JOIN ref.ndc_drug_class d
    ON d.ndc9 = LEFT(p.PROD_SRVC_ID, 9);


-- Member months ----------------------------------------------------------------
-- The beneficiary file has one row per person per year with 12 columns per
-- monthly field (_01 to _12). I pack each set into a list, then pull out one
-- element per month.
--   buy-in: 1 = Part A only, 2 = Part B only, 3 = A and B, A/B/C = same with state buy-in
--   status: 10 aged, 20 disabled, 11/21/31 = with ESRD

CREATE OR REPLACE TABLE stg.member_month AS
WITH by_year AS (
    SELECT
        BENE_ID                                           AS bene_id,
        CAST(BENE_ENROLLMT_REF_YR AS INTEGER)             AS yr,
        cms_date(BENE_BIRTH_DT)                           AS birth_dt,
        TRY_CAST(AGE_AT_END_REF_YR AS INTEGER)            AS age_end_of_year,
        SEX_IDENT_CD                                      AS sex_cd,
        STATE_CODE                                        AS state_cd,
        ESRD_IND = 'Y'                                    AS esrd_ind,
        list_value(*COLUMNS('^MDCR_ENTLMT_BUYIN_IND_\d\d$')) AS buyin,
        list_value(*COLUMNS('^MDCR_STATUS_CODE_\d\d$'))      AS mdcr_status,
        list_value(*COLUMNS('^PTC_CNTRCT_ID_\d\d$'))         AS ma_contract,
        list_value(*COLUMNS('^PTD_CNTRCT_ID_\d\d$'))         AS partd_contract,
        list_value(*COLUMNS('^DUAL_STUS_CD_\d\d$'))          AS dual_status
    FROM raw.beneficiary
)
SELECT
    bene_id,
    make_date(yr, CAST(m AS INTEGER), 1)                       AS month_start,
    yr                                                          AS year,
    age_end_of_year,
    sex_cd,
    state_cd,
    buyin[m]                                                    AS buyin_cd,
    buyin[m] IN ('1', '3', 'A', 'C')                            AS has_part_a,
    buyin[m] IN ('2', '3', 'B', 'C')                            AS has_part_b,
    COALESCE(ma_contract[m], '') NOT IN ('', '0', 'N')          AS has_ma_contract,
    COALESCE(partd_contract[m], '') NOT IN ('', '0', 'N', 'X')  AS has_part_d,
    COALESCE(dual_status[m], 'NA') NOT IN ('NA', '00', '99')    AS is_dual,
    mdcr_status[m]                                              AS mdcr_status_cd,
    mdcr_status[m] IN ('11', '21', '31') OR esrd_ind            AS is_esrd
FROM by_year
CROSS JOIN range(1, 13) AS t(m)
WHERE buyin[m] IS NOT NULL
  AND buyin[m] <> '0';
