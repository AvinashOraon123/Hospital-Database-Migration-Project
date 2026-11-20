"""
Generate the ward & inpatient-admission source extracts (data/wards.csv, data/admissions.csv).

Why this exists
---------------
The legacy hospital extract (hospital_data_10000_rows.csv) covers outpatient activity only:
departments, doctors, patients, appointments, prescriptions, bills and lab reports.
It has no bed/ward data, so occupancy and readmission analysis is impossible from it alone.
This script produces a *synthetic but internally consistent* inpatient extract that is
anchored to the real appointment records, so the ETL can migrate it like any other source.

Rules (all deterministic - fixed seed, same output every run)
-------------------------------------------------------------
* 15 wards spread over the 10 departments (5 departments run a second ward, e.g. an HDU).
* Only *Completed* appointments can lead to an admission (you can't admit off a cancelled visit).
* Appointments whose doctor or patient is double-booked in the source are skipped, because the ETL will
  reject/cancel those bookings.
* The patient is admitted to a ward of the treating doctor's department.
* A bed must be free: a ward never exceeds its bed_capacity at any instant
  (if the department's wards are all full the admission is not created).
* A patient can't be in two beds at once (no overlapping stays for the same patient).
* Length of stay: 1-14 days (HDU/ICU stays are shorter); stays that would run past the extract
  date are left open (dischargedat empty) = patients currently in a bed.

Usage:  python data_generation/generate_ward_data.py
Standard library only.
"""
import csv
import random
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "hospital_data_10000_rows.csv"
OUT_DIR = ROOT / "data"

SEED = 42
ADMISSION_RATE = 0.30                         # share of completed visits that become admissions
EXTRACT_DATE = datetime(2025, 6, 25, 0, 0)    # legacy extract was taken just after the last record

# ward_id, ward_name, department_id, ward_type, bed_capacity
WARDS = [
    (1,  "Ward 1A - General",  1, "General", 20),
    (2,  "Ward 1B - HDU",      1, "HDU",      8),
    (3,  "Ward 2A - General",  2, "General", 18),
    (4,  "Ward 3A - General",  3, "General", 16),
    (5,  "Ward 3B - HDU",      3, "HDU",      6),
    (6,  "Ward 4A - General",  4, "General", 18),
    (7,  "Ward 5A - General",  5, "General", 14),
    (8,  "Ward 6A - General",  6, "General", 20),
    (9,  "Ward 6B - HDU",      6, "HDU",      8),
    (10, "Ward 7A - General",  7, "General", 14),
    (11, "Ward 8A - General",  8, "General", 16),
    (12, "Ward 8B - HDU",      8, "HDU",      6),
    (13, "Ward 9A - General",  9, "General", 14),
    (14, "Ward 10A - General", 10, "General", 18),
    (15, "Ward 10B - HDU",     10, "HDU",      8),
]


def overlaps(a_start, a_end, b_start, b_end):
    a_end = a_end or datetime.max
    b_end = b_end or datetime.max
    return a_start < b_end and b_start < a_end


def main():
    rng = random.Random(SEED)
    rows = list(csv.DictReader(SOURCE.open(encoding="utf-8")))

    doctor_dept = {r["Doctors.DoctorID"]: int(r["Doctors.DepartmentID"])
                   for r in rows if r["Doctors.DoctorID"]}
    appts = [r for r in rows if r["Appointments.AppointmentID"]]
    doctor_slots = Counter((a["Appointments.DoctorID"], a["Appointments.AppointmentTime"]) for a in appts)
    patient_slots = Counter((a["Appointments.PatientID"], a["Appointments.AppointmentTime"]) for a in appts)

    candidates = []
    for a in appts:
        if a["Appointments.Status"] != "Completed":
            continue
        if (doctor_slots[(a["Appointments.DoctorID"], a["Appointments.AppointmentTime"])] > 1
                or patient_slots[(a["Appointments.PatientID"], a["Appointments.AppointmentTime"])] > 1):
            continue
        candidates.append((
            datetime.strptime(a["Appointments.AppointmentTime"], "%d-%m-%Y %H:%M"),
            int(a["Appointments.AppointmentID"]),
            a["Appointments.PatientID"],
            doctor_dept[a["Appointments.DoctorID"]],
        ))
    candidates.sort()  # process chronologically so bed checks are realistic

    wards_by_dept = defaultdict(list)
    for w in WARDS:
        wards_by_dept[w[2]].append(w)

    ward_stays = defaultdict(list)     # ward_id -> [(start, end)]
    patient_stays = defaultdict(list)  # patient_id -> [(start, end)]
    admissions = []

    for appt_time, appt_id, patient_id, dept in candidates:
        if rng.random() >= ADMISSION_RATE:
            continue
        admitted = appt_time + timedelta(minutes=rng.randint(30, 240))
        if admitted >= EXTRACT_DATE:
            continue
        if any(overlaps(admitted, None, s, e) for s, e in patient_stays[patient_id]
               if e is None or e > admitted):
            continue  # patient still in a bed

        # HDU is used for ~25% of admissions in departments that have one
        prefer_hdu = rng.random() < 0.25
        options = sorted(wards_by_dept[dept], key=lambda w: (w[3] == "HDU") != prefer_hdu)

        for ward_id, _, _, ward_type, capacity in options:
            los_days = rng.randint(1, 5) if ward_type == "HDU" else rng.choice(
                [1, 1, 2, 2, 3, 3, 4, 5, 6, 7, 9, 12, 14])
            discharged = admitted + timedelta(days=los_days, hours=rng.randint(0, 20))
            if discharged > EXTRACT_DATE:
                discharged = None  # still admitted at extract time
            busy = sum(1 for s, e in ward_stays[ward_id] if overlaps(admitted, discharged, s, e))
            if busy >= capacity:
                continue
            ward_stays[ward_id].append((admitted, discharged))
            patient_stays[patient_id].append((admitted, discharged))
            admissions.append((appt_id, ward_id, admitted, discharged))
            break

    OUT_DIR.mkdir(exist_ok=True)
    with (OUT_DIR / "wards.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["WardID", "WardName", "DepartmentID", "WardType", "BedCapacity"])
        w.writerows(WARDS)

    fmt = "%Y-%m-%d %H:%M:%S"
    with (OUT_DIR / "admissions.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["AdmissionID", "AppointmentID", "WardID", "AdmittedAt", "DischargedAt"])
        for i, (appt_id, ward_id, adm, dis) in enumerate(admissions, start=1):
            w.writerow([i, appt_id, ward_id, adm.strftime(fmt), dis.strftime(fmt) if dis else ""])

    open_stays = sum(1 for a in admissions if a[3] is None)
    print(f"wards: {len(WARDS)}  admissions: {len(admissions)}  currently admitted: {open_stays}")


if __name__ == "__main__":
    main()
