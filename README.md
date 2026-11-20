# Automated ETL Pipeline for Hospital Data Migration

Migrates a hospital's legacy spreadsheet extract into a normalized, indexed **PostgreSQL** database.
It runs on its own: one `docker compose up` builds the schema, runs the SQL ETL, checks the result and
reports **healthy** only after every check passes. Analytics views on top of the data show
**30-day readmissions** and **bed occupancy across 15 wards**.

| | |
|---|---|
| **Stack** | PostgreSQL 16.15 · PL/pgSQL · Docker Compose · Python (stdlib, data generation only) |
| **Source** | `hospital_data_10000_rows.csv` (4,000 rows × 30 columns, 7 entities side by side) · `doctor_credentials.csv` |
| **Target** | 7-table normalized (3NF) core database + 2-table inpatient module, plus `auth`, `etl`, `analytics` schemas |
| **Records migrated** | 14,441 rows loaded from 15,552 source records (1,111 quarantined, see below) |

---

## Project phases

| Phase | Files | What it is |
|---|---|---|
| 1. MySQL prototype | `Hospital Database Creation and Data Migration.sql`, `hospital_data_migration.sql` | The first working version (database `EHIAS`): import the CSV, split it into 7 tables, then add a booking trigger, a doctor-access procedure and a monthly-revenue procedure. |
| 1b. First Postgres draft | `schema.sql`, `migrate_data.sql` | An earlier draft. It reads the old `hospital_data.csv`. Kept for history; replaced by `db/init/`. |
| **2. Production pipeline** | `docker-compose.yml`, `db/init/*.sql`, `benchmarks/`, `data_generation/` | A PostgreSQL rebuild with automated ETL, data-quality rules, strategic indexes, an inpatient module, analytics views and self-validation. |

---

## Quick start

```bash
cp .env.example .env              # then set POSTGRES_PASSWORD
docker compose up -d              # builds + migrates + validates (~15 s)
docker compose ps                 # wait for "healthy"
docker exec -it hospital-db psql -U postgres -d hospitaldb
```

On first boot (empty volume), `db/init/` runs in order:

```
01_schema.sql           7 core + 2 inpatient tables, constraints, schemas
02_indexes.sql          strategic indexes
03_etl.sql              staging tables + etl.run_migration() procedure
04_business_rules.sql   booking trigger, doctor access, monthly revenue
05_views.sql            analytics views (readmission, occupancy, ...)
06_run_and_validate.sql CALL etl.run_migration(); then the validation checks
```

If any statement or check fails, initialisation stops (`ON_ERROR_STOP`) and the container never
reports healthy. The health check passes only once an ETL run has the status `SUCCEEDED`.

| Task | Command |
|---|---|
| Re-run the migration (idempotent, single transaction) | `CALL etl.run_migration();` |
| Rebuild from scratch | `docker compose down -v && docker compose up -d` |
| Retrieval benchmark | `docker exec hospital-db psql -U postgres -d hospitaldb -f /project/benchmarks/benchmark.sql` |
| Redundancy measurement | `docker exec hospital-db psql -U postgres -d hospitaldb -f /project/benchmarks/redundancy.sql` |
| Regenerate ward/admission source data | `python data_generation/generate_ward_data.py` |

> Git Bash on Windows rewrites `/project/...` paths, so prefix the command with `MSYS_NO_PATHCONV=1`.

---

## Schema: 7-table core database + inpatient module (3NF)

The **`hospital` schema holds the 7-table core database** migrated from the legacy system, which
covered outpatient activity only. The **`inpatient` schema** is a 2-table module (wards and
admissions) for beds and overnight stays. It was added so that occupancy and readmission could be
analysed, since the legacy extract had no ward data.

![Hospital Database ERD](./Database%20design.png)

| # | Table | Rows | Notes |
|---|---|---|---|
| 1 | `hospital.departments` | 10 | |
| 2 | `hospital.doctors` | 200 | role is CHECKed: Junior / Resident / Consultant / Senior |
| 3 | `hospital.patients` | 2,000 | gender CHECK (`m`/`f`/`o`); phone must be 10 digits |
| 4 | `hospital.appointments` | 4,000 | partial UNIQUE indexes stop double-booking |
| 5 | `hospital.prescriptions` | 2,504 | UNIQUE (appointment, medication) |
| 6 | `hospital.bills` | 3,099 | amount > 0; `paid` is BOOLEAN |
| 7 | `hospital.lab_reports` | 1,786 | stored as **JSONB** (was raw text) |
| Inpatient 1 | `inpatient.wards` | 15 | 10 General + 5 HDU wards, each with a bed capacity |
| Inpatient 2 | `inpatient.admissions` | 827 | each stay links to its completed appointment |
| – | `auth.doctor_credentials` | 200 | passwords hashed with **bcrypt** (`pgcrypto`), never stored in plaintext |

