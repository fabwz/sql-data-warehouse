/*
===============================================================================
DDL: Bronze layer tables
===============================================================================
Purpose:
    Creates the six raw tables of the bronze schema (3 CRM, 3 ERP). Each table
    mirrors one source CSV: same columns, same names (lower case), no technical
    columns. Bronze is a faithful copy; no cleaning happens here.

Usage (run after 03_scripts/init_database.sql):
    docker compose exec -T postgres psql -U postgres -d data_warehouse < 03_scripts/bronze/ddl_bronze.sql

Warnings:
    - DROP TABLE IF EXISTS: re-running this script DELETES all data in the
      bronze tables. Reload them afterwards with CALL bronze.load_bronze();
    - Idempotent: safe to run more than once.
    - Column types were validated against EVERY row of the CSV files, not just
      the first ones. All values fit the types below (no decimals, no invalid
      dates, no integer overflow), so no column needed a looser type.
    - Text columns are unbounded varchar so that no value is ever truncated or
      rejected; the length checks belong to Silver.
    - Date-like values of the sales table (sls_order_dt, sls_ship_dt, sls_due_dt)
      come as integers such as 20101229, and sls_order_dt contains 0 as a dirty
      value. They stay integer here; Silver converts them to dates.
    - Empty CSV fields are loaded as NULL (see proc_load_bronze.sql).
===============================================================================
*/

-- ---------------------------------------------------------------------------
-- CRM
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS bronze.crm_cust_info;
CREATE TABLE bronze.crm_cust_info (
    cst_id              integer,
    cst_key             varchar,
    cst_firstname       varchar,    -- may contain leading/trailing spaces
    cst_lastname        varchar,    -- may contain leading/trailing spaces
    cst_marital_status  varchar,
    cst_gndr            varchar,
    cst_create_date     date
);

DROP TABLE IF EXISTS bronze.crm_prd_info;
CREATE TABLE bronze.crm_prd_info (
    prd_id          integer,
    prd_key         varchar,
    prd_nm          varchar,
    prd_cost        integer,        -- source has whole numbers only (1..2171)
    prd_line        varchar,        -- padded with a trailing space in the source
    prd_start_dt    date,
    prd_end_dt      date
);

DROP TABLE IF EXISTS bronze.crm_sales_details;
CREATE TABLE bronze.crm_sales_details (
    sls_ord_num     varchar,
    sls_prd_key     varchar,
    sls_cust_id     integer,
    sls_order_dt    integer,        -- yyyymmdd as integer; contains 0 values
    sls_ship_dt     integer,        -- yyyymmdd as integer
    sls_due_dt      integer,        -- yyyymmdd as integer
    sls_sales       integer,        -- source has whole numbers, some negative
    sls_quantity    integer,
    sls_price       integer         -- source has whole numbers, some negative
);

-- ---------------------------------------------------------------------------
-- ERP
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS bronze.erp_cust_az12;
CREATE TABLE bronze.erp_cust_az12 (
    cid     varchar,
    bdate   date,
    gen     varchar
);

DROP TABLE IF EXISTS bronze.erp_loc_a101;
CREATE TABLE bronze.erp_loc_a101 (
    cid     varchar,
    cntry   varchar
);

DROP TABLE IF EXISTS bronze.erp_px_cat_g1v2;
CREATE TABLE bronze.erp_px_cat_g1v2 (
    id          varchar,
    cat         varchar,
    subcat      varchar,
    maintenance varchar
);
