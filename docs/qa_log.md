# QA log

Every check I ran, what I expected, what I got, and what I did about it. Entries 1 to 9 come from the first look at the raw files (`sql/02_first_look.sql`). The rest came up while building staging and the measures. Entry numbers are referenced from comments in the SQL.

The automated checks in `sql/qa_checks.sql` cover the reconciliation items below and run on every build. Current result: 27 of 27 pass.

---

### 1. Row counts vs the CMS user guide

- Checked: rows loaded per file against the counts in the CMS Synthetic RIF user guide (May 2023).
- Expected: an exact match.
- Found: every file except home health is slightly higher than the guide. Carrier 1,121,004 vs 1,120,655, outpatient 575,092 vs 574,861, inpatient 58,066 vs 58,030, SNF 12,548 vs 12,526, hospice 12,107 vs 12,088, DME 103,828 vs 103,798. Home health matches (6,215).
- Action: the guide was written for an earlier release of the files. Differences are under 0.1% per file and the files load cleanly with no rejected rows. I recorded the current counts as the baseline and `qa_checks.sql` tests against them.

### 2. Rows are not claims

- Checked: rows, distinct CLM_ID, and distinct BENE_ID per claim file.
- Expected: some files to have more than one row per claim.
- Found: every file has multiple lines per claim. Carrier averages 12.4 lines per claim, home health 12.6, hospice 11.1, SNF 7.7, inpatient 2.8, DME 2.8, outpatient 1.4.
- Action: staging rolls everything up to one row per claim before any counting.

### 3. Part D is one row per fill

- Checked: same profile for the PDE file.
- Found: 515,520 fills for 7,403 people. No claim and line split.
- Action: none needed. Fills are counted directly.

### 4. Dates are text and codes have leading zeros

- Checked: sample values.
- Found: dates look like 25-Mar-2015. Revenue center codes, NDCs, and some diagnosis codes start with zero.
- Action: loaded everything as text (`all_varchar`) and typed it in staging with `strptime`. Letting DuckDB guess types would have turned '0450' into 450.

### 5. Date ranges

- Checked: first and last dates in each file.
- Found: claims run from late 2014 to early March 2023. Part D runs March 2015 to March 2023. Enrollment files run 2015 to 2025, but 2024 and 2025 have no claims, and 2025 only has three months.
- Action: analysis window is full calendar years 2015 to 2022 (entry 16).

### 6. Summing payments across lines overcounts spend

- Checked: inpatient CLM_PMT_AMT summed over every row vs once per claim.
- Expected: the same total, since I assumed the payment sat on one line.
- Found: $791,921,976.86 summed over rows vs $141,046,614.08 once per claim, 5.6 times higher. The claim payment repeats on every line.
- Action: staging takes the payment once per claim with ANY_VALUE after confirming it never changes within a claim (entry 9). The check "inpatient paid, one row per claim" locks the $141.0M total in.

### 7. Who counts as a member

- Checked: monthly buy-in codes (MDCR_ENTLMT_BUYIN_IND_01 to _12).
- Found: codes 3 and C (Parts A and B) cover most months. Code 1 (Part A only) is about 6% of months from 2015 to 2022.
- Action: a member month requires Part A and Part B. Someone with Part A only shouldn't have doctor or outpatient claims, so including them would understate PMPM. This is the standard ACO approach. Claims in Part A only months are covered in entry 11.

### 8. Medicare Advantage contracts on fee-for-service claims

- Checked: PTC_CNTRCT_ID (Part C contract) by month against claim dates.
- Expected: almost no fee-for-service claims in months with a Part C contract.
- Found: 60% of 2015-2022 claims (and 61% of dollars) fall in months where the person also has a Part C contract. HMO_IND is blank for everyone. The user guide says Part C enrollment was simulated separately from the claims.
- Action: treated the whole population as traditional Medicare, framed as an ACO rather than an MA plan, and kept the flag for a sensitivity check (entry 28).

### 9. Header fields never change within a claim

- Checked: count of distinct CLM_PMT_AMT, dates, and BENE_ID per CLM_ID in every claim file.
- Expected: one value per claim.
- Found: zero claims with more than one value in any file.
- Action: ANY_VALUE() per claim is safe for header fields in staging.

### 10. Staging reconciles to raw