The legacy extract has no bed data. Wards and admissions come from
`data_generation/generate_ward_data.py`. It is deterministic (seed 42) and every stay is tied to a
real completed appointment. A ward never holds more patients than it has beds, and a patient is
never in two beds at once. The source has only 4,000 visits over two years, so ward occupancy is
low: 1–5% on average, with peaks of 13–36%. The views and metrics are the deliverable here, not the occupancy level itself.

---

## ETL and data-quality rules

`etl.run_migration()` loads the raw files into all-TEXT staging tables, so nothing can fail at load
time. It then parses every value strictly: invalid dates such as `31-02` are rejected rather than
rolled over to March, and JSON is validated. Next it applies the integrity rules below, most of them
built on **window functions** (`ROW_NUMBER`, `COUNT … OVER`). Finally it reloads the target tables in
foreign-key order and re-syncs the identity sequences. Every change is written to
`etl.data_quality_log`, and every rejected row is kept in full in `etl.quarantine`, so nothing is
lost silently.

| Rule | Technique | Action | Rows |
|---|---|---|---:|
| R03 Doctor double-booked in the same slot | `ROW_NUMBER() OVER (PARTITION BY doctor_id, appointment_time …)` | keep the completed/earliest booking, set the others to Cancelled | 47 |
| R04 Patient double-booked in the same slot | `ROW_NUMBER() OVER (PARTITION BY patient_id, appointment_time …)` | same | 4 |
| R06 Bill raised on a cancelled visit | join to the corrected status | quarantine | 401 |
| R06 Prescription on a cancelled visit | | quarantine | 342 |
| R06 Lab report on a cancelled visit | | quarantine | 214 |
| R07 Same drug entered twice on one visit | `ROW_NUMBER()` + `COUNT(*) OVER (PARTITION BY appointment_id, medication)` | keep the latest, remove the duplicates | 154 |
| R00/R01/R02/R08 Unparseable values, duplicate keys, orphan references, invalid admissions | strict parsers, `ROW_NUMBER`, `NOT EXISTS` | quarantine | 0 |
| **Integrity violations resolved** | | | **1,162** |
| R09 Bill before visit, lab before visit, stale "Scheduled" | temporal comparison | **flagged** for review; the true time is unknown, so the row is not changed | 1,863 |

Format standardisations, which change representation but are not errors: 2,000 genders lowercased,
6,000 birth/appointment dates parsed to `DATE`/`TIMESTAMP`, 3,500 0/1 flags converted to BOOLEAN, 2,000 lab reports
converted from text to JSONB, and 51,480 empty padding cells dropped (42.9% of the sheet).

```sql
SELECT rule_code, action, count(*) FROM etl.data_quality_log GROUP BY 1, 2 ORDER BY 3 DESC;
SELECT * FROM etl.quarantine WHERE rule_code = 'R06_BILL_ON_CANCELLED_VISIT' LIMIT 5;
```

---

## Strategic indexing: measured results

There are 14 indexes, and each one serves a specific access path (see `02_indexes.sql`):
composite `(patient_id, appointment_time)` and `(doctor_id, appointment_time)`; foreign-key indexes,
which PostgreSQL does not create automatically; a partial index on unpaid bills; a GIN `jsonb_path_ops`
index on lab results; and partial UNIQUE indexes that enforce the no-double-booking rule.

`benchmarks/benchmark.sql` times 7 everyday retrieval tasks. Each task runs 200 times with a
different parameter on each run, and the same data is queried in three tiers:

| Task | Legacy sheet (ms) | Normalized, PK only (ms) | **Normalized + indexes (ms)** |
|---|---:|---:|---:|
| Patient visit history | 0.717 | 0.320 | **0.170** |
| Prescriptions + labs of a visit | 1.194 | 0.298 | **0.102** |
| Doctor's schedule for a month | 0.513 | 0.297 | **0.075** |
| Outstanding bills of a patient | 1.203 | 0.511 | **0.165** |
| Patient lookup by phone | 0.379 | 0.231 | **0.051** |
| Daily appointment list | 3.693 | 1.894 | **0.288** |
| Lab reports by haemoglobin value | 0.858 | 1.084 | **0.107** |
| **Average** | **1.222** | **0.662** | **0.137** |

