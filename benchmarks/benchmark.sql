-- =====================================================================================
-- benchmarks/benchmark.sql  -  measured retrieval-time improvement
-- -------------------------------------------------------------------------------------
-- Run:  docker exec -it hospital-db psql -U postgres -d hospitaldb -f /project/benchmarks/benchmark.sql
--
-- Seven everyday retrieval tasks are timed on three tiers holding the SAME data:
--   legacy     : the legacy extract as it arrived (one wide all-text sheet, no indexes)
--                -> etl.stg_hospital_raw
--   normalized : the 9-table schema with primary keys only (no secondary indexes)
--                -> bench_noidx.*  (copy built below)
--   indexed    : the production schema with the strategic indexes of 02_indexes.sql
--                -> hospital.*
-- Each query runs ITERATIONS times with a different parameter every time (different
-- patient / doctor / date ...), after a warm-up, and the mean wall time is recorded.
-- Planning time is included (EXECUTE re-plans each call), which favours no tier.
-- =====================================================================================
\set ON_ERROR_STOP on
\timing off
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS bench_noidx CASCADE;
CREATE SCHEMA bench_noidx;
CREATE TABLE bench_noidx.departments  AS SELECT * FROM hospital.departments;
CREATE TABLE bench_noidx.doctors      AS SELECT * FROM hospital.doctors;
CREATE TABLE bench_noidx.patients     AS SELECT * FROM hospital.patients;
CREATE TABLE bench_noidx.appointments AS SELECT * FROM hospital.appointments;
CREATE TABLE bench_noidx.prescriptions AS SELECT * FROM hospital.prescriptions;
CREATE TABLE bench_noidx.bills        AS SELECT * FROM hospital.bills;
CREATE TABLE bench_noidx.lab_reports  AS SELECT * FROM hospital.lab_reports;
ALTER TABLE bench_noidx.departments   ADD PRIMARY KEY (department_id);
ALTER TABLE bench_noidx.doctors       ADD PRIMARY KEY (doctor_id);
ALTER TABLE bench_noidx.patients      ADD PRIMARY KEY (patient_id);
ALTER TABLE bench_noidx.appointments  ADD PRIMARY KEY (appointment_id);
ALTER TABLE bench_noidx.prescriptions ADD PRIMARY KEY (prescription_id);
ALTER TABLE bench_noidx.bills         ADD PRIMARY KEY (bill_id);
ALTER TABLE bench_noidx.lab_reports   ADD PRIMARY KEY (report_id);
ANALYZE bench_noidx.departments, bench_noidx.doctors, bench_noidx.patients, bench_noidx.appointments,
        bench_noidx.prescriptions, bench_noidx.bills, bench_noidx.lab_reports;
ANALYZE etl.stg_hospital_raw;

DROP SCHEMA IF EXISTS bench CASCADE;
CREATE SCHEMA bench;
CREATE TABLE bench.results (query_no INT, task TEXT, tier TEXT, iterations INT, avg_ms NUMERIC);

