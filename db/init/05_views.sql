-- =====================================================================================
-- 05_views.sql  -  Analytics layer (schema "analytics")
-- -------------------------------------------------------------------------------------
--  v_appointment_details        5-table join: visit + patient + doctor + department + bill totals
--  v_admission_episodes         every inpatient stay, with LAG/LEAD window functions that link
--                               it to the same patient's previous / next stay
--  v_readmission_by_ward        30-day readmission rate per ward (attributed to discharging ward)
--  v_readmission_by_department  same, rolled up per department
--  v_ward_daily_occupancy       midnight census: beds occupied per ward per day
--  v_ward_occupancy_summary     average / peak occupancy, pressure days, ALOS for all 15 wards
--  v_ward_monthly_occupancy     monthly occupancy trend per ward
--  v_ward_current_census        who is in a bed right now (as of the reporting date)
-- =====================================================================================

-- Reporting date = day after the latest event in the migrated data (the legacy extract is
-- historical, so now() would make every "current" metric empty).
CREATE FUNCTION analytics.reporting_date() RETURNS DATE
LANGUAGE sql STABLE AS $$
    SELECT (GREATEST(
              (SELECT max(appointment_time) FROM hospital.appointments),
              (SELECT max(admitted_at)      FROM hospital.admissions),
              (SELECT max(discharged_at)    FROM hospital.admissions)))::DATE + 1
$$;


CREATE VIEW analytics.v_appointment_details AS
SELECT a.appointment_id,
       a.appointment_time,
       a.status,
       p.patient_id,
       p.name                                             AS patient_name,
       p.gender,
       date_part('year', age(a.appointment_time, p.date_of_birth))::INT AS patient_age,
       d.doctor_id,
       d.name                                             AS doctor_name,
       d.specialization,
       d.role                                             AS doctor_role,
       dp.department_id,
       dp.name                                            AS department,
       COALESCE(b.billed, 0)                              AS billed_amount,
       COALESCE(b.outstanding, 0)                         AS outstanding_amount
FROM hospital.appointments a
JOIN hospital.patients    p  ON p.patient_id     = a.patient_id
JOIN hospital.doctors     d  ON d.doctor_id      = a.doctor_id
JOIN hospital.departments dp ON dp.department_id = d.department_id
LEFT JOIN LATERAL (
        SELECT sum(amount) AS billed, sum(amount) FILTER (WHERE NOT paid) AS outstanding
        FROM hospital.bills bl WHERE bl.appointment_id = a.appointment_id) b ON TRUE;


CREATE VIEW analytics.v_admission_episodes AS
WITH stays AS (
    SELECT m.admission_id,
           a.patient_id,
           m.ward_id,
           m.admitted_at,
           m.discharged_at,
           ROW_NUMBER()          OVER w AS stay_number,
           LAG(m.discharged_at)  OVER w AS previous_discharge,
           LEAD(m.admitted_at)   OVER w AS next_admission
    FROM hospital.admissions m
    JOIN hospital.appointments a ON a.appointment_id = m.appointment_id
    WINDOW w AS (PARTITION BY a.patient_id ORDER BY m.admitted_at)
)
SELECT s.admission_id,
       s.patient_id,
       p.name                                         AS patient_name,
       s.ward_id,
       w.ward_name,
       w.ward_type,
       dp.department_id,
       dp.name                                        AS department,
       s.admitted_at,
       s.discharged_at,
       round((extract(epoch FROM COALESCE(s.discharged_at, analytics.reporting_date()::TIMESTAMP)
                                  - s.admitted_at) / 86400)::NUMERIC, 1) AS length_of_stay_days,
       s.stay_number,
       s.previous_discharge,
       -- this stay IS a readmission: began within 30 days of the previous discharge
       COALESCE(s.admitted_at - s.previous_discharge <= INTERVAL '30 days', FALSE)  AS is_readmission_30d,
       -- this discharge was FOLLOWED by a readmission within 30 days (standard index-stay metric)
       COALESCE(s.next_admission - s.discharged_at  <= INTERVAL '30 days', FALSE)  AS readmitted_within_30d,
       -- discharge is "eligible" only if a full 30-day follow-up window exists in the data
       (s.discharged_at IS NOT NULL
        AND s.discharged_at + INTERVAL '30 days' <= analytics.reporting_date())   AS eligible_index_stay
FROM stays s
JOIN hospital.patients    p  ON p.patient_id     = s.patient_id
JOIN hospital.wards       w  ON w.ward_id        = s.ward_id
JOIN hospital.departments dp ON dp.department_id = w.department_id;


