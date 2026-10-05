# Medicare claims warehouse

Where is an ACO's Medicare spend going, who drives it, and which of two programs would actually bring it down? I built a SQL warehouse on CMS's synthetic Medicare claims to answer that, with the cost, utilization, and Part D adherence measures a population health team would use.

The data is synthetic. CMS made it to look like the real research files, so the layout, codes, and quirks are real, but the people aren't, and some of the patterns aren't either (more on that under Limitations). The method is the product here, not the findings.

**Dashboard:** [docs/index.html](docs/index.html) (published with GitHub Pages)
**Memo:** [docs/memo.pdf](docs/memo.pdf), one page, to an ACO VP of Population Health
**ROI model:** [model/outreach_roi.xlsx](model/outreach_roi.xlsx)

## What I found

All 2022 unless noted. About 8,200 members and 98,100 member months.

- **Medical spend is $1,665 per member per month**, up 39% from $1,194 in 2015.
- **ESRD members are 10% of member months but 32% of spend** ($5,447 PMPM, 5.3x the aged non-dual group). Outpatient dialysis was the fastest growing category, from $215 to $387 PMPM since 2015.
- **The top 5% of members (408 people) account for 47.5% of spend.** 55% of them have ESRD.
- **High cost doesn't always last.** Of the 2021 top 5%, about half were still in the top 5% in 2022, and 70% of those were ESRD. The non-ESRD high spenders' average cost fell 39% the next year with no intervention at all. Any program that enrolls "last year's most expensive people" and compares before vs after will look like it worked.
- **30-day readmissions are 10.5%**, up from 2.8% in 2015. Still below the 16.9% national Medicare rate (HCUP, 2018).
- **Part D adherence (PDC 80%+):** statins 81.6%, RAS antagonists 20.5%, diabetes meds 14.3%. 270 members sit in the 60 to 79% range, close enough that one or two refills on time gets them over.
- **ROI.** Pharmacy outreach to those 270 near misses nets about $53K a year in the base case (about $5 back per $1). Care management for the 167 non-ESRD high spenders loses about $224K in the base case and needs a 25% drop in admissions to break even. The best program in Medicare's care coordination trials got 17%.

**Recommendation:** fund the adherence outreach, don't fund generic care management for last year's top spenders, route ESRD members to a kidney care approach, and pilot transitional care after discharge since readmissions are climbing. Details in the memo.

## Data

[CMS Synthetic Medicare Enrollment, Fee-for-Service Claims, and Prescription Drug Event files](https://data.cms.gov/collection/synthetic-medicare-enrollment-fee-for-service-claims-and-prescription-drug-event): 11 yearly enrollment files, 7 claim files (inpatient, outpatient, carrier, SNF, home health, hospice, DME), and Part D events. Pipe-delimited, about 1 GB unzipped. Claims run from late 2014 to early March 2023.

| File | Rows | Claims | People |
|---|---:|---:|---:|
| carrier | 1,121,004 | 90,705 | 7,971 |
| outpatient | 575,092 | 402,653 | 8,591 |
| inpatient | 58,066 | 20,867 | 5,699 |
| snf | 12,548 | 1,632 | 1,466 |
| hha | 6,215 | 493 | 449 |
| hospice | 12,107 | 1,086 | 1,086 |
| dme | 103,828 | 37,782 | 5,576 |
| pde (fills) | 515,520 | | 7,403 |
| beneficiary (person-years) | 86,917 | | |

Drug classes come from my own NDC lookup built with the NLM RxNorm API (`ref/ndc_drug_class.csv`), because the official PQA lists are licensed. Diagnosis groups are in `ref/chronic_condition_codes.csv`.

The raw files aren't in this repo (they're in `.gitignore`). Download them from the CMS page above into `data/raw`.

## How it's built

DuckDB, three layers: raw (exactly as shipped, all text), staging (typed, one row per claim), and marts (the measures).

