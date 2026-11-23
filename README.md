# Retail Sales & Staffing Efficiency Analysis

**SQL Server + Power BI | 11 stores | calendar year 2025 | CAD**

An end-to-end analytics project: seven raw CSV tables are validated, cleaned and reconciled in SQL Server, shaped into dashboard-ready tables, and presented in a three-page Power BI dashboard with a short management briefing.

![Sales dashboard page](images/01_sales.png)

## Business questions

| # | Question |
|---|----------|
| Q1 | What are net sales and gross profit by store, category, month, weekday and hour? |
| Q2 | How much does each store sell per worked labour hour, and where are labour cost and overtime unusually high? |
| Q3 | How well do scheduled shifts match footfall at peak periods? |
| Q4 | How are absence, overtime, staff availability and sales related? |
| Q5 | Which stores have high visitor numbers but few purchases, compared with peers at the same month, weekday and hour? |
| Q6 | Where should leadership investigate first, and what extra data would confirm the case? |

## Headline results

| Net sales | Gross profit | Sales per worked hour | Labour cost | Conversion |
|---|---|---|---|---|
| CAD 275.31M | CAD 101.04M (36.7%) | CAD 144.31 | 18.37% of net sales | 34.00% of visitors |

- **Year-end margin drop:** sales peak in December, but gross margin falls from about 37% to about 34% in November and December.
- **Staffing does not follow footfall:** staff hours are heaviest from 10:00 to 15:00, while visitors peak from 16:00 and at weekends (about a third busier than weekdays).
- **Stores to review first:** Regina and Winnipeg each raise two of five investigation flags. Regina and Brandon have overtime shares about three times the other stores.
- **Weakest conversion against peers:** Saskatoon (0.77), Brandon (0.85) and Regina (0.87).

All findings are associations, not proven causes. See the limitations in the management briefing.

## Repository contents

```
.
├── README.md
├── sql/
│   └── Keren_Oyem_Analysis_Report.sql        # one organised script, Parts 0 to 7
├── dashboard/
│   └── Keren_Oyem_Analysis_Dashboard.pbix     # Power BI report (3 pages)
├── reports/
│   └── Keren_Oyem_Management_Briefing.pdf     # concise management briefing
└── images/                                    # screenshots used in this README
```

> The source CSV files are not included in this repository.

## Data pipeline

The script runs one part at a time and ends each part with result grids that can be screenshotted as evidence.

| Part | Layer | What it does |
|------|-------|--------------|
| 0 | setup | Creates `Task2_DataWH`, the seven schemas and the `dq.Assumptions` threshold table |
| 1 | raw → clean | Validates and converts data types. Every failed value is logged, and the build stops if more than 1% of any column fails |
| 2 | clean → dq | 80+ business-rule checks: keys, missing values, duplicates, invalid dates, orphans, invalid numbers, return and shift rules |
| 3 | clean → core | Removes duplicates, excludes invalid rows, and recalculates net sales, gross profit and labour cost |
| 4 | core | Enforces primary and foreign keys and reconciles to employee totals |
| 5 | core → mart | Builds fixed-grain mart tables with no double counting, and reconciles every mart total to core |
| 6 | mart | Analysis queries Q1 to Q6 (one query per business question) |
| 7 | dq | Optional clean-up of the row-lineage copies once exceptions are reviewed |

**Schemas:** `raw` (untouched) · `clean` (typed) · `stg` (read-only views) · `core` (analysis-ready) · `dq` (audit evidence and assumptions) · `work` (temporary) · `mart` (dashboard tables)

## Data quality summary

- 81 business-rule checks ran across all seven tables and flagged nine items.
- Rows removed in cleaning: 8 duplicate footfall rows, 4 duplicate transactions, 2 transactions with unparseable timestamps, 12 sales lines (including 5 with no matching product) and 3 shifts. Employees, products and stores were kept in full.
- 12 store-hours with no visitor count are kept as `NULL` and left out of visitor and conversion measures, not set to zero.
- All mart totals reconcile exactly to the source (11 of 11 checks pass), for example net sales of CAD 275,312,806.

## Metric definitions

All money is in CAD, excluding tax. Rates are always a ratio of summed numerators and denominators, never an average of rates.

| Metric | Definition |
|--------|------------|
| Net sales | `SUM(Quantity × UnitPrice − Discount)` over sale and return lines |
| Gross profit | Net sales − `SUM(Quantity × UnitCostAtSale)` |
| Worked hours | Scheduled − absent + overtime |
| Labour cost | `(scheduled − absent) × rate + overtime × 1.5 × rate` (absence unpaid, benefits excluded) |
| Sales per worked hour | Net sales / worked hours |
| Labour cost % | Labour cost / net sales |
| Absence rate / overtime share | Absent hours / scheduled hours, and overtime hours / worked hours |
| Conversion | Distinct sale transactions / visitors (valid footfall hours only) |
| Conversion index | Actual purchases / purchases expected at peer conversion rates for the same month, weekday and hour (1.0 = peer level) |
| Flags raised (0 to 5) | Labour cost %, overtime share or absence rate more than 1 standard deviation above other stores; one of the 3 lowest in sales per worked hour; top-4 traffic with conversion index below 0.98 |

## Dashboard

Power BI imports 10 mart objects and uses 13 DAX measures.

| Page | Purpose |
|------|---------|
| Sales | KPIs, monthly sales and margin, store ranking, category mix |
| Staffing and demand | Labour cost vs sales per hour, weekday-by-hour demand, staffing coverage vs footfall |
| Absence, overtime and conversion | Absence vs overtime, conversion index against peers, investigation shortlist |

![Staffing and demand](images/02_staffing_and_demand.png)
![Absence, overtime and conversion](images/03_absence_overtime_conversion.png)

<details>
<summary>Power BI model view</summary>

![Model view](images/model_view.png)

</details>

## How to reproduce

1. Install SQL Server (Express works) and SQL Server Management Studio.
2. Import the seven CSVs into a `raw` schema with the SSMS *Import Flat File* wizard: `Employees`, `Products`, `SalesLineItems`, `SalesTransactions`, `StaffShifts`, `StoreFootfall`, `Stores`.
3. Open `sql/Keren_Oyem_Analysis_Report.sql`, run **Part 0** first, then run **one part at a time** (highlight the part and press F5), reading the result grids before continuing.
4. In Power BI Desktop, connect to `Task2_DataWH`, import the 10 `mart` objects, and open `dashboard/Keren_Oyem_Analysis_Dashboard.pbix`.

**Note:** the Import wizard stores many decimal columns as `FLOAT`. The script reads `FLOAT` straight into `DECIMAL`, and its stop rules halt the build if any column or core table fails to convert.

## Limitations

- Findings show association, not cause. The data has no promotions, absence reasons or shift-level schedule changes.
- The conversion index compares stores with each other, so it will not show a problem shared by every store.
- Hourly staff coverage is estimated because absence timing within a shift is unknown. The script runs two sensitivity scenarios to test this assumption.
- Saskatoon, Regina and Brandon are the smallest stores, so their ratios move more with a few transactions.

## Author

**Keren Oyem**: data analysis internship project, November 2026.
