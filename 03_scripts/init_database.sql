/*
===============================================================================
Init database
===============================================================================
Purpose:
    Creates the data_warehouse database and the bronze, silver and gold schemas.

Usage (psql, connected to any existing database, e.g. postgres):
    psql -U postgres -f 03_scripts/init_database.sql

Warnings:
    - Idempotent: safe to run more than once. It never drops or truncates
      anything; existing databases, schemas and data are left untouched.
    - CREATE DATABASE has no IF NOT EXISTS, so it is run through \gexec only
      when the database is missing.
    - Requires psql (uses \gexec and \connect), and a role with CREATEDB.
===============================================================================
*/

-- Create the database only if it does not exist yet
SELECT 'CREATE DATABASE data_warehouse'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'data_warehouse')
\gexec

\connect data_warehouse

CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
