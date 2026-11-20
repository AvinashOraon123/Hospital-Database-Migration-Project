-- CREATE Database
CREATE DATABASE EHIAS;
USE EHIAS;

-- CREATING DEPARTMENT TABLE
CREATE TABLE departments
(
departmentID int auto_increment primary key, 
name varchar(50) not null
);
-- CREATE TABLE DOCTORS
CREATE TABLE doctors
(
doctorid int auto_increment primary key,
name varchar(50),
specialization varchar(100),
role varchar(50),
departmentid int,
foreign key (departmentid) references departments(departmentid)
);

-- CREATE PATIENTS
CREATE TABLE PATIENTS
(
Patientid int auto_increment primary key,
name varchar(50),
DateofBirth date,
Gender varchar(1),
Phone varchar(15),
check (gender in('m', 'f', 'o'))
);

-- CREATE APPOINTMENT
CREATE TABLE APPOINTMENTS
(
appointmentid int auto_increment primary key,
patientid int,
doctorid int,
appointmenttime datetime,
status varchar(50),
foreign key (patientid) references patients(patientid),
foreign key (doctorid) references doctors(doctorid),
check (status in('Scheduled' , 'Completed', 'Cancelled'))
);

-- CREATE PRESCRIPTION TABLE
CREATE TABLE PRESCRIPTIONS
(
prescriptionid int auto_increment primary key,
appointmentid int,
medication varchar(100),
dosage varchar(100),
foreign key (appointmentid) references appointments(appointmentid)
);

-- CREATE BILLS TABLE
CREATE TABLE BILLS
(
billid int auto_increment primary key,
appointmentid int,
amount decimal(10,2),
paid tinyint(1),
billdate datetime default current_timestamp,
foreign key (appointmentid) references appointments(appointmentid)
);
-- CREATE LABREPORT TABLES

CREATE TABLE LABREPORTS
(
REPORTID int auto_increment primary key,
appointmentid int,
REPORTDATA TEXT,
CREATEDAT DATETIME DEFAULT CURRENT_TIMESTAMP,
foreign key (appointmentid) references appointments(appointmentid)
);

-- INSERTION OF DATABASE
SELECT * FROM HOSPITAL_DATA_10000_ROWS;

SELECT `Departments.DepartmentID` FROM HOSPITAL_DATA_10000_ROWS;

SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'Departments.%';

insert into departments(departmentID, name)
select`Departments.DepartmentID`,`Departments.Name`from hospital_data_10000_rows
where `Departments.DepartmentID` <> '';

select * from departments;

-- inserting values into doctors table
SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'Doctors.%';

insert into doctors(DoctorID, Name, Specialization, Role, DepartmentID)
select`Doctors.DoctorID`,`Doctors.Name`,`Doctors.Specialization`,`Doctors.Role`,`Doctors.DepartmentID`from hospital_data_10000_rows
WHERE `Doctors.DoctorID` <> '';

select * from doctors;

-- PATIENT TABLE
SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'Patients.%';

insert into patients(PatientID, Name, DateOfBirth, Gender, Phone)
select`Patients.PatientID`,`Patients.Name`,str_to_date(`Patients.DateOfBirth`, '%d-%m-%Y'),`Patients.Gender`,`Patients.Phone`from hospital_data_10000_rows
where `Patients.PatientID` <> '';

select * from patients;


SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'appointments.%';

insert into appointments(AppointmentID, PatientID, DoctorID, AppointmentTime, Status)
select`Appointments.AppointmentID`,`Appointments.PatientID`,`Appointments.DoctorID`,
str_to_date(`Appointments.AppointmentTime`, '%d-%m-%Y %H:%i')
,`Appointments.Status`from hospital_data_10000_rows
where `Appointments.AppointmentID` <> '';

select * from appointments;

SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'prescriptions.%';

insert into prescriptions(PrescriptionID, AppointmentID, Medication, Dosage)
select`Prescriptions.PrescriptionID`,`Prescriptions.AppointmentID`,`Prescriptions.Medication`,`Prescriptions.Dosage`from hospital_data_10000_rows
where `Prescriptions.PrescriptionID` <> '';

select * from prescriptions;

SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'bills.%';

insert into bills(BillID, AppointmentID, Amount, Paid, BillDate)
select`Bills.BillID`,`Bills.AppointmentID`,`Bills.Amount`,`Bills.Paid`,
`Bills.BillDate`from hospital_data_10000_rows
where `Bills.BillID` <> '';

select * from bills;

SELECT concat('select',group_concat(concat('`' , COLUMN_NAME , '`')), 'from hospital_data_10000_rows') FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'EHIAS'
AND TABLE_NAME = 'HOSpiTAL_DATA_10000_rows'
and COLUMN_NAME LIKE 'labreports.%';

insert into labreports(ReportID, AppointmentID, ReportData, CreatedAt)
select`LabReports.ReportID`,`LabReports.AppointmentID`,`LabReports.ReportData`,`LabReports.CreatedAt`from hospital_data_10000_rows
where `LabReports.ReportID` <> '';

