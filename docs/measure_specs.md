# Measure specs

How each number in this project is defined, and where I simplified compared to the official version. If a definition here and the SQL ever disagree, the SQL is what ran, and that's a bug to fix.

## Population and denominator

**Member month.** One person, one calendar month, with both Part A and Part B (monthly buy-in code 3 or C). Window: January 2015 to December 2022. Source: `mart.member_month` (04).

**Enrollment type.** The four groups the Medicare Shared Savings Program uses for ACO benchmarks, assigned per month:
- ESRD: Medicare status code 11, 21, or 31, or the yearly ESRD indicator is Y
- Disabled: status code 20
- Aged dual: aged, and a dual status code other than NA, 00, or 99
- Aged non-dual: everyone else

**Medicare Advantage flag.** A month with any Part C contract ID. Not used to filter (see qa_log entry 8), only for the sensitivity check.

## Dollars

**Paid.** CLM_PMT_AMT, taken once per claim. This is what Medicare paid the provider. It leaves out beneficiary cost sharing and other payers. Allowed amounts exist only in the carrier and DME files, so I used paid everywhere to keep claim types comparable.

**Which month a claim belongs to.** The month of the claim's from date. Claims in months that aren't A and B member months are left out of PMPM (qa_log entry 11).

**PMPM.** Paid dollars in the window / member months. By service category, the category comes from the claim file:

| Category | Rule |
|---|---|
| Inpatient | inpatient file |
| Outpatient dialysis | outpatient claim with HCPCS 90935, 90937, 90945, 90947, or 90999 on any line |
| Outpatient other | every other outpatient claim |
| Professional | carrier file |
| SNF, Home health, Hospice, DME | their own files |

**Part D PMPM.** Plan paid (covered plus non-covered plan paid amounts) / member months with a Part D contract. Reported separately because ACO benchmarks don't include Part D.

## Utilization

All per 1,000 = events / member months x 12,000.

**Stay.** Inpatient claims for the same person merged when a claim starts on or before the latest discharge date seen so far (overlapping or same-day transfer). Built with a running MAX over discharge dates and a running SUM of "new stay" flags (gaps and islands).

**Overnight admission.** A stay where discharge date is after admit date. Same-day stays are counted separately (qa_log entry 12).

**Inpatient days.** Discharge date minus admit date, overnight stays only.

**SNF days.** CLM_UTLZTN_DAY_CNT (Medicare covered days) on SNF claims.

**ER visits.** Not available in this data (qa_log entry 15).

## 30-day readmission

- Index stay: overnight stay discharged in 2015 to 2022, with A and B coverage in the discharge month and the following month.
- Readmission: the next overnight stay for the same person admitted 1 to 30 days after the index discharge.
- Every overnight stay can be both a readmission and a new index stay, as in CMS's hospital-wide measure.
- Not included: CMS's planned readmission algorithm, risk adjustment, death exclusion (no deaths in this data), and transfer logic beyond merging overlapping claims.

## High-cost members

**Cost rank.** Members ranked within each year by total medical paid in A and B months. Top 5% = rank / members in year of 5% or less. Members with zero spend are included in the denominator.

**Persistence.** The 2021 top 5%, followed into 2022 and grouped by where they ranked.

## Chronic condition cohorts

A member has the condition in a year if, in that calendar year, they have 1 or more inpatient, SNF, or home health claims with a matching code in any diagnosis position, or 2 or more outpatient or professional claims with a matching code on different dates. Similar to the CMS Chronic Conditions Warehouse approach, simplified to a one-year lookback for every condition.

| Condition | ICD-10 prefixes |
|---|---|
| Diabetes | E08, E09, E10, E11, E13 |
| Heart failure | I50, I110, I130, I132, I0981 |
| COPD | J41, J42, J43, J44 |
| CKD | N18 |

## Medication adherence (PDC)

Follows the Pharmacy Quality Alliance method used in the Part D Star Ratings for three measures: diabetes medications, RAS antagonists, and statins.

**Drug lists.** PQA's official NDC lists are licensed, so I built my own from RxNorm (`ref/ndc_drug_class.csv`). For each ingredient below, I pulled every clinical and branded drug that contains it (including combinations) and every NDC ever linked to those drugs that was active between 2014 and 2023. Matching is on the first 9 digits of the NDC (labeler and product).

| Measure | Ingredients |
|---|---|
| Statins | atorvastatin, fluvastatin, lovastatin, pitavastatin, pravastatin, rosuvastatin, simvastatin |
| RAS antagonists | ACE inhibitors (benazepril, captopril, enalapril, fosinopril, lisinopril, moexipril, perindopril, quinapril, ramipril, trandolapril), ARBs (azilsartan, candesartan, eprosartan, irbesartan, losartan, olmesartan, telmisartan, valsartan), aliskiren |
| Diabetes | biguanides (metformin), sulfonylureas, thiazolidinediones, DPP-4 inhibitors, GLP-1 agonists (including tirzepatide), meglitinides, SGLT2 inhibitors |
| Exclusion lists | insulins (ATC A10A plus NPH), sacubitril |