-- run p_sql once per parameter in p_params (cycled), return mean milliseconds
CREATE FUNCTION bench.time_it(p_search_path TEXT, p_sql TEXT, p_params TEXT[], p_iters INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
    t0 TIMESTAMPTZ; n INT := array_length(p_params, 1); dummy BIGINT;
BEGIN
    PERFORM set_config('search_path', p_search_path, true);
    FOR i IN 1..20 LOOP   -- warm-up: caches, catalog
        EXECUTE 'SELECT count(*) FROM (' || p_sql || ') q' INTO dummy USING p_params[1 + (i % n)];
    END LOOP;
    t0 := clock_timestamp();
    FOR i IN 1..p_iters LOOP
        EXECUTE 'SELECT count(*) FROM (' || p_sql || ') q' INTO dummy USING p_params[1 + (i % n)];
    END LOOP;
    RETURN extract(epoch FROM clock_timestamp() - t0) * 1000 / p_iters;
END $$;

CREATE FUNCTION bench.run(p_no INT, p_task TEXT, p_legacy_sql TEXT, p_sql TEXT,
                          p_params TEXT[], p_iters INT DEFAULT 200)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO bench.results VALUES
      (p_no, p_task, '1_legacy',     p_iters, bench.time_it('etl, public',         p_legacy_sql, p_params, p_iters)),
      (p_no, p_task, '2_normalized', p_iters, bench.time_it('bench_noidx, public', p_sql,        p_params, p_iters)),
      (p_no, p_task, '3_indexed',    p_iters, bench.time_it('hospital, public',    p_sql,        p_params, p_iters));
END $$;

-- ------------------------------------------------------------------ parameter pools (seeded = repeatable)
SELECT setseed(0.42);
CREATE TABLE bench.params AS SELECT
    (SELECT array_agg(patient_id::TEXT ORDER BY random()) FROM (SELECT patient_id FROM hospital.patients ORDER BY random() LIMIT 200) x) AS patients,
    (SELECT array_agg(appointment_id::TEXT) FROM (SELECT appointment_id FROM hospital.appointments ORDER BY random() LIMIT 200) x)   AS appointments,
    (SELECT array_agg(doctor_id::TEXT)      FROM (SELECT doctor_id FROM hospital.doctors ORDER BY random() LIMIT 200) x)             AS doctors,
    (SELECT array_agg(phone)                FROM (SELECT phone FROM hospital.patients ORDER BY random() LIMIT 200) x)                AS phones,
    (SELECT array_agg(d::TEXT)              FROM (SELECT DISTINCT appointment_time::DATE d FROM hospital.appointments ORDER BY 1 LIMIT 200) x) AS days,
    (SELECT array_agg(h)                    FROM (SELECT DISTINCT report_data->>'Hemoglobin' h FROM hospital.lab_reports LIMIT 200) x) AS hb;

-- ------------------------------------------------------------------ the 7 tasks
SELECT bench.run(1, 'Patient visit history (with doctor)',
  $q$ SELECT a.appt_id, a.appt_time, d.doc_name
      FROM stg_hospital_raw a JOIN stg_hospital_raw d ON d.doc_id = a.appt_doctor_id
      WHERE a.appt_patient_id = $1
      ORDER BY to_timestamp(a.appt_time, 'DD-MM-YYYY HH24:MI') DESC $q$,
  $q$ SELECT a.appointment_id, a.appointment_time, d.name
      FROM appointments a JOIN doctors d USING (doctor_id)
      WHERE a.patient_id = $1::INT ORDER BY a.appointment_time DESC $q$,
  (SELECT patients FROM bench.params));

SELECT bench.run(2, 'Prescriptions + lab reports of one visit',
  $q$ SELECT 'rx' AS kind, rx_medication || ' ' || rx_dosage AS detail FROM stg_hospital_raw WHERE rx_appt_id = $1
      UNION ALL
      SELECT 'lab', lab_data FROM stg_hospital_raw WHERE lab_appt_id = $1 $q$,
  $q$ SELECT 'rx' AS kind, medication || ' ' || dosage AS detail FROM prescriptions WHERE appointment_id = $1::INT
      UNION ALL
      SELECT 'lab', report_data::TEXT FROM lab_reports WHERE appointment_id = $1::INT $q$,
  (SELECT appointments FROM bench.params));

SELECT bench.run(3, 'Doctor schedule for a month',
  $q$ SELECT appt_id, appt_time FROM stg_hospital_raw
      WHERE appt_doctor_id = $1
        AND to_timestamp(appt_time, 'DD-MM-YYYY HH24:MI') >= '2024-05-01'
        AND to_timestamp(appt_time, 'DD-MM-YYYY HH24:MI') <  '2024-06-01' $q$,
  $q$ SELECT appointment_id, appointment_time FROM appointments
      WHERE doctor_id = $1::INT
        AND appointment_time >= '2024-05-01' AND appointment_time < '2024-06-01' $q$,
  (SELECT doctors FROM bench.params));

SELECT bench.run(4, 'Outstanding bills of a patient',
  $q$ SELECT b.bill_id, b.bill_amount
      FROM stg_hospital_raw b JOIN stg_hospital_raw a ON a.appt_id = b.bill_appt_id
      WHERE a.appt_patient_id = $1 AND b.bill_paid = '0' $q$,
  $q$ SELECT b.bill_id, b.amount
      FROM bills b JOIN appointments a USING (appointment_id)
      WHERE a.patient_id = $1::INT AND NOT b.paid $q$,
  (SELECT patients FROM bench.params));

SELECT bench.run(5, 'Front-desk patient lookup by phone',
  $q$ SELECT pat_id, pat_name FROM stg_hospital_raw WHERE pat_phone = $1 $q$,
  $q$ SELECT patient_id, name FROM patients WHERE phone = $1 $q$,
  (SELECT phones FROM bench.params));

SELECT bench.run(6, 'Daily appointment list (patient + doctor)',
  $q$ SELECT a.appt_id, p.pat_name, d.doc_name
      FROM stg_hospital_raw a
      JOIN stg_hospital_raw p ON p.pat_id = a.appt_patient_id
      JOIN stg_hospital_raw d ON d.doc_id = a.appt_doctor_id
      WHERE to_timestamp(a.appt_time, 'DD-MM-YYYY HH24:MI')::DATE = $1::DATE $q$,
  $q$ SELECT a.appointment_id, p.name, d.name
      FROM appointments a JOIN patients p USING (patient_id) JOIN doctors d USING (doctor_id)
      WHERE a.appointment_time >= $1::DATE AND a.appointment_time < $1::DATE + 1 $q$,
  (SELECT days FROM bench.params));

SELECT bench.run(7, 'Lab reports by haemoglobin value',
  $q$ SELECT lab_id FROM stg_hospital_raw WHERE lab_data LIKE '%"Hemoglobin": "' || $1 || '"%' $q$,
  $q$ SELECT report_id FROM lab_reports WHERE report_data @> jsonb_build_object('Hemoglobin', $1) $q$,
  (SELECT hb FROM bench.params));

-- ------------------------------------------------------------------ report
\echo
\echo '=== Mean retrieval time per task (ms) ==='
SELECT query_no AS "#", task,
       max(avg_ms) FILTER (WHERE tier = '1_legacy')     ::NUMERIC(10,3) AS legacy_ms,
       max(avg_ms) FILTER (WHERE tier = '2_normalized') ::NUMERIC(10,3) AS normalized_ms,
       max(avg_ms) FILTER (WHERE tier = '3_indexed')    ::NUMERIC(10,3) AS indexed_ms,
       round(100 * (1 - max(avg_ms) FILTER (WHERE tier = '3_indexed') / max(avg_ms) FILTER (WHERE tier = '1_legacy')), 1)     AS "% faster vs legacy",
       round(100 * (1 - max(avg_ms) FILTER (WHERE tier = '3_indexed') / max(avg_ms) FILTER (WHERE tier = '2_normalized')), 1) AS "% faster vs no-index"
FROM bench.results GROUP BY query_no, task ORDER BY query_no;

\echo '=== Overall ==='
WITH t AS (
    SELECT query_no,
           max(avg_ms) FILTER (WHERE tier = '1_legacy')     AS legacy,
           max(avg_ms) FILTER (WHERE tier = '2_normalized') AS normalized,
           max(avg_ms) FILTER (WHERE tier = '3_indexed')    AS indexed
    FROM bench.results GROUP BY query_no)
SELECT round(avg(legacy), 3)      AS avg_legacy_ms,
       round(avg(normalized), 3)  AS avg_normalized_ms,
       round(avg(indexed), 3)     AS avg_indexed_ms,
       round(100 * (1 - avg(indexed) / avg(legacy)), 1)     AS "avg time reduction vs legacy %",
       round(100 * (1 - avg(indexed) / avg(normalized)), 1) AS "avg time reduction vs no-index %",
       round(avg(legacy / indexed), 1)                      AS "mean speed-up vs legacy (x)"
FROM t;

DROP SCHEMA bench_noidx CASCADE;
