-- =====================================================================================
-- benchmarks/redundancy.sql  -  how much duplicated data normalization removed
-- -------------------------------------------------------------------------------------
-- Run:  docker exec -it hospital-db psql -U postgres -d hospitaldb -f /project/benchmarks/redundancy.sql
--
-- A spreadsheet-based hospital keeps one flat row per event, repeating the patient,
-- doctor and department details on every row. We rebuild that flat register from the
-- migrated data (same information, nothing added) and compare it with the normalized
-- schema, where each fact is stored exactly once.
--
--   flat_visit_register    : 1 row per appointment  (visit + patient + doctor + department)
--   flat_activity_register : 1 row per clinical/billing line (prescription, bill, lab report)
--                            with the full visit/patient/doctor/department context
-- =====================================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS redundancy CASCADE;
CREATE SCHEMA redundancy;

-- descriptive (non-key) attributes that a flat sheet repeats
--   patient: name, date_of_birth, gender, phone           (4)
--   doctor : name, specialization, role                   (3)
--   department: name                                      (1)
--   visit  : appointment_time, status                     (2)

CREATE TABLE redundancy.flat_visit_register AS
SELECT a.appointment_id, a.appointment_time, a.status,
       p.patient_id, p.name AS patient_name, p.date_of_birth, p.gender, p.phone,
       d.doctor_id, d.name AS doctor_name, d.specialization, d.role,
       dp.department_id, dp.name AS department_name
FROM hospital.appointments a
JOIN hospital.patients p     USING (patient_id)
JOIN hospital.doctors d      USING (doctor_id)
JOIN hospital.departments dp ON dp.department_id = d.department_id;

CREATE TABLE redundancy.flat_activity_register AS
SELECT x.line_type, x.line_id, x.detail_1, x.detail_2, x.detail_3,
       v.*
FROM (
    SELECT 'prescription' AS line_type, prescription_id AS line_id, appointment_id,
           medication AS detail_1, dosage AS detail_2, NULL::TEXT AS detail_3 FROM hospital.prescriptions
    UNION ALL
    SELECT 'bill', bill_id, appointment_id, amount::TEXT, paid::TEXT, bill_date::TEXT FROM hospital.bills
    UNION ALL
    SELECT 'lab', report_id, appointment_id, report_data::TEXT, created_at::TEXT, NULL FROM hospital.lab_reports
) x
JOIN redundancy.flat_visit_register v USING (appointment_id);

\echo
\echo '=== 1. Repeated descriptive values (patient / doctor / department / visit attributes) ==='
WITH flat AS (
    SELECT 'visit register (1 row per appointment)' AS layout,
           (SELECT count(*) FROM redundancy.flat_visit_register) * (4 + 3 + 1)     AS flat_values,
           (SELECT count(*) FROM hospital.patients) * 4
         + (SELECT count(*) FROM hospital.doctors) * 3
         + (SELECT count(*) FROM hospital.departments) * 1                          AS normalized_values
    UNION ALL
    SELECT 'activity register (1 row per Rx / bill / lab line)',
           (SELECT count(*) FROM redundancy.flat_activity_register) * (4 + 3 + 1 + 2),
           (SELECT count(*) FROM hospital.patients) * 4
         + (SELECT count(*) FROM hospital.doctors) * 3
         + (SELECT count(*) FROM hospital.departments) * 1
         + (SELECT count(*) FROM hospital.appointments) * 2
)
SELECT layout, flat_values, normalized_values,
       flat_values - normalized_values                              AS duplicate_values_removed,
       round(100.0 * (flat_values - normalized_values) / flat_values, 1) AS "redundancy reduction %"
FROM flat;

\echo '=== 2. Bytes on disk for the same information (heap only, no indexes) ==='
WITH s AS (
    SELECT pg_table_size('redundancy.flat_visit_register')    AS flat_visit,
           pg_table_size('redundancy.flat_activity_register') AS flat_activity,
           pg_table_size('hospital.appointments') + pg_table_size('hospital.patients')
         + pg_table_size('hospital.doctors')      + pg_table_size('hospital.departments') AS norm_visit,
           pg_table_size('hospital.appointments') + pg_table_size('hospital.patients')
         + pg_table_size('hospital.doctors')      + pg_table_size('hospital.departments')
         + pg_table_size('hospital.prescriptions') + pg_table_size('hospital.bills')
         + pg_table_size('hospital.lab_reports')                                          AS norm_activity
)
SELECT 'visit register'    AS layout, pg_size_pretty(flat_visit) AS flat, pg_size_pretty(norm_visit) AS normalized,
       round(100.0 * (flat_visit - norm_visit) / flat_visit, 1) AS "storage reduction %" FROM s
UNION ALL
SELECT 'activity register', pg_size_pretty(flat_activity), pg_size_pretty(norm_activity),
       round(100.0 * (flat_activity - norm_activity) / flat_activity, 1) FROM s;

\echo '=== 3. The legacy extract itself ==='
SELECT count(*) * 30                                                       AS legacy_cells,
       (SELECT (standardized->>'blank_padding_cells_dropped')::INT
        FROM etl.etl_run ORDER BY run_id DESC LIMIT 1)                     AS blank_padding_cells,
       round(100.0 * (SELECT (standardized->>'blank_padding_cells_dropped')::INT
                      FROM etl.etl_run ORDER BY run_id DESC LIMIT 1) / (count(*) * 30), 1) AS "% of sheet that was empty padding"
FROM etl.stg_hospital_raw;

DROP SCHEMA redundancy CASCADE;
