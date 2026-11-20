-- =====================================================================================
-- 06_run_and_validate.sql  -  run the ETL, then prove the result is correct
-- -------------------------------------------------------------------------------------
-- The postgres entrypoint runs init scripts with ON_ERROR_STOP=1, so any failed assertion
-- below aborts initialisation and the container does NOT come up "healthy". A database
-- that fails validation is never served.
-- =====================================================================================

CALL etl.run_migration('/project');

DO $$
DECLARE
    v_run   INT := (SELECT max(run_id) FROM etl.etl_run);
    v_n     BIGINT;
    v_txt   TEXT;
    r       RECORD;
BEGIN
    -- 1. structure ---------------------------------------------------------------------
    SELECT count(*) INTO v_n FROM information_schema.tables
    WHERE table_schema = 'hospital' AND table_type = 'BASE TABLE';
    IF v_n <> 9 THEN RAISE EXCEPTION 'VALIDATION: expected 9 hospital tables, found %', v_n; END IF;

    -- 2. run status ----------------------------------------------------------------------
    IF (SELECT status FROM etl.etl_run WHERE run_id = v_run) <> 'SUCCEEDED' THEN
        RAISE EXCEPTION 'VALIDATION: ETL run % did not succeed', v_run;
    END IF;

    -- 3. reference-data completeness ----------------------------------------------------
    IF (SELECT count(*) FROM hospital.departments) <> 10  THEN RAISE EXCEPTION 'VALIDATION: departments <> 10'; END IF;
    IF (SELECT count(*) FROM hospital.doctors)     <> 200 THEN RAISE EXCEPTION 'VALIDATION: doctors <> 200'; END IF;
    IF (SELECT count(*) FROM hospital.wards)       <> 15  THEN RAISE EXCEPTION 'VALIDATION: wards <> 15'; END IF;
    IF (SELECT count(*) FROM auth.doctor_credentials) <> (SELECT count(*) FROM hospital.doctors) THEN
        RAISE EXCEPTION 'VALIDATION: every doctor must have credentials';
    END IF;

    -- 4. reconciliation: every source record is either loaded or quarantined -----------
    FOR r IN
        SELECT * FROM (VALUES
            ('patients',      (SELECT count(*) FROM etl.stg_hospital_raw WHERE trim(pat_id)  <> ''), (SELECT count(*) FROM hospital.patients)),
            ('appointments',  (SELECT count(*) FROM etl.stg_hospital_raw WHERE trim(appt_id) <> ''), (SELECT count(*) FROM hospital.appointments)),
            ('prescriptions', (SELECT count(*) FROM etl.stg_hospital_raw WHERE trim(rx_id)   <> ''), (SELECT count(*) FROM hospital.prescriptions)),
            ('bills',         (SELECT count(*) FROM etl.stg_hospital_raw WHERE trim(bill_id) <> ''), (SELECT count(*) FROM hospital.bills)),
            ('lab_reports',   (SELECT count(*) FROM etl.stg_hospital_raw WHERE trim(lab_id)  <> ''), (SELECT count(*) FROM hospital.lab_reports)),
            ('admissions',    (SELECT count(*) FROM etl.stg_admissions),                             (SELECT count(*) FROM hospital.admissions))
        ) t(entity, source_rows, loaded_rows)
    LOOP
        SELECT count(*) INTO v_n FROM etl.quarantine WHERE run_id = v_run AND entity = r.entity;
        IF r.source_rows <> r.loaded_rows + v_n THEN
            RAISE EXCEPTION 'VALIDATION: % not reconciled: source % <> loaded % + quarantined %',
                r.entity, r.source_rows, r.loaded_rows, v_n;
        END IF;
    END LOOP;

    -- 5. integrity rules hold in the final data ----------------------------------------
    SELECT count(*) INTO v_n FROM (
        SELECT 1 FROM hospital.appointments WHERE status <> 'Cancelled'
        GROUP BY doctor_id, appointment_time HAVING count(*) > 1) x;
    IF v_n > 0 THEN RAISE EXCEPTION 'VALIDATION: % doctor double-bookings remain', v_n; END IF;

    SELECT count(*) INTO v_n FROM hospital.bills b JOIN hospital.appointments a USING (appointment_id)
    WHERE a.status = 'Cancelled';
    IF v_n > 0 THEN RAISE EXCEPTION 'VALIDATION: % bills on cancelled appointments', v_n; END IF;

    SELECT count(*) INTO v_n FROM analytics.v_ward_daily_occupancy WHERE occupied_beds > bed_capacity;
    IF v_n > 0 THEN RAISE EXCEPTION 'VALIDATION: ward over capacity on % ward-days', v_n; END IF;

    SELECT count(*) INTO v_n FROM hospital.admissions m1 JOIN hospital.appointments a1 USING (appointment_id)
    JOIN hospital.admissions m2 ON m2.admission_id > m1.admission_id
    JOIN hospital.appointments a2 ON a2.appointment_id = m2.appointment_id AND a2.patient_id = a1.patient_id
    WHERE m1.admitted_at < COALESCE(m2.discharged_at, 'infinity') AND m2.admitted_at < COALESCE(m1.discharged_at, 'infinity');
    IF v_n > 0 THEN RAISE EXCEPTION 'VALIDATION: % overlapping stays for the same patient', v_n; END IF;

    -- 6. identity sequences continue after migrated IDs --------------------------------
    IF (SELECT last_value FROM pg_sequences WHERE schemaname = 'hospital' AND sequencename LIKE 'appointments%')
       < (SELECT max(appointment_id) FROM hospital.appointments) THEN
        RAISE EXCEPTION 'VALIDATION: appointment identity sequence not re-synced';
    END IF;

    -- 7. business-rule trigger rejects bad bookings (tested in sub-transactions) --------
    BEGIN
        INSERT INTO hospital.appointments (patient_id, doctor_id, appointment_time, status)
        VALUES (1, 1, now() - INTERVAL '1 day', 'Scheduled');
        RAISE EXCEPTION 'VALIDATION: past appointment was accepted';
    EXCEPTION WHEN check_violation THEN NULL;   -- expected
    END;

    SELECT doctor_id, appointment_time INTO r FROM hospital.appointments WHERE status <> 'Cancelled' LIMIT 1;
    BEGIN
        PERFORM set_config('hospital.etl_mode', 'off', true);
        INSERT INTO hospital.appointments (patient_id, doctor_id, appointment_time, status)
        VALUES (2, r.doctor_id, r.appointment_time, 'Completed');
        RAISE EXCEPTION 'VALIDATION: doctor double-booking was accepted';
    EXCEPTION WHEN unique_violation THEN NULL;  -- expected
    END;

    -- 8. login check works against bcrypt hashes ----------------------------------------
    PERFORM * FROM hospital.view_doctor_data('doctor1', 'W3jzIANG');
    BEGIN
        PERFORM * FROM hospital.view_doctor_data('doctor1', 'wrong-password');
        RAISE EXCEPTION 'VALIDATION: wrong password accepted';
    EXCEPTION WHEN invalid_password THEN NULL;  -- expected
    END;

    SELECT loaded_rows::TEXT INTO v_txt FROM etl.etl_run WHERE run_id = v_run;
    RAISE NOTICE 'VALIDATION PASSED (run %): %', v_run, v_txt;
END $$;
