-- =====================================================================================
-- 03_etl.sql  -  Automated, idempotent ETL:  legacy CSV extract  ->  normalized HospitalDB
-- -------------------------------------------------------------------------------------
--  EXTRACT   COPY the raw files into all-TEXT staging tables (nothing can fail on load)
--  TRANSFORM strict typed parsing  +  data-integrity rules implemented with WINDOW
--            FUNCTIONS (ROW_NUMBER / COUNT OVER).  Every fix is written to
--            etl.data_quality_log; rejected rows are kept in etl.quarantine.
--  LOAD      truncate + reload the 7 core hospital tables and the 2 inpatient tables in
--            FK order, re-sync identities,
--            hash credentials.
--
--  Run any time:   CALL etl.run_migration();        (default source dir: /project)
--  The whole procedure runs in ONE transaction - any failure rolls everything back, so
--  the database is never left half-migrated.
-- =====================================================================================

-- ---------------------------------------------------------------- audit / control tables
CREATE TABLE etl.etl_run (
    run_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finished_at   TIMESTAMPTZ,
    status        TEXT NOT NULL DEFAULT 'RUNNING',
    source_rows   INT,
    loaded_rows   JSONB,         -- rows per target table
    standardized  JSONB          -- format conversions applied (not errors)
);

CREATE TABLE etl.data_quality_log (
    log_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id     INT  NOT NULL REFERENCES etl.etl_run (run_id),
    rule_code  TEXT NOT NULL,
    entity     TEXT NOT NULL,
    record_id  INT,
    action     TEXT NOT NULL CHECK (action IN ('CORRECTED', 'QUARANTINED', 'FLAGGED')),
    detail     TEXT,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE etl.quarantine (
    run_id     INT  NOT NULL REFERENCES etl.etl_run (run_id),
    entity     TEXT NOT NULL,
    record_id  INT,
    rule_code  TEXT NOT NULL,
    payload    JSONB NOT NULL
);

-- ---------------------------------------------------------------- raw staging (all TEXT)
CREATE TABLE etl.stg_hospital_raw (
    dept_id TEXT, dept_name TEXT,
    doc_id TEXT, doc_name TEXT, doc_specialization TEXT, doc_role TEXT, doc_dept_id TEXT,
    pat_id TEXT, pat_name TEXT, pat_dob TEXT, pat_gender TEXT, pat_phone TEXT,
    appt_id TEXT, appt_patient_id TEXT, appt_doctor_id TEXT, appt_time TEXT, appt_status TEXT,
    rx_id TEXT, rx_appt_id TEXT, rx_medication TEXT, rx_dosage TEXT,
    bill_id TEXT, bill_appt_id TEXT, bill_amount TEXT, bill_paid TEXT, bill_date TEXT,
    lab_id TEXT, lab_appt_id TEXT, lab_data TEXT, lab_created_at TEXT
);
CREATE TABLE etl.stg_doctor_credentials (doctor_id TEXT, user_name TEXT, password TEXT);
CREATE TABLE etl.stg_wards      (ward_id TEXT, ward_name TEXT, department_id TEXT, ward_type TEXT, bed_capacity TEXT);
CREATE TABLE etl.stg_admissions (admission_id TEXT, appointment_id TEXT, ward_id TEXT, admitted_at TEXT, discharged_at TEXT);

-- ---------------------------------------------------------------- strict parsing helpers
-- Return NULL instead of raising, so bad values can be quarantined rather than abort the run.
CREATE FUNCTION etl.try_int(v TEXT) RETURNS INT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN v ~ '^\s*[0-9]{1,9}\s*$' THEN trim(v)::INT END
$$;

CREATE FUNCTION etl.try_numeric(v TEXT) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN v ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' THEN trim(v)::NUMERIC END
$$;

-- to_timestamp() silently rolls invalid dates over (31-02 -> 03-03); the round-trip
-- comparison rejects them instead.
CREATE FUNCTION etl.try_ts(v TEXT, fmt TEXT) RETURNS TIMESTAMP
LANGUAGE plpgsql STABLE AS $$
DECLARE t TIMESTAMP;
BEGIN
    IF v IS NULL OR trim(v) = '' THEN RETURN NULL; END IF;
    t := to_timestamp(trim(v), fmt)::TIMESTAMP;
    IF to_char(t, fmt) <> trim(v) THEN RETURN NULL; END IF;
    RETURN t;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE FUNCTION etl.try_jsonb(v TEXT) RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN v::JSONB;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

-- Move rows of a work table whose required columns failed to parse into quarantine.
CREATE PROCEDURE etl.quarantine_unparseable(p_run INT, p_table TEXT, p_entity TEXT,
                                            p_id_col TEXT, p_required TEXT[])
LANGUAGE plpgsql AS $$
DECLARE
    v_cond TEXT;
BEGIN
    SELECT string_agg(format('%I IS NULL', c), ' OR ') INTO v_cond FROM unnest(p_required) c;
    EXECUTE format($q$
        WITH bad AS (DELETE FROM %1$I WHERE %2$s RETURNING *),
             q   AS (INSERT INTO etl.quarantine (run_id, entity, record_id, rule_code, payload)
                     SELECT %3$s, %4$L, %5$I, 'R00_UNPARSEABLE_VALUE', raw FROM bad)
        INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
        SELECT %3$s, 'R00_UNPARSEABLE_VALUE', %4$L, %5$I, 'QUARANTINED',
               'required field missing or not parseable: ' || raw::TEXT
        FROM bad $q$, p_table, v_cond, p_run, p_entity, p_id_col);
END $$;

-- =====================================================================================
--  MAIN PROCEDURE
-- =====================================================================================
CREATE PROCEDURE etl.run_migration(p_dir TEXT DEFAULT '/project')
LANGUAGE plpgsql AS $proc$
DECLARE
    v_run     INT;
    v_cnt     INT;
    v_extract TIMESTAMP;
BEGIN
    INSERT INTO etl.etl_run DEFAULT VALUES RETURNING run_id INTO v_run;
    RAISE NOTICE '[ETL run %] started', v_run;

    -- ============================================================== 1. EXTRACT
    TRUNCATE etl.stg_hospital_raw, etl.stg_doctor_credentials, etl.stg_wards, etl.stg_admissions;
    EXECUTE format('COPY etl.stg_hospital_raw       FROM %L WITH (FORMAT csv, HEADER true)', p_dir || '/hospital_data_10000_rows.csv');
    EXECUTE format('COPY etl.stg_doctor_credentials FROM %L WITH (FORMAT csv, HEADER true)', p_dir || '/doctor_credentials.csv');
    EXECUTE format('COPY etl.stg_wards              FROM %L WITH (FORMAT csv, HEADER true)', p_dir || '/data/wards.csv');
    EXECUTE format('COPY etl.stg_admissions         FROM %L WITH (FORMAT csv, HEADER true)', p_dir || '/data/admissions.csv');
    SELECT count(*) INTO v_cnt FROM etl.stg_hospital_raw;
    UPDATE etl.etl_run SET source_rows = v_cnt WHERE run_id = v_run;
    RAISE NOTICE '[ETL] extracted % legacy rows', v_cnt;

    -- ============================================================== 2. TRANSFORM
    -- The legacy sheet stores 7 different tables side-by-side in one grid, padded with
    -- blanks. Each entity is sliced out where its own key is present, then strictly typed.
    PERFORM set_config('client_min_messages', 'warning', true);   -- hide "does not exist, skipping"
    DROP TABLE IF EXISTS w_departments, w_doctors, w_patients, w_appointments,
                         w_prescriptions, w_bills, w_lab_reports, w_wards, w_admissions;
    PERFORM set_config('client_min_messages', 'notice', true);

    CREATE TEMP TABLE w_departments AS
        SELECT etl.try_int(dept_id) AS department_id, NULLIF(trim(dept_name), '') AS name,
               to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(dept_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_doctors AS
        SELECT etl.try_int(doc_id) AS doctor_id, NULLIF(trim(doc_name), '') AS name,
               NULLIF(trim(doc_specialization), '') AS specialization,
               initcap(NULLIF(trim(doc_role), '')) AS role,
               etl.try_int(doc_dept_id) AS department_id, to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(doc_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_patients AS
        SELECT etl.try_int(pat_id) AS patient_id, NULLIF(trim(pat_name), '') AS name,
               etl.try_ts(pat_dob, 'DD-MM-YYYY')::DATE AS date_of_birth,
               CASE WHEN lower(trim(pat_gender)) IN ('m', 'f', 'o') THEN lower(trim(pat_gender)) END AS gender,
               CASE WHEN regexp_replace(pat_phone, '\D', '', 'g') ~ '^[0-9]{10}$'
                    THEN regexp_replace(pat_phone, '\D', '', 'g') END AS phone,
               to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(pat_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_appointments AS
        SELECT etl.try_int(appt_id) AS appointment_id, etl.try_int(appt_patient_id) AS patient_id,
               etl.try_int(appt_doctor_id) AS doctor_id,
               etl.try_ts(appt_time, 'DD-MM-YYYY HH24:MI') AS appointment_time,
               CASE WHEN initcap(trim(appt_status)) IN ('Scheduled', 'Completed', 'Cancelled')
                    THEN initcap(trim(appt_status)) END AS status,
               to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(appt_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_prescriptions AS
        SELECT etl.try_int(rx_id) AS prescription_id, etl.try_int(rx_appt_id) AS appointment_id,
               NULLIF(trim(rx_medication), '') AS medication, NULLIF(trim(rx_dosage), '') AS dosage,
               to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(rx_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_bills AS
        SELECT etl.try_int(bill_id) AS bill_id, etl.try_int(bill_appt_id) AS appointment_id,
               etl.try_numeric(bill_amount)::NUMERIC(10, 2) AS amount,
               CASE trim(bill_paid) WHEN '1' THEN TRUE WHEN '0' THEN FALSE END AS paid,
               etl.try_ts(bill_date, 'YYYY-MM-DD HH24:MI:SS') AS bill_date,
               to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(bill_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_lab_reports AS
        SELECT etl.try_int(lab_id) AS report_id, etl.try_int(lab_appt_id) AS appointment_id,
               etl.try_jsonb(lab_data) AS report_data,
               etl.try_ts(lab_created_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at,
               to_jsonb(s) AS raw
        FROM etl.stg_hospital_raw s WHERE NULLIF(trim(lab_id), '') IS NOT NULL;

    CREATE TEMP TABLE w_wards AS
        SELECT etl.try_int(ward_id) AS ward_id, NULLIF(trim(ward_name), '') AS ward_name,
               etl.try_int(department_id) AS department_id, NULLIF(trim(ward_type), '') AS ward_type,
               etl.try_int(bed_capacity) AS bed_capacity, to_jsonb(s) AS raw
        FROM etl.stg_wards s;

    CREATE TEMP TABLE w_admissions AS
        SELECT etl.try_int(admission_id) AS admission_id, etl.try_int(appointment_id) AS appointment_id,
               etl.try_int(ward_id) AS ward_id,
               etl.try_ts(admitted_at, 'YYYY-MM-DD HH24:MI:SS') AS admitted_at,
               etl.try_ts(discharged_at, 'YYYY-MM-DD HH24:MI:SS') AS discharged_at,
               to_jsonb(s) AS raw
        FROM etl.stg_admissions s;

    -- Format standardizations (legal values in a different representation - not errors)
    UPDATE etl.etl_run SET standardized = jsonb_build_object(
        'gender_uppercase_to_lowercase', (SELECT count(*) FROM etl.stg_hospital_raw WHERE pat_gender ~ '[A-Z]'),
        'dob_dd-mm-yyyy_to_date',        (SELECT count(*) FROM w_patients),
        'appt_time_text_to_timestamp',   (SELECT count(*) FROM w_appointments),
        'bill_paid_0/1_to_boolean',      (SELECT count(*) FROM w_bills),
        'lab_report_text_to_jsonb',      (SELECT count(*) FROM w_lab_reports),
        'blank_padding_cells_dropped',   (SELECT count(*) FROM etl.stg_hospital_raw s
                                          CROSS JOIN LATERAL jsonb_each_text(to_jsonb(s)) e
                                          WHERE NULLIF(trim(e.value), '') IS NULL)
    ) WHERE run_id = v_run;

    -- ---------------------------------------------------------- R00 unparseable values
    CALL etl.quarantine_unparseable(v_run, 'w_departments',   'departments',   'department_id',   ARRAY['department_id','name']);
    CALL etl.quarantine_unparseable(v_run, 'w_doctors',       'doctors',       'doctor_id',       ARRAY['doctor_id','name','specialization','role','department_id']);
    CALL etl.quarantine_unparseable(v_run, 'w_patients',      'patients',      'patient_id',      ARRAY['patient_id','name','date_of_birth','gender','phone']);
    CALL etl.quarantine_unparseable(v_run, 'w_appointments',  'appointments',  'appointment_id',  ARRAY['appointment_id','patient_id','doctor_id','appointment_time','status']);
    CALL etl.quarantine_unparseable(v_run, 'w_prescriptions', 'prescriptions', 'prescription_id', ARRAY['prescription_id','appointment_id','medication','dosage']);
    CALL etl.quarantine_unparseable(v_run, 'w_bills',         'bills',         'bill_id',         ARRAY['bill_id','appointment_id','amount','paid','bill_date']);
    CALL etl.quarantine_unparseable(v_run, 'w_lab_reports',   'lab_reports',   'report_id',       ARRAY['report_id','appointment_id','report_data','created_at']);
    CALL etl.quarantine_unparseable(v_run, 'w_wards',         'wards',         'ward_id',         ARRAY['ward_id','ward_name','department_id','ward_type','bed_capacity']);
    CALL etl.quarantine_unparseable(v_run, 'w_admissions',    'admissions',    'admission_id',    ARRAY['admission_id','appointment_id','ward_id','admitted_at']);

    -- ---------------------------------------------------------- R01 duplicate primary keys
    -- ROW_NUMBER() keeps the first occurrence of a re-used ID; repeats are quarantined.
    WITH ranked AS (
        SELECT ctid, patient_id, ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY ctid) AS rn
        FROM w_patients),
    del AS (DELETE FROM w_patients p USING ranked r WHERE p.ctid = r.ctid AND r.rn > 1 RETURNING p.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'patients', patient_id, 'R01_DUPLICATE_KEY', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R01_DUPLICATE_KEY', 'patients', patient_id, 'QUARANTINED', 'patient_id already used' FROM del;

    WITH ranked AS (
        SELECT ctid, ROW_NUMBER() OVER (PARTITION BY appointment_id ORDER BY ctid) AS rn FROM w_appointments),
    del AS (DELETE FROM w_appointments a USING ranked r WHERE a.ctid = r.ctid AND r.rn > 1 RETURNING a.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'appointments', appointment_id, 'R01_DUPLICATE_KEY', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R01_DUPLICATE_KEY', 'appointments', appointment_id, 'QUARANTINED', 'appointment_id already used' FROM del;

    -- ---------------------------------------------------------- R02 orphan references
    WITH del AS (
        DELETE FROM w_doctors d WHERE NOT EXISTS (SELECT 1 FROM w_departments x WHERE x.department_id = d.department_id)
        RETURNING d.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'doctors', doctor_id, 'R02_ORPHAN_REFERENCE', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R02_ORPHAN_REFERENCE', 'doctors', doctor_id, 'QUARANTINED', 'unknown department ' || department_id FROM del;

    WITH del AS (
        DELETE FROM w_appointments a
        WHERE NOT EXISTS (SELECT 1 FROM w_patients p WHERE p.patient_id = a.patient_id)
           OR NOT EXISTS (SELECT 1 FROM w_doctors d  WHERE d.doctor_id  = a.doctor_id)
        RETURNING a.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'appointments', appointment_id, 'R02_ORPHAN_REFERENCE', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R02_ORPHAN_REFERENCE', 'appointments', appointment_id, 'QUARANTINED', 'unknown patient or doctor' FROM del;

    -- ---------------------------------------------------------- R03 doctor double-booking
    -- A doctor cannot see two patients in the same slot. Among live bookings of a slot,
    -- ROW_NUMBER() keeps the one that actually happened (Completed first, then lowest ID);
    -- the conflicting duplicates are corrected to 'Cancelled'.
    WITH ranked AS (
        SELECT appointment_id, doctor_id, appointment_time, status,
               ROW_NUMBER() OVER (PARTITION BY doctor_id, appointment_time
                                  ORDER BY (status = 'Completed') DESC, appointment_id) AS rn
        FROM w_appointments WHERE status <> 'Cancelled'),
    upd AS (
        UPDATE w_appointments a SET status = 'Cancelled'
        FROM ranked r WHERE a.appointment_id = r.appointment_id AND r.rn > 1
        RETURNING a.appointment_id, r.doctor_id, r.appointment_time, r.status AS old_status)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R03_DOCTOR_DOUBLE_BOOKING', 'appointments', appointment_id, 'CORRECTED',
           format('doctor %s already booked at %s; status %s -> Cancelled', doctor_id, appointment_time, old_status)
    FROM upd;

    -- ---------------------------------------------------------- R04 patient double-booking
    WITH ranked AS (
        SELECT appointment_id, patient_id, appointment_time, status,
               ROW_NUMBER() OVER (PARTITION BY patient_id, appointment_time
                                  ORDER BY (status = 'Completed') DESC, appointment_id) AS rn
        FROM w_appointments WHERE status <> 'Cancelled'),
    upd AS (
        UPDATE w_appointments a SET status = 'Cancelled'
        FROM ranked r WHERE a.appointment_id = r.appointment_id AND r.rn > 1
        RETURNING a.appointment_id, r.patient_id, r.appointment_time, r.status AS old_status)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R04_PATIENT_DOUBLE_BOOKING', 'appointments', appointment_id, 'CORRECTED',
           format('patient %s already booked at %s; status %s -> Cancelled', patient_id, appointment_time, old_status)
    FROM upd;

    -- ---------------------------------------------------------- R05 orphan child records
    WITH del AS (DELETE FROM w_prescriptions c WHERE NOT EXISTS (SELECT 1 FROM w_appointments a WHERE a.appointment_id = c.appointment_id) RETURNING c.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'prescriptions', prescription_id, 'R02_ORPHAN_REFERENCE', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R02_ORPHAN_REFERENCE', 'prescriptions', prescription_id, 'QUARANTINED', 'unknown appointment' FROM del;

    WITH del AS (DELETE FROM w_bills c WHERE NOT EXISTS (SELECT 1 FROM w_appointments a WHERE a.appointment_id = c.appointment_id) RETURNING c.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'bills', bill_id, 'R02_ORPHAN_REFERENCE', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R02_ORPHAN_REFERENCE', 'bills', bill_id, 'QUARANTINED', 'unknown appointment' FROM del;

    WITH del AS (DELETE FROM w_lab_reports c WHERE NOT EXISTS (SELECT 1 FROM w_appointments a WHERE a.appointment_id = c.appointment_id) RETURNING c.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'lab_reports', report_id, 'R02_ORPHAN_REFERENCE', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R02_ORPHAN_REFERENCE', 'lab_reports', report_id, 'QUARANTINED', 'unknown appointment' FROM del;

    -- ---------------------------------------------------------- R06 activity on cancelled visits
    -- A cancelled appointment never took place, so it cannot carry a bill, a prescription
    -- or a lab report. Such rows are quarantined for manual review (not silently deleted).
    WITH del AS (DELETE FROM w_bills c USING w_appointments a
                 WHERE a.appointment_id = c.appointment_id AND a.status = 'Cancelled' RETURNING c.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'bills', bill_id, 'R06_BILL_ON_CANCELLED_VISIT', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R06_BILL_ON_CANCELLED_VISIT', 'bills', bill_id, 'QUARANTINED',
           format('bill %s (%s) raised against cancelled appointment %s', bill_id, amount, appointment_id) FROM del;

    WITH del AS (DELETE FROM w_prescriptions c USING w_appointments a
                 WHERE a.appointment_id = c.appointment_id AND a.status = 'Cancelled' RETURNING c.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'prescriptions', prescription_id, 'R06_PRESCRIPTION_ON_CANCELLED_VISIT', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R06_PRESCRIPTION_ON_CANCELLED_VISIT', 'prescriptions', prescription_id, 'QUARANTINED',
           format('%s prescribed on cancelled appointment %s', medication, appointment_id) FROM del;

    WITH del AS (DELETE FROM w_lab_reports c USING w_appointments a
                 WHERE a.appointment_id = c.appointment_id AND a.status = 'Cancelled' RETURNING c.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'lab_reports', report_id, 'R06_LAB_ON_CANCELLED_VISIT', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R06_LAB_ON_CANCELLED_VISIT', 'lab_reports', report_id, 'QUARANTINED',
           format('lab report on cancelled appointment %s', appointment_id) FROM del;

    -- ---------------------------------------------------------- R07 duplicate prescription lines
    -- Same drug entered more than once for the same visit: ROW_NUMBER() keeps the latest
    -- entry (highest ID = most recent dosage instruction) and removes the duplicates.
    WITH ranked AS (
        SELECT prescription_id,
               ROW_NUMBER() OVER (PARTITION BY appointment_id, medication ORDER BY prescription_id DESC) AS rn,
               COUNT(*)     OVER (PARTITION BY appointment_id, medication) AS copies
        FROM w_prescriptions),
    del AS (DELETE FROM w_prescriptions p USING ranked r
            WHERE p.prescription_id = r.prescription_id AND r.rn > 1
            RETURNING p.*, r.copies),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'prescriptions', prescription_id, 'R07_DUPLICATE_PRESCRIPTION', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R07_DUPLICATE_PRESCRIPTION', 'prescriptions', prescription_id, 'CORRECTED',
           format('%s entered %s times on appointment %s; kept latest', medication, copies, appointment_id) FROM del;

    -- ---------------------------------------------------------- R08 admission integrity
    WITH del AS (DELETE FROM w_admissions m
                 WHERE NOT EXISTS (SELECT 1 FROM w_appointments a WHERE a.appointment_id = m.appointment_id AND a.status = 'Completed')
                    OR NOT EXISTS (SELECT 1 FROM w_wards w WHERE w.ward_id = m.ward_id)
                 RETURNING m.*),
    q AS (INSERT INTO etl.quarantine SELECT v_run, 'admissions', admission_id, 'R08_INVALID_ADMISSION', raw FROM del)
    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R08_INVALID_ADMISSION', 'admissions', admission_id, 'QUARANTINED',
           'admission must come from a completed appointment and a known ward' FROM del;

    -- ---------------------------------------------------------- R09 temporal anomalies (FLAG only)
    -- These cannot be fixed automatically (the true timestamp is unknown), so the rows are
    -- loaded unchanged and flagged for the records team.
    v_extract := (SELECT max(appointment_time) FROM w_appointments);

    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R09_BILL_BEFORE_VISIT', 'bills', b.bill_id, 'FLAGGED',
           format('bill dated %s, appointment at %s', b.bill_date, a.appointment_time)
    FROM w_bills b JOIN w_appointments a USING (appointment_id) WHERE b.bill_date < a.appointment_time;

    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R09_LAB_BEFORE_VISIT', 'lab_reports', l.report_id, 'FLAGGED',
           format('report created %s, appointment at %s', l.created_at, a.appointment_time)
    FROM w_lab_reports l JOIN w_appointments a USING (appointment_id) WHERE l.created_at < a.appointment_time;

    INSERT INTO etl.data_quality_log (run_id, rule_code, entity, record_id, action, detail)
    SELECT v_run, 'R09_STALE_SCHEDULED', 'appointments', appointment_id, 'FLAGGED',
           format('still "Scheduled" but slot %s is more than 30 days before extract date %s', appointment_time, v_extract)
    FROM w_appointments WHERE status = 'Scheduled' AND appointment_time < v_extract - INTERVAL '30 days';

    -- ============================================================== 3. LOAD
    -- Bypass the interactive-booking trigger (04_business_rules.sql) for historical rows.
    PERFORM set_config('hospital.etl_mode', 'on', true);

    TRUNCATE inpatient.admissions, inpatient.wards, hospital.lab_reports, hospital.bills,
             hospital.prescriptions, hospital.appointments, hospital.patients,
             hospital.doctors, hospital.departments, auth.doctor_credentials
             RESTART IDENTITY CASCADE;

    INSERT INTO hospital.departments  SELECT department_id, name FROM w_departments ORDER BY 1;
    INSERT INTO hospital.doctors      SELECT doctor_id, name, specialization, role, department_id FROM w_doctors ORDER BY 1;
    INSERT INTO hospital.patients     SELECT patient_id, name, date_of_birth, gender, phone FROM w_patients ORDER BY 1;
    INSERT INTO hospital.appointments SELECT appointment_id, patient_id, doctor_id, appointment_time, status FROM w_appointments ORDER BY 1;
    INSERT INTO hospital.prescriptions SELECT prescription_id, appointment_id, medication, dosage FROM w_prescriptions ORDER BY 1;
    INSERT INTO hospital.bills        SELECT bill_id, appointment_id, amount, paid, bill_date FROM w_bills ORDER BY 1;
    INSERT INTO hospital.lab_reports  SELECT report_id, appointment_id, report_data, created_at FROM w_lab_reports ORDER BY 1;
    INSERT INTO inpatient.wards        SELECT ward_id, ward_name, department_id, ward_type, bed_capacity FROM w_wards ORDER BY 1;
    INSERT INTO inpatient.admissions   SELECT admission_id, appointment_id, ward_id, admitted_at, discharged_at FROM w_admissions ORDER BY 1;

    -- Credentials: bcrypt-hash on the way in; plaintext never reaches a permanent table.
    INSERT INTO auth.doctor_credentials (doctor_id, username, password_hash)
    SELECT etl.try_int(c.doctor_id), trim(c.user_name), crypt(trim(c.password), gen_salt('bf', 8))
    FROM etl.stg_doctor_credentials c
    WHERE EXISTS (SELECT 1 FROM hospital.doctors d WHERE d.doctor_id = etl.try_int(c.doctor_id));
    TRUNCATE etl.stg_doctor_credentials;

    -- Re-sync identity sequences so new rows continue after the migrated IDs.
    DECLARE
        r RECORD; v_max INT;
    BEGIN
        FOR r IN SELECT * FROM (VALUES ('hospital', 'departments', 'department_id'),
                                       ('hospital', 'doctors', 'doctor_id'),
                                       ('hospital', 'patients', 'patient_id'),
                                       ('hospital', 'appointments', 'appointment_id'),
                                       ('hospital', 'prescriptions', 'prescription_id'),
                                       ('hospital', 'bills', 'bill_id'),
                                       ('hospital', 'lab_reports', 'report_id'),
                                       ('inpatient', 'wards', 'ward_id'),
                                       ('inpatient', 'admissions', 'admission_id')) v(s, t, c)
        LOOP
            EXECUTE format('SELECT max(%I) FROM %I.%I', r.c, r.s, r.t) INTO v_max;
            PERFORM setval(pg_get_serial_sequence(r.s || '.' || r.t, r.c), COALESCE(v_max, 1), v_max IS NOT NULL);
        END LOOP;
    END;

    ANALYZE hospital.departments, hospital.doctors, hospital.patients, hospital.appointments,
            hospital.prescriptions, hospital.bills, hospital.lab_reports, inpatient.wards, inpatient.admissions;

    UPDATE etl.etl_run SET
        finished_at = clock_timestamp(),
        status      = 'SUCCEEDED',
        loaded_rows = jsonb_build_object(
            'departments',   (SELECT count(*) FROM hospital.departments),
            'doctors',       (SELECT count(*) FROM hospital.doctors),
            'patients',      (SELECT count(*) FROM hospital.patients),
            'appointments',  (SELECT count(*) FROM hospital.appointments),
            'prescriptions', (SELECT count(*) FROM hospital.prescriptions),
            'bills',         (SELECT count(*) FROM hospital.bills),
            'lab_reports',   (SELECT count(*) FROM hospital.lab_reports),
            'wards',         (SELECT count(*) FROM inpatient.wards),
            'admissions',    (SELECT count(*) FROM inpatient.admissions),
            'doctor_credentials', (SELECT count(*) FROM auth.doctor_credentials))
    WHERE run_id = v_run;

    RAISE NOTICE '[ETL run %] finished: % integrity fixes (corrected+quarantined), % flagged',
        v_run,
        (SELECT count(*) FROM etl.data_quality_log WHERE run_id = v_run AND action IN ('CORRECTED','QUARANTINED')),
        (SELECT count(*) FROM etl.data_quality_log WHERE run_id = v_run AND action = 'FLAGGED');
END
$proc$;
