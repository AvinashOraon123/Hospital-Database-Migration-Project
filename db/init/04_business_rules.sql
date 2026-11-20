-- =====================================================================================
-- 04_business_rules.sql  -  PostgreSQL ports of the MySQL prototype's Points 4, 5, 6
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- POINT 4: block invalid appointment entries at write time
--   * no booking in the past
--   * doctor / patient cannot be double-booked in the same slot
-- (The partial UNIQUE indexes in 02_indexes.sql enforce double-booking as a hard
--  constraint as well; this trigger adds readable error messages and the "past" rule.)
-- -------------------------------------------------------------------------------------
CREATE FUNCTION hospital.trg_check_appointment() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- the ETL loads historical appointments, so it switches this check off for its own transaction
    IF current_setting('hospital.etl_mode', true) = 'on' THEN
        RETURN NEW;
    END IF;

    IF NEW.status = 'Cancelled' THEN
        RETURN NEW;
    END IF;

    IF NEW.status = 'Scheduled' AND NEW.appointment_time < now()
       AND (TG_OP = 'INSERT' OR NEW.appointment_time IS DISTINCT FROM OLD.appointment_time) THEN
        RAISE EXCEPTION 'Appointment cannot be in the past (%).', NEW.appointment_time
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM hospital.appointments a
               WHERE a.doctor_id = NEW.doctor_id
                 AND a.appointment_time = NEW.appointment_time
                 AND a.status <> 'Cancelled'
                 AND a.appointment_id <> NEW.appointment_id) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment at %.', NEW.doctor_id, NEW.appointment_time
            USING ERRCODE = 'unique_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM hospital.appointments a
               WHERE a.patient_id = NEW.patient_id
                 AND a.appointment_time = NEW.appointment_time
                 AND a.status <> 'Cancelled'
                 AND a.appointment_id <> NEW.appointment_id) THEN
        RAISE EXCEPTION 'Patient % already has an appointment at %.', NEW.patient_id, NEW.appointment_time
            USING ERRCODE = 'unique_violation';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER check_new_appointment
BEFORE INSERT OR UPDATE OF doctor_id, patient_id, appointment_time, status
ON hospital.appointments
FOR EACH ROW EXECUTE FUNCTION hospital.trg_check_appointment();


-- -------------------------------------------------------------------------------------
-- POINT 5: role-based patient access for doctors
--   Senior doctors see every patient of their department; others only their own patients.
--   Passwords are checked against the bcrypt hash (auth.doctor_credentials).
--   Usage: SELECT * FROM hospital.view_doctor_data('doctor4', 'ic0pFSn0');
-- -------------------------------------------------------------------------------------
CREATE FUNCTION hospital.view_doctor_data(p_username TEXT, p_password TEXT)
RETURNS TABLE (doctor_id INT, patient_id INT, patient_name VARCHAR, gender CHAR,
               appointment_time TIMESTAMP, medication VARCHAR, report_data JSONB)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = hospital, auth, public AS $$
#variable_conflict use_column
DECLARE
    v_doc  INT;
    v_role TEXT;
    v_dept INT;
BEGIN
    SELECT c.doctor_id INTO v_doc
    FROM auth.doctor_credentials c
    WHERE c.username = p_username AND c.password_hash = crypt(p_password, c.password_hash);

    IF v_doc IS NULL THEN
        RAISE EXCEPTION 'Invalid username or password' USING ERRCODE = 'invalid_password';
    END IF;

    SELECT d.role, d.department_id INTO v_role, v_dept FROM doctors d WHERE d.doctor_id = v_doc;

    RETURN QUERY
    SELECT a.doctor_id, p.patient_id, p.name, p.gender, a.appointment_time, pr.medication, lr.report_data
    FROM appointments a
    JOIN patients p          ON p.patient_id = a.patient_id
    JOIN doctors  d          ON d.doctor_id  = a.doctor_id
    LEFT JOIN prescriptions pr ON pr.appointment_id = a.appointment_id
    LEFT JOIN lab_reports   lr ON lr.appointment_id = a.appointment_id
    WHERE CASE WHEN v_role = 'Senior' THEN d.department_id = v_dept
               ELSE a.doctor_id = v_doc END
    ORDER BY a.appointment_time DESC;
END $$;


-- -------------------------------------------------------------------------------------
-- POINT 6: monthly revenue by department
--   Fix vs. MySQL prototype: the prototype joined departments ON department_id = doctor_id,
--   which attributes revenue to the wrong department; here it joins on department_id.
--   Uses a half-open date range (sargable) instead of MONTH()/YEAR() on the column.
--   Usage: SELECT * FROM hospital.monthly_revenue(2025, 5);
-- -------------------------------------------------------------------------------------
CREATE FUNCTION hospital.monthly_revenue(p_year INT, p_month INT)
RETURNS TABLE (department VARCHAR, bills BIGINT, total_revenue NUMERIC,
               collected NUMERIC, outstanding NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT dp.name,
           count(*),
           sum(b.amount),
           sum(b.amount) FILTER (WHERE b.paid),
           sum(b.amount) FILTER (WHERE NOT b.paid)
    FROM hospital.bills b
    JOIN hospital.appointments a ON a.appointment_id = b.appointment_id
    JOIN hospital.doctors      d ON d.doctor_id      = a.doctor_id
    JOIN hospital.departments dp ON dp.department_id = d.department_id
    WHERE b.bill_date >= make_date(p_year, p_month, 1)
      AND b.bill_date <  make_date(p_year, p_month, 1) + INTERVAL '1 month'
    GROUP BY dp.name
    ORDER BY sum(b.amount) DESC;
$$;