| Step | File | What it does |
|---|---|---|
| 1 | `sql/01_load_raw.sql` | Loads all 19 files as text so codes keep leading zeros |
| | `sql/02_first_look.sql` | Profiling queries I ran before building anything (not part of the build) |
| 2 | `sql/03_staging.sql` | One row per claim across all 7 claim files, real dates and dollars, diagnoses unpivoted, Part D fills tagged by drug class, enrollment unpacked into person-months |
| 3 | `sql/04_member_months.sql` | The denominator: months with Part A and Part B, 2015 to 2022 |
| 4 | `sql/05_inpatient_stays.sql` | Merges inpatient claims into stays, flags 30-day readmissions |
| 5 | `sql/06_pmpm_utilization.sql` | PMPM by service category and enrollment type, utilization per 1,000 |
| 6 | `sql/07_high_cost_and_cohorts.sql` | Spend concentration, top 5% persistence, chronic condition cohorts |
| 7 | `sql/08_pdc_adherence.sql` | PDC for statins, RAS antagonists, and diabetes meds (PQA method) |
| 8 | `sql/09_outreach_targets.sql` | Outreach worklist and the inputs for the ROI model |
| 9 | `sql/qa_checks.sql` | 27 reconciliation checks, PASS or FAIL |
| 10 | `sql/10_exports.sql` | CSVs for Tableau and Excel, JSON for the dashboard |

`build.sql` runs steps 1 through 10 in order.

Definitions for every measure, including where I simplified the official specs, are in [docs/measure_specs.md](docs/measure_specs.md). Table and column definitions are in [docs/data_dictionary.md](docs/data_dictionary.md).

## QA

This is the part I care most about. Before this I worked in quality at an FDA-regulated device company, where nothing ships until it reconciles, and I treated this the same way.

`sql/qa_checks.sql` runs at the end of every build and checks that raw row counts match what I recorded on first load, that staging keeps every claim exactly once and every line adds back, that carrier line payments sum to the claim payment, that every 2015-2022 claim is either matched to a member month or explained, that stays keep every inpatient claim and dollar, and that two PDC values I worked out by hand match the SQL. All 27 pass. Results are in `exports/qa_results.csv`.

[docs/qa_log.md](docs/qa_log.md) has every issue I found and what I did about it. A few that changed the analysis:

- Summing the claim payment across lines overcounts inpatient spend 5.6 times ($792M vs $141M). Payments are taken once per claim.
- 73% of inpatient claims start and end on the same day with a median payment under $1,000. I kept their dollars but didn't count them as admissions. Counting them would put the readmission rate at 31%.
- About 60% of claims fall in months where the person also has a Medicare Advantage contract, which can't happen in real data. I treated everyone as traditional Medicare and checked PMPM with those months removed ($1,692 vs $1,665 in 2022).
- There's no way to measure ER visits. The outpatient file has no ER revenue codes, and the professional file has no ER visit codes or place of service 23.

## Limitations

- Synthetic data. Several patterns don't match real Medicare: ESRD is about 10% of members (closer to 1% in reality), heart failure is almost never coded, some members are under 18 or over 100, and dollar amounts vary in odd ways.
- Dollars are Medicare paid. The institutional files have no allowed amount, so I couldn't report allowed consistently.
- Readmissions don't use CMS's planned readmission algorithm or risk adjustment, and every claim has discharge status 01, so transfers are inferred from overlapping dates.
- PDC follows the PQA method with my own drug lists and doesn't adjust for inpatient or SNF days.
- ROI uses published effect sizes from other populations, and the adherence savings come from an observational study. That's why the base case only counts half of them and why every assumption is a blue cell you can change.

## How I used AI

I used Claude (an AI assistant) as a tutor and pair programmer on this project. It drafted much of the SQL and documentation. I made the analysis decisions, reran the full build myself, and checked the results against the QA log.

## Run it yourself

1. Install the [DuckDB CLI](https://duckdb.org/docs/installation/) (I used 1.5.6).
2. Download the CMS files into `data/raw` (19 CSVs).
3. From the repo folder: `duckdb medicare.duckdb -f build.sql`. It takes a minute or two and ends with the QA summary.
4. To look around: `duckdb -ui medicare.duckdb`.
5. To view the dashboard locally, serve the `docs` folder (for example `python -m http.server` from inside `docs`) and open `localhost:8000`.

## Repo layout

```
build.sql                 runs the whole pipeline
sql/                      one file per step, in order
ref/                      drug class and diagnosis code lists
exports/                  CSV outputs (Tableau, Excel)
model/outreach_roi.xlsx   ROI model with low / base / high scenarios
docs/index.html           dashboard (GitHub Pages)
docs/data/                JSON the dashboard reads
docs/memo.pdf             one-page memo
docs/qa_log.md            issues found and decisions made
docs/measure_specs.md     how every measure is defined
docs/data_dictionary.md   tables and columns
```