- Checked: claims in `stg.claims` vs distinct CLM_IDs in raw, lines vs raw rows, paid totals vs entry 6, null dates and payments.
- Found: 555,218 claims, no duplicate IDs, lines add back to 1,888,860 raw rows, carrier line payments ($127,158,142.15) equal the claim payments, no null dates or payments.
- Action: all part of `qa_checks.sql`.

### 11. Claims in Part A only months

- Checked: 2015-2022 claims that don't match an A and B member month.
- Found: 25,653 claims and $50.7M (5% of 2015-2022 paid). Every one of them falls in a Part A only month. None are orphans.
- Action: left out of PMPM so the numerator and denominator cover the same months. `qa_checks.sql` confirms matched + Part A only = all claims in the window.

### 12. Most inpatient claims are same-day

- Checked: length of stay and payment for inpatient claims. First noticed in the first look, when the example claim I pulled was a $96.65 same-day claim with a single line (HCPCS 99221).
- Expected: a few percent same-day at most.
- Found: 15,301 of 20,867 inpatient claims (73%) start and end on the same day. Median payment $957. Mostly DRG 951 ("other factors influencing health status") with Z-code principal diagnoses like Z73 and Z60. Overnight stays look more normal.
- Action: kept every dollar in inpatient spend, but only overnight stays count as admissions and readmissions. Same-day claims are reported separately (`same_day_inpatient_per_1000`).

### 13. Overlapping inpatient claims and transfers

- Checked: claims for the same person whose dates overlap or touch, and discharge status codes.
- Found: 1,086 overlapping pairs. PTNT_DSCHRG_STUS_CD is 01 (home) on every claim, so transfers can't be read from the claim.
- Action: merged claims that overlap or start on the day the last one ended into one stay. 20,867 claims became 19,846 stays (802 stays have more than one claim, max 3). `qa_checks.sql` confirms stays keep every claim and dollar.

### 14. Readmission rate

- Checked: 30-day all-cause readmission rate against a national benchmark.
- Expected: something near the 16.9% Medicare rate (HCUP Statistical Brief 278, 2018).
- Found: my first pass counted every inpatient claim as a stay and got 29%. After merging overlaps and counting overnight stays only, 7.1% across 2015-2022, rising from 2.8% to 10.5%.
- Action: kept the overnight definition (entry 12) and noted the 31% figure (all stays, after merging) as the alternative in the dashboard and README. No planned readmission exclusion, since I don't have CMS's algorithm built.

### 15. No way to identify ER visits

- Checked: outpatient revenue centers 0450-0459 and 0981, carrier HCPCS 99281-99285, carrier place of service 23.
- Expected: ER visits are one of the standard utilization measures.
- Found: zero of each. Outpatient revenue centers are only 0001 (claim total) and 0780 (telehealth). Carrier place of service is mostly 11 (office) and 20 (urgent care).
- Action: dropped the ER measure and listed it under limitations. Reported dialysis claims, outpatient visits, and professional claims per 1,000 instead. Because revenue centers are blank, dialysis is identified by HCPCS (90935 and related codes).

### 16. Enrollment shape

- Checked: months per person per year, deaths, population over time.
- Found: every person-year has 12 months of coverage, BENE_DEATH_DT is never filled, and the population only grows (5,642 A and B members in 2015 to 8,175 in 2022).
- Action: member months are simple here, but I kept the month-level logic so it would work on real data with partial years.

### 17. ESRD and dialysis are oversized

- Checked: ESRD share and what drives outpatient spend.
- Found: ESRD members grow from 4.4% of member months in 2015 to 9.9% in 2022 (real Medicare is closer to 1%). Dialysis (HCPCS 90935) is 55% of outpatient claims and $225M of the $731M outpatient total.
- Action: kept as is, but reported enrollment type separately (MSSP uses separate ESRD benchmarks for the same reason) and excluded ESRD members from the care management target.

### 18. Dollar amounts behave oddly in places

- Checked: payment distributions by claim type.
- Found: DME median payment is $5.17. Overnight inpatient stays in 2022 have a median of $4,222 and a mean of $31,192. The "outpatient other" category is the largest at $722 PMPM.
- Action: reported as is. For pricing avoided admissions in the ROI model, the base case uses MedPAC's $16,000 per stay (FY2024), with the data's median and mean as the low and high cases.

