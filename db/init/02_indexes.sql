-- =====================================================================================
-- 02_indexes.sql  -  Strategic indexing
-- -------------------------------------------------------------------------------------
-- PostgreSQL creates indexes for PRIMARY KEY / UNIQUE automatically, but NOT for foreign
-- keys. Every index below is tied to a concrete access path used by the front desk,
-- doctors, billing or the analytics views. Measured impact: benchmarks/benchmark.sql
-- =====================================================================================

-- Appointments: the hub table, hit by almost every query --------------------------------
-- patient history ("show me everything for patient X", newest first)
CREATE INDEX ix_appt_patient_time  ON hospital.appointments (patient_id, appointment_time DESC);
-- doctor schedule ("Dr X's appointments today / this month")
CREATE INDEX ix_appt_doctor_time   ON hospital.appointments (doctor_id, appointment_time);
-- date-range reporting (daily lists, monthly revenue)
CREATE INDEX ix_appt_time          ON hospital.appointments (appointment_time);

-- Business-rule indexes: a doctor / a patient cannot hold two live bookings in the same
-- slot. Partial UNIQUE indexes ignore cancelled rows, so a cancelled slot can be re-booked.
CREATE UNIQUE INDEX uq_doctor_slot  ON hospital.appointments (doctor_id, appointment_time)
    WHERE status <> 'Cancelled';
CREATE UNIQUE INDEX uq_patient_slot ON hospital.appointments (patient_id, appointment_time)
    WHERE status <> 'Cancelled';

-- Child tables: FK lookups (appointment -> its prescriptions / bills / lab reports) -------
-- prescriptions(appointment_id) is already covered by uq_prescription_per_visit
CREATE INDEX ix_bills_appointment  ON hospital.bills (appointment_id);
CREATE INDEX ix_lab_appointment    ON hospital.lab_reports (appointment_id);

-- Outstanding bills worklist: tiny partial index, only unpaid rows are stored
CREATE INDEX ix_bills_unpaid       ON hospital.bills (bill_date) WHERE NOT paid;

-- Lab results search inside JSON (e.g. report_data @> '{"Hemoglobin":"13.3"}')
-- fastupdate=off: rows go straight into the index during the bulk ETL load instead of a
-- pending list, so the index is fully effective the moment the migration finishes.
CREATE INDEX ix_lab_report_data    ON hospital.lab_reports USING GIN (report_data jsonb_path_ops)
    WITH (fastupdate = off);

-- Reference lookups ----------------------------------------------------------------------
CREATE INDEX ix_doctors_department ON hospital.doctors (department_id);
CREATE INDEX ix_patients_phone     ON hospital.patients (phone);         -- front-desk search
CREATE INDEX ix_wards_department   ON hospital.wards (department_id);

-- Inpatient module: occupancy & census -------------------------------------------------------
CREATE INDEX ix_adm_ward_period    ON hospital.admissions (ward_id, admitted_at, discharged_at);
CREATE INDEX ix_adm_current        ON hospital.admissions (ward_id) WHERE discharged_at IS NULL;