CREATE VIEW analytics.v_readmission_by_ward AS
SELECT ward_id,
       ward_name,
       department,
       count(*)                                                            AS admissions,
       count(*) FILTER (WHERE eligible_index_stay)                         AS index_discharges,
       count(*) FILTER (WHERE eligible_index_stay AND readmitted_within_30d) AS readmissions_30d,
       round(100.0 * count(*) FILTER (WHERE eligible_index_stay AND readmitted_within_30d)
             / NULLIF(count(*) FILTER (WHERE eligible_index_stay), 0), 1)  AS readmission_rate_pct,
       round(avg(length_of_stay_days) FILTER (WHERE discharged_at IS NOT NULL), 1) AS avg_length_of_stay_days
FROM analytics.v_admission_episodes
GROUP BY ward_id, ward_name, department;


CREATE VIEW analytics.v_readmission_by_department AS
SELECT department_id,
       department,
       count(*)                                                            AS admissions,
       count(*) FILTER (WHERE eligible_index_stay)                         AS index_discharges,
       count(*) FILTER (WHERE eligible_index_stay AND readmitted_within_30d) AS readmissions_30d,
       round(100.0 * count(*) FILTER (WHERE eligible_index_stay AND readmitted_within_30d)
             / NULLIF(count(*) FILTER (WHERE eligible_index_stay), 0), 1)  AS readmission_rate_pct
FROM analytics.v_admission_episodes
GROUP BY department_id, department;


-- Midnight census: a patient occupies a bed on day D if they were admitted before the end
-- of D and not yet discharged at the end of D.
CREATE VIEW analytics.v_ward_daily_occupancy AS
WITH days AS (
    SELECT generate_series((SELECT min(admitted_at)::DATE FROM hospital.admissions),
                           analytics.reporting_date() - 1, INTERVAL '1 day')::DATE AS census_date
)
SELECT w.ward_id,
       w.ward_name,
       w.ward_type,
       w.department_id,
       d.census_date,
       w.bed_capacity,
       count(m.admission_id)                                    AS occupied_beds,
       round(100.0 * count(m.admission_id) / w.bed_capacity, 1) AS occupancy_pct
FROM hospital.wards w
CROSS JOIN days d
LEFT JOIN hospital.admissions m
       ON m.ward_id = w.ward_id
      AND m.admitted_at <  d.census_date + 1
      AND (m.discharged_at IS NULL OR m.discharged_at >= d.census_date + 1)
GROUP BY w.ward_id, w.ward_name, w.ward_type, w.department_id, d.census_date, w.bed_capacity;


CREATE VIEW analytics.v_ward_occupancy_summary AS
SELECT o.ward_id,
       o.ward_name,
       o.ward_type,
       dp.name                                              AS department,
       o.bed_capacity,
       round(avg(o.occupancy_pct), 1)                       AS avg_occupancy_pct,
       max(o.occupied_beds)                                 AS peak_occupied_beds,
       round(100.0 * max(o.occupied_beds) / o.bed_capacity, 1) AS peak_occupancy_pct,
       count(*) FILTER (WHERE o.occupancy_pct >= 85)        AS days_at_or_above_85pct,
       sum(o.occupied_beds)                                 AS bed_days_used,
       RANK() OVER (ORDER BY avg(o.occupancy_pct) DESC)     AS busiest_rank
FROM analytics.v_ward_daily_occupancy o
JOIN hospital.departments dp ON dp.department_id = o.department_id
GROUP BY o.ward_id, o.ward_name, o.ward_type, dp.name, o.bed_capacity;


CREATE VIEW analytics.v_ward_monthly_occupancy AS
SELECT ward_id,
       ward_name,
       date_trunc('month', census_date)::DATE  AS month,
       bed_capacity,
       round(avg(occupied_beds), 1)            AS avg_occupied_beds,
       round(avg(occupancy_pct), 1)            AS avg_occupancy_pct,
       max(occupied_beds)                      AS peak_occupied_beds
FROM analytics.v_ward_daily_occupancy
GROUP BY ward_id, ward_name, date_trunc('month', census_date), bed_capacity;


CREATE VIEW analytics.v_ward_current_census AS
SELECT w.ward_id,
       w.ward_name,
       w.bed_capacity,
       m.admission_id,
       p.patient_id,
       p.name                                                    AS patient_name,
       m.admitted_at,
       analytics.reporting_date() - m.admitted_at::DATE          AS days_in_bed
FROM hospital.admissions m
JOIN hospital.wards        w ON w.ward_id        = m.ward_id
JOIN hospital.appointments a ON a.appointment_id = m.appointment_id
JOIN hospital.patients     p ON p.patient_id     = a.patient_id
WHERE m.discharged_at IS NULL;