**Denominator** (per measure, per calendar year):
- 2 or more fills of the class on different dates in the year
- first fill (index date) on or before Oct 1, so at least 91 days before Dec 31
- Part D coverage in the index month
- age 18 or older
- excluded: any hospice claim in the year, any ESRD month in the year, any insulin fill in the year (diabetes measure), any sacubitril/valsartan fill in the year (RAS measure)

**Treatment period.** Index date through Dec 31, or through the end of the last Part D month in the year if coverage ends earlier.

**Days covered.**
1. Same drug, same day: keep the longest days supply.
2. Same drug, overlapping fills: the later fill starts the day after the earlier one runs out (an early refill's pills get used after the current supply).
3. Different drugs in the same class can overlap; a day counts once.
4. Days after the end of the treatment period don't count.

**PDC** = days covered / days in the treatment period. Adherent at 0.80 or higher.

**How step 2 works in SQL.** Instead of a loop, the shifted end date for each fill comes from two window functions over that person's fills of the drug in date order:

```
supply_so_far = running total of days supply, including this fill
adj_end       = MAX(fill_date - (supply_so_far - days_supply)) over all fills so far
                + supply_so_far - 1
adj_start     = adj_end - days_supply + 1
```

Example with three fills:

| Fill date | Days | supply_so_far | fill_date minus earlier supply | running max | adj_end | adj_start |
|---|---:|---:|---|---|---|---|
| Jan 1 | 30 | 30 | Jan 1 | Jan 1 | Jan 30 | Jan 1 |
| Jan 25 (early) | 30 | 60 | Dec 26 | Jan 1 | Mar 1 | Jan 31 |
| Apr 1 (after a gap) | 30 | 90 | Jan 31 | Jan 31 | Apr 30 | Apr 1 |

The early refill gets pushed to start Jan 31, the day after the first fill runs out. After the gap, the running max jumps forward and the third fill starts on its own fill date.

**Not done.** The optional PQA adjustment that removes inpatient and SNF days from the period, and plan-level (contract) reporting.

## Outreach targets

**Adherence near misses.** Members in the 2022 PDC result with PDC from 0.60 to just under 0.80. Ranked by days short of 80% (fewest first). Output: `mart.adherence_outreach_list`.

**Care management target.** 2021 top 5% by medical spend, excluding ESRD, still enrolled in 2022. Their 2022 overnight admissions (82) are the "no program" baseline in the ROI model.

## ROI model

`model/outreach_roi.xlsx`. Every assumption is a blue cell on the Assumptions tab with its source:

| Assumption | Low | Base | High | Source |
|---|---:|---:|---:|---|
| Near misses who reach 80% | 5% | 15% | 30% | My assumption; Prime Therapeutics missed-refill program as a reality check |
| Outreach cost per member | $100 | $50 | $25 | My assumption |
| Share of published savings realized | 25% | 50% | 100% | Roebuck et al. is observational |
| Net savings per newly adherent member | $1,258 / $3,908 / $3,756 | same | same | Roebuck et al., Health Affairs 2011 (cholesterol / hypertension / diabetes) |
| Care management fee PMPM | $270 | $164 | $60 | Peikes et al., JAMA 2009 |
| Reduction in admissions | 0% | 8% | 17% | Peikes et al. 2009 (most programs 0%, best 17%) |
| Paid per avoided admission | $4,222 | $16,000 | $31,192 | Data median and mean; MedPAC July 2026 Data Book |

## Sources

- CMS. Synthetic Medicare Enrollment, Fee-for-Service Claims, and Prescription Drug Event files, and the Synthetic RIF user guide (May 2023).
- Pharmacy Quality Alliance. Proportion of Days Covered measure specifications (as used in the CMS Part D Star Ratings Technical Notes).
- National Library of Medicine. RxNorm and RxClass APIs (rxnav.nlm.nih.gov).
- Roebuck MC, Liberman JN, Gemmill-Toyama M, Brennan TA. Medication adherence leads to lower health care use and costs despite increased drug spending. Health Affairs. 2011;30(1):91-99.
- Peikes D, Chen A, Schore J, Brown R. Effects of care coordination on hospitalization, quality of care, and health care expenditures among Medicare beneficiaries: 15 randomized trials. JAMA. 2009;301(6):603-618.
- MedPAC. July 2026 Data Book, Section 6 (acute inpatient services).
- AHRQ HCUP. Statistical Brief 278, Overview of Clinical Conditions With Frequent and Costly Hospital Readmissions by Payer, 2018.
- Prime Therapeutics. Missed refill and reduced cost share adherence programs (reported via BioSpace, May 2018).
