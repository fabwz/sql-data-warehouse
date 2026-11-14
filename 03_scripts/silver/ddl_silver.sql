/*
===============================================================================
DDL: Silver layer tables
===============================================================================
Purpose:
    Creates the six cleaned tables of the silver schema. Each table matches one
    bronze table (same name) and keeps the original column names. Differences
    with bronze:
      - proper data types (dates as date, prices as numeric);
      - crm_prd_info gets one extra column, cat_id (derived from prd_key);
      - every table gets the technical column dwh_load_date (default now()).

Usage (run after bronze/ddl_bronze.sql):
    docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/silver/ddl_silver.sql

Warnings:
    - DROP TABLE IF EXISTS: re-running this script DELETES all data in the
      silver tables. Reload them afterwards with CALL silver.load_silver();
    - Idempotent: safe to run more than once.
    - sls_sales and sls_price are numeric(12,2) (not integer as in bronze)
      because a missing price is derived as sls_sales / sls_quantity, which can
      give decimals (e.g. 35 / 2 = 17.50).
===============================================================================
*/

-- ---------------------------------------------------------------------------
-- CRM
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS silver.crm_cust_info;
CREATE TABLE silver.crm_cust_info (
    cst_id              integer,
    cst_key             varchar,
    cst_firstname       varchar,
    cst_lastname        varchar,
    cst_marital_status  varchar,        -- Married / Single / n/a
    cst_gndr            varchar,        -- Male / Female / n/a
    cst_create_date     date,
    dwh_load_date       timestamptz DEFAULT now()
);

DROP TABLE IF EXISTS silver.crm_prd_info;
CREATE TABLE silver.crm_prd_info (
    prd_id          integer,
    cat_id          varchar,            -- derived: category id, matches erp_px_cat_g1v2.id
    prd_key         varchar,            -- without the category prefix, matches sls_prd_key
    prd_nm          varchar,
    prd_cost        integer,            -- NULL when unknown
    prd_line        varchar,            -- Road / Mountain / Other Sales / Touring / n/a
    prd_start_dt    date,
    prd_end_dt      date,               -- NULL = current version
    dwh_load_date   timestamptz DEFAULT now()
);

DROP TABLE IF EXISTS silver.crm_sales_details;
CREATE TABLE silver.crm_sales_details (
    sls_ord_num     varchar,
    sls_prd_key     varchar,
    sls_cust_id     integer,
    sls_order_dt    date,
    sls_ship_dt     date,
    sls_due_dt      date,
    sls_sales       numeric(12,2),      -- always sls_quantity * sls_price
    sls_quantity    integer,
    sls_price       numeric(12,2),      -- unit price, always positive
    dwh_load_date   timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- ERP
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS silver.erp_cust_az12;
CREATE TABLE silver.erp_cust_az12 (
    cid             varchar,            -- same format as crm_cust_info.cst_key
    bdate           date,               -- NULL when the source date is in the future
    gen             varchar,            -- Male / Female / n/a
    dwh_load_date   timestamptz DEFAULT now()
);

DROP TABLE IF EXISTS silver.erp_loc_a101;
CREATE TABLE silver.erp_loc_a101 (
    cid             varchar,            -- same format as crm_cust_info.cst_key
    cntry           varchar,            -- full country name or n/a
    dwh_load_date   timestamptz DEFAULT now()
);

DROP TABLE IF EXISTS silver.erp_px_cat_g1v2;
CREATE TABLE silver.erp_px_cat_g1v2 (
    id              varchar,
    cat             varchar,
    subcat          varchar,
    maintenance     varchar,
    dwh_load_date   timestamptz DEFAULT now()
);