The average retrieval time is **88.8% lower than the legacy sheet** (8.3× faster on average). Indexing
alone accounts for **79.4%** compared with the same schema without indexes. Results were stable at
88–89% over repeated runs. The dataset is small (4,000 visits); index gains grow with data volume,
because a B-tree lookup costs O(log n) where a full scan costs O(n).

## Redundancy: measured results

`benchmarks/redundancy.sql` rebuilds the same information as a flat spreadsheet register and
compares it with the normalized schema:

| Flat layout | Repeated descriptive values | Normalized | Reduction |
|---|---:|---:|---:|
| One row per appointment | 32,000 | 8,610 | **73.1%** |
| One row per prescription / bill / lab line | 73,890 | 16,610 | **77.5%** |

---

## Business rules (ported from the MySQL prototype)

| Prototype | PostgreSQL | Notes |
|---|---|---|
| Point 4: trigger `CHECK_NEW_APPOINTMENT` | trigger `check_new_appointment` + partial UNIQUE indexes | Blocks bookings in the past and doctor/patient double-booking on INSERT and UPDATE. |
| Point 5: `VIEW_DOCTOR_DATA(user, pwd)` | `hospital.view_doctor_data(user, pwd)` | Checks the password against its bcrypt hash. Senior doctors see their whole department; other doctors see only their own patients. |
| Point 6: `SP_MONTHLY_REVENUE(y, m)` | `hospital.monthly_revenue(y, m)` | Fixes the join: the prototype joined `departments.departmentid = doctors.doctorid`. Uses a date-range filter the index can serve and adds collected/outstanding columns. |

```sql
SELECT * FROM hospital.view_doctor_data('doctor4', 'ic0pFSn0');   -- Senior: whole department
SELECT * FROM hospital.monthly_revenue(2025, 5);
```

---

## Analytics views (`analytics` schema)

| View | Purpose |
|---|---|
| `v_appointment_details` | 5-table join: visit, patient (age at visit), doctor, department, billed and outstanding amounts |
| `v_admission_episodes` | every stay, with `LAG`/`LEAD` window functions linking it to the patient's previous and next stays |
| `v_readmission_by_ward` / `_by_department` | 30-day readmission rate; counts only discharges with a full 30-day follow-up window |
| `v_ward_daily_occupancy` | midnight bed census for each of the 15 wards, every day |
| `v_ward_occupancy_summary` | average and peak occupancy, days at ≥85%, bed-days, ward ranking (`RANK()`) |
| `v_ward_monthly_occupancy` | monthly trend for each ward |
| `v_ward_current_census` | patients in a bed on the reporting date |

```sql
SELECT * FROM analytics.v_ward_occupancy_summary ORDER BY busiest_rank;
SELECT * FROM analytics.v_readmission_by_ward ORDER BY readmission_rate_pct DESC;
```

---

## Self-validation (`06_run_and_validate.sql`)

These checks run on every deployment, and any failure aborts the start-up:

- There are exactly 7 core tables in `hospital` and 2 in `inpatient`, the ETL run succeeded, and the reference data is complete.
- **Reconciliation:** for every entity, source rows = loaded + quarantined.
- No double-bookings, no bills on cancelled visits, no ward over capacity on any day, and no overlapping stays for one patient.
- The identity sequences continue after the migrated IDs.
- The trigger rejects a booking in the past and a double-booking (tested inside sub-transactions).
- A doctor can log in with the right password and is refused with a wrong one.

---

## Project structure

```
docker-compose.yml          one-command deployment (pinned postgres:16.15, health check)
.env.example                connection settings template
db/init/01..06_*.sql        schema -> indexes -> ETL -> rules -> views -> run + validate
benchmarks/benchmark.sql    retrieval-time benchmark (3 tiers)
benchmarks/redundancy.sql   redundancy measurement
data_generation/            deterministic ward/admission generator
data/wards.csv, admissions.csv
hospital_data_10000_rows.csv, doctor_credentials.csv    legacy source extract
Hospital Database Creation and Data Migration.sql, hospital_data_migration.sql   MySQL prototype
schema.sql, migrate_data.sql                                                     first Postgres draft
```