### 19. Drug class lookup coverage

- Checked: how many Part D fills map to the drug lists, and whether any target drugs are being missed.
- Found: built a list of 11,465 NDC9 codes from the RxNorm API (all NDCs ever linked to products containing the target ingredients, active 2014 to 2023). 147,126 fills (28.5%) match a class. I looked up the 40 most common unmatched NDCs one by one: acetaminophen, oxycodone with acetaminophen, tacrolimus, hydrocodone, verapamil, and several codes RxNorm doesn't recognize. None were statins, RAS antagonists, diabetes drugs, or insulin.
- Action: none. Matching on the first 9 digits (labeler and product) means package size changes don't break the match.

### 20. The drug mix is narrow

- Found: almost all target fills are simvastatin (62,142), lisinopril (35,200), metformin (11,042), and a 70/30 NPH and regular insulin (37,387). Losartan, atorvastatin, and the rest are rare.
- Action: none. It's a property of how the synthetic data was generated. Noted because it means drug switching within a class almost never happens here.

### 21. Same-day duplicate fills

- Found: 56 cases where a person filled the same target drug twice on the same day.
- Action: kept the longer days supply, per the PQA rule.

### 22. PDC exclusion waterfall (2022)

| Step | Statins | RAS antagonists | Diabetes |
|---|---:|---:|---:|
| Any fill | 1,187 | 1,808 | 342 |
| 2+ fills on different dates | 1,062 | 726 | 164 |
| First fill by Oct 1 | 1,006 | 701 | 161 |
| Part D at first fill, age 18+ | 999 | 695 | 160 |
| No hospice, no ESRD | 892 | 519 | 122 |
| No insulin (diabetes) or sacubitril (RAS) | 892 | 516 | 56 |

- Action: the insulin exclusion cuts the diabetes measure in half, which matches how common insulin is in this data (entry 20). The small denominator (56) means the diabetes rate moves a lot year to year.

### 23. PDC hand checks

- Checked: worked two members out on paper and compared to the SQL.
- Member -10000010285326, RAS antagonists, 2022: first fill Apr 1, so the period is Apr 1 to Dec 31 (275 days). Fills of 84, 63, 63, and 28 days with no overlap cover 238 days. 238 / 275 = 0.8655. SQL: 0.8655.
- Member -10000010283760, RAS antagonists, 2022: period Mar 15 to Dec 31 (292 days). Fills cover 90 + 14 + 90 days, and the Dec 13 fill only counts through Dec 31 (19 of 28 days). 213 / 292 = 0.7295. SQL: 0.7295.
- Action: both are in `qa_checks.sql`.

### 24. RAS and diabetes adherence are very low

- Found: 20.5% and 14.3% adherent in 2022, against the high 80s in real Part D plans. Looking at fill histories, many members have long gaps or switch between 7-day and 90-day supplies with months in between.
- Action: checked a sample of members by hand (entry 23) to make sure it's the data and not the logic. It's the data.

### 25. Fills outside Part D months

- Found: 3,290 fills (0.6%) fall in months with no Part D contract.
- Action: left them in `stg.pde`. They don't affect PDC because the treatment period ends at the last Part D month.

### 26. Heart failure is barely coded

- Found: 32 members with heart failure in 2022 (0.4%). In real Medicare it's around 14%.
- Action: the cohort is shown but flagged as not meaningful.

### 27. Ages outside the Medicare range

- Found: in 2022, 426 members are under 18 and 273 are 100 or older.
- Action: PDC requires age 18+, per the spec. Everything else keeps them.

### 28. Medicare Advantage sensitivity

- Checked: PMPM with the MA-flagged months removed (entry 8).
- Found: 2022 PMPM is $1,692 without them vs $1,665 with them. Early years differ more (2015: $1,048 vs $1,194). The trend and the category mix hold either way.
- Action: kept all months in the headline numbers. Both versions are in `mart.pmpm_by_year`.

### 29. Automated checks

- 27 checks in `sql/qa_checks.sql`: raw row counts (9), staging completeness and nulls (6), payment reconciliation (3), member months (2), claim matching (1), stays (2), PMPM roll-up (1), PDC (3).
- Current result: all pass. Output saved to `exports/qa_results.csv` on every build.
