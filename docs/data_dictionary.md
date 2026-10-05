# Data dictionary

Tables built by `build.sql`, by schema. Row counts are from the current build. The `raw` schema is the CMS files exactly as shipped (all text) and is documented in the CMS codebooks, so it isn't repeated here.

Conventions: `bene_id` is the CMS synthetic beneficiary ID. Dollars are Medicare paid unless the column says otherwise. Dates are real DATE values. `_pct` columns are 0 to 100, `pdc` is 0 to 1.

---

## ref (reference lists)

### ref.ndc_drug_class (11,465 rows)
One row per NDC9 (first 9 digits of the NDC: labeler + product) linked to a target drug in RxNorm.

| Column | Meaning |
|---|---|
| ndc9 | Labeler and product code, text with leading zeros |
| is_statin, is_rasa, is_diabetes, is_insulin, is_sacubitril | 1 if the product contains a drug from that list |
| ingredients | Active ingredients, combinations joined with " / " |

### ref.chronic_condition_codes (15 rows)
| Column | Meaning |
|---|---|
| condition | diabetes, heart_failure, copd, ckd |
| icd10_prefix | Code prefix with no dot, matched with LIKE prefix% |
| description | Plain-English label |

---

## stg (typed, one row per thing)

### stg.claims (555,218 rows)
One row per claim across all seven claim files.

| Column | Meaning |
|---|---|
| claim_id | CLM_ID, unique across files |
| bene_id | Beneficiary |
| claim_type | inpatient, outpatient, carrier, snf, hha, hospice, dme |
| from_dt, thru_dt | Claim service dates |
| admit_dt | Admission date (inpatient, SNF, home health) |
| discharge_dt | Discharge date (inpatient, SNF, hospice) |
| paid_amt | CLM_PMT_AMT, once per claim |
| charge_amt | Total charges (institutional) or submitted charges (carrier, DME) |
| principal_dx | Principal diagnosis, ICD-10 with no dot |
| drg_cd | MS-DRG (inpatient, SNF) |
| provider_id | CMS provider number, or billing NPI for carrier |
| covered_days | Medicare utilization days (inpatient, SNF, hospice) |
| is_dialysis | Outpatient claim with a dialysis HCPCS on any line |
| n_lines | Raw lines rolled into this claim |
| service_category | Inpatient, Outpatient dialysis, Outpatient other, Professional, SNF, Home health, Hospice, DME |
| service_month | First day of the month of from_dt |

### stg.claim_dx (8,577,225 rows)
One row per claim per distinct diagnosis code.

| Column | Meaning |
|---|---|
| claim_id, bene_id, claim_type, from_dt | From stg.claims |
| dx_code | ICD-10 code, no dot |
| is_principal | True if this was the principal diagnosis |

### stg.pde (515,520 rows)
One row per Part D fill.

| Column | Meaning |
|---|---|
| pde_id | PDE_ID |
| fill_dt | Date of service (SRVC_DT) |
| ndc11, ndc9 | Product code, full and first 9 digits |
| days_supply | Days supply on the fill |
| qty | Quantity dispensed |
| gross_cost | TOT_RX_CST_AMT, total drug cost |
| plan_paid | Covered + non-covered plan paid |
| patient_pay | Patient pay amount |
| brand_generic | B or G |
| is_statin ... is_sacubitril | Drug class flags from ref.ndc_drug_class |
| ingredients | Active ingredients, if matched |

### stg.member_month (953,004 rows)
One row per person per month with any Medicare entitlement, 2015 to March 2025.

| Column | Meaning |
|---|---|
| month_start | First day of the month |
| year | Calendar year |
| age_end_of_year | AGE_AT_END_REF_YR |
| sex_cd, state_cd | As coded by CMS |
| buyin_cd | Monthly entitlement buy-in code |
| has_part_a, has_part_b | From buyin_cd |
| has_ma_contract | Any Part C contract ID that month |
| has_part_d | A Part D contract ID that month |
| is_dual | Dual status code other than NA, 00, 99 |
| mdcr_status_cd | 10 aged, 20 disabled, 11/21/31 with ESRD |
| is_esrd | ESRD status code or yearly ESRD indicator |

---