select * from labreports;

-- POINT 4
-- Doctors are occassionally double-booked and appointments are scheduled in the past
-- We have to design and implement measures to automatically prevent invalid appointment entries during insertion 
drop trigger CHECK_NEW_APPOINTMENT
DELIMITER $$
CREATE TRIGGER CHECK_NEW_APPOINTMENT
BEFORE INSERT ON APPOINTMENTS
FOR EACH ROW
BEGIN
	IF NEW.APPOINTMENTTIME < NOW() THEN 
		SIGNAL SQLSTATE '45000'
		SET MESSAGE_TEXT = 'Error: Appointment cannot be in the past';
	END IF ;
    
    IF EXISTs
    (
		SELECT * FROM APPOINTMENTS
        WHERE DOCTORID = NEW.DOCTORID AND 
        APPOINTMENTTIME = NEW.APPOINTMENTTIME
        AND STATUS IN ('SCHEDULED')
	) THEN
	SIGNAL SQLSTATE '45000'
	SET MESSAGE_TEXT = 'Error: Doctor already has an appointment at this time'	;
	END IF;
END$$
DELIMITER ;

insert into appointments( appointmentid, patientid, doctorid, appointmenttime, status)
VALUES(10000,1,1, '2026-11-25 10:00:00', 'Scheduled');
insert into appointments( appointmentid, patientid, doctorid, appointmenttime, status)
VALUES(10002,1,1, '2026-06-25 10:00:00', 'Scheduled');

-- POINT 5
DELIMITER $$
CREATE PROCEDURE VIEW_DOCTOR_DATA(IN INPUT_USERNAME VARCHAR(100), IN INPUT_PASSWORD VARCHAR(100))
BEGIN
	DECLARE DOC_ROLE VARCHAR(100);
    DECLARE DOC_DEPT INT;
    DECLARE DOC_ID INT;
    
    -- CHECK CREDENTIALS OF THE DOCTOR
    SELECT DOCTOR_ID INTO DOC_ID
    FROM DOCTOR_CREDENTIALS
    WHERE USER_NAME = INPUT_USERNAME AND PASSWORD = INPUT_PASSWORD;
	
    -- GET ROLE AND DEPARTMENT FROM DOCTORS TABLE
    SELECT ROLE, DEPARTMENTID 
    INTO DOC_ROLE, DOC_DEPT
    FROM DOCTORS WHERE DOCTORID = DOC_ID;
    
    -- SHOW APPROPRIATE PATIENTS DATA.
    IF DOC_ROLE = 'senior' THEN
		SELECT D.DOCTORID, P.PATIENTID, P.Name, P.Gender, A.Appointmenttime, PR.Medication, LR.REPORTDATA
		FROM PATIENTS AS P INNER JOIN 
		APPOINTMENTS AS A ON A.PATIENTID = P.PATIENTID
        JOIN DOCTORS AS D ON D.DOCTORID = A.DOCTORID
		LEFT JOIN PRESCRIPTIONS AS PR ON A.APPOINTMENTID = PR.APPOINTMENTID
		LEFT JOIN LABREPORTS AS LR ON A.APPOINTMENTID = LR.APPOINTMENTID
		WHERE D.DEPARTMENTID = DOC_DEPT;
	ELSE
		SELECT A.DOCTORID,P.PATIENTID, P.Name, P.Gender, A.Appointmenttime, PR.Medication, LR.REPORTDATA
		FROM PATIENTS AS P INNER JOIN 
		APPOINTMENTS AS A ON A.PATIENTID = P.PATIENTID
	
		LEFT JOIN PRESCRIPTIONS AS PR ON A.APPOINTMENTID = PR.APPOINTMENTID
		LEFT JOIN LABREPORTS AS LR ON A.APPOINTMENTID = LR.APPOINTMENTID
		WHERE A.DOCTORID = DOC_ID;
	END IF;
END$$
DELIMITER ;


CALL VIEW_DOCTOR_DATA('doctor1', 'W3jzIANG');
CALL VIEW_DOCTOR_DATA('doctor4','ic0pFSn0');

-- POINT 6

DELIMITER $$
CREATE PROCEDURE SP_MONTHLY_REVENUE( IN P_YEAR INT, IN P_MONTH INT)
BEGIN
SELECT D1.NAME AS DEPARTMENT,
SUM(B.AMOUNT) AS TOTAL_REVENUE
FROM BILLS AS B
INNER JOIN APPOINTMENTS AS A ON A.APPOINTMENTID = B.APPOINTMENTID
INNER JOIN DOCTORS AS D ON A.DOCTORID = D.DOCTORID
INNER JOIN DEPARTMENTS AS D1 ON D1.DEPARTMENTID = D.DOCTORID
WHERE MONTH(B.BILLDATE) = P_MONTH AND YEAR(B.BILLDATE) = P_YEAR
GROUP BY D1.NAME;

END$$
DELIMITER ;

CALL SP_MONTHLY_REVENUE(2025, 5);














