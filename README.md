# Hospital Database Migration & Automation Project

This repository contains a complete solution for building and migrating a robust, relational database for a hospital. The project addresses the challenge of moving from an inefficient, error-prone Excel-based system to a scalable, high-integrity PostgreSQL database.

The project demonstrates a real-world **ETL (Extract, Transform, Load)** workflow using SQL scripts to automate the data migration process.

---

## 📊 Database Schema (ERD)

The final database is normalized into six interconnected tables, ensuring data integrity and minimizing redundancy. The schema is designed to manage core hospital functionalities, including departments, doctors, patients, appointments, prescriptions, billing, and lab reports.

![Hospital Database ERD](./Database%20design.png)

For the complete table structure and relationships, see the `schema.sql` file.

---

## 🛠️ Tech Stack

- **Database**: PostgreSQL
- **Containerization**: Docker
- **Scripting**: SQL

---

## 📁 Project Structure

- `schema.sql`: Defines the final normalized database structure.
- `migrate_data.sql`: The ETL script that handles data staging, transformation, and migration.
- `hospital_data.csv`: The source dataset used for migration.
- `doctor_credentials.csv`: Sample doctor credentials data.
- `Database design.png`: Visual representation of the database schema.

---

## ⚙️ Setup and Usage

Follow these steps to set up the database and run the automated data migration.

### 1. Prerequisites

- You must have **Docker** installed and running on your system.

### 2. Running the Database

**Create and Run the PostgreSQL Container:**
Open your terminal in the project root directory and run the following command. This creates a PostgreSQL container and maps the current project directory to `/data` inside the container.

**Important**: Replace `your_strong_password_here` with a secure password.

```bash
docker run --name hospital-db -e POSTGRES_PASSWORD=your_strong_password_here -d -p 5432:5432 -v "$(pwd):/data" postgres
```

**Connect to the Container:**
```bash
docker exec -it hospital-db bash
```

**Connect to PostgreSQL:**
```bash
psql -U postgres
```

**Create and Connect to the Database:**
```sql
CREATE DATABASE "HospitalDB";
\c "HospitalDB"
```

### 3. Running the Migration

The migration process happens in two steps: creating the schema and then migrating the data.

**Step 1: Create the Schema**
Execute the schema script to create the necessary tables.
```sql
\i /data/schema.sql
```

**Step 2: Run the Automated Migration**
Execute the migration script. This script will create a staging table, load the raw CSV data, transform it, and populate the final normalized tables.
```sql
\i /data/migrate_data.sql
```

### 4. Verification

After the script finishes, you can verify the migration by running a few simple queries:

```sql
-- Check if doctors were migrated
SELECT * FROM doctors LIMIT 5;

-- Check appointments
SELECT * FROM appointments WHERE status = 'Completed' LIMIT 5;

-- Check billing data
SELECT * FROM bills LIMIT 5;
```