## mart (analysis tables)

### Denominator and claims

**mart.member_month** (657,084 rows). stg.member_month limited to A and B months, Jan 2015 to Dec 2022, plus `enrollment_type` (ESRD, Disabled, Aged dual, Aged non-dual).

**mart.claims_in_window** (513,798 rows). stg.claims matched to an A and B member month, with that month's `enrollment_type` and `has_ma_contract`.

**mart.member_months_by_year** (8 rows). year, member_months, member_months_no_ma, partd_member_months, members.

### Stays and readmissions

**mart.inpatient_stay** (19,846 rows)

| Column | Meaning |
|---|---|
| stay_id | bene_id plus stay number |
| admit_dt, discharge_dt | First from date and last thru date of the merged claims |
| los_days | discharge_dt minus admit_dt |
| is_overnight | los_days of 1 or more |
| n_claims | Inpatient claims merged into the stay |
| paid_amt | Sum of claim payments |
| first_drg, first_principal_dx | From the earliest claim |

**mart.readmission** (4,496 rows). One row per index stay: discharge_year, los_days, paid_amt, next_admit_dt, days_to_next_admit, readmit_30.

### Cost and utilization

**mart.pmpm_by_year** (8 rows): members, member_months, medical_paid, medical_pmpm, medical_pmpm_no_ma_months, partd_plan_paid_pmpm, medical_pmpm_change_pct (vs prior year).

**mart.pmpm_by_category** (64 rows): year, service_category, paid, member_months, pmpm.

**mart.pmpm_by_enrollment_type** (32 rows): year, enrollment_type, members, member_months, paid, pmpm, pct_of_member_months, pct_of_spend.

**mart.utilization_by_year** (8 rows): admits_per_1000, inpatient_days_per_1000, same_day_inpatient_per_1000, snf_days_per_1000, dialysis_claims_per_1000, outpatient_visits_per_1000, professional_claims_per_1000, readmit_rate_pct.

### Members

**mart.member_year** (54,757 rows). One row per member per year: member_months, enrollment_type (most common that year), age, any_part_d, medical_paid, dialysis_paid, inpatient_paid, overnight_admits, has_diabetes, has_heart_failure, has_copd, has_ckd.

**mart.member_year_ranked**. Same plus cost_rank (1 = highest spend that year) and members_in_year.

**mart.spend_concentration** (8 rows): share of spend from the top 1, 5, 10, 20 percent and bottom 50 percent, by year.

**mart.top5_profile** (2 rows): 2022 top 5% vs the other 95% (average and median paid, % ESRD, % with dialysis, share of spend from dialysis and inpatient, condition prevalence, age).

**mart.top5_persistence** (3 rows): where the 2021 top 5% ranked in 2022, with average paid both years and % ESRD.

**mart.cohort_summary** (6 rows): members, prevalence_pct, pmpm, admits_per_1000 for each 2022 condition group.

### Adherence

**mart.pdc_fills** (106,291 rows). Target-class fills 2015 to 2022, one per person, measure, drug, and day (longest days supply kept).

**mart.pdc_denominator** (20,932 rows). Every person, measure, and year with a target fill, with index_dt, period_end, period_days, and one true/false column per inclusion rule and exclusion.

**mart.pdc_result** (9,093 rows). Members who pass every rule: days_covered, pdc, is_adherent.

**mart.pdc_rates** (24 rows): denominator, adherent, adherence_rate_pct, median_pdc_pct, near_miss_60_79, below_60, by measure and year.

**mart.pdc_waterfall** (3 rows). 2022 counts after each denominator step, by measure.

**mart.pdc_bands** (12 rows). 2022 members by PDC band, by measure.

### Programs

**mart.adherence_outreach_list** (270 rows). 2022 near misses: measure, bene_id, drug, pdc, days_short_of_80, last_fill_dt, priority (1 = closest to 80%).

**mart.care_mgmt_followup** (167 rows). 2021 top 5% non-ESRD members with paid and overnight admits in 2021 and 2022.

**mart.roi_inputs** (15 rows). Every count the Excel model pulls from the data.

### QA

**mart.qa_results** (27 rows): check_name, expected, actual, result (PASS or FAIL).
