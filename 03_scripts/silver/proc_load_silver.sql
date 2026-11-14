/*
===============================================================================
Stored procedure: silver.load_silver
===============================================================================
Purpose:
    Full reload of the silver layer. For each of the six tables it runs
    TRUNCATE followed by INSERT ... SELECT from the bronze table, applying the
    cleaning rules documented at the top of each block.

Usage:
    CALL silver.load_silver();

Warnings:
    - Run bronze load first (CALL bronze.load_bronze();) and ddl_silver.sql;
      the silver tables must exist.
    - Reads ONLY from bronze. Never reads from gold.
    - Full load: every run empties the tables first, so running it twice does
      not duplicate data.
    - Atomic: the whole procedure runs in the caller's transaction. If any
      table fails, the error is re-raised and ALL silver tables roll back to
      their previous content. Do not call it with COMMIT-per-table wrappers.
    - dwh_load_date is not listed in the INSERTs: it takes its DEFAULT now().
===============================================================================
*/

CREATE OR REPLACE PROCEDURE silver.load_silver()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows          bigint;
    v_total_rows    bigint := 0;
    v_table_start   timestamptz;
    v_batch_start   timestamptz;
BEGIN
    v_batch_start := clock_timestamp();
    RAISE NOTICE '================================================';
    RAISE NOTICE 'Loading silver layer';
    RAISE NOTICE '================================================';

    -- =======================================================================
    -- silver.crm_cust_info
    -- Problems found in bronze and treatment:
    --   * 4 rows with NULL cst_id (empty records, keys that do not follow the
    --     AW######## format): DISCARDED, they cannot be linked to any sale.
    --   * 5 customers repeated (6 extra rows), differing only in
    --     cst_create_date: keep the most recent row (ROW_NUMBER, rn = 1),
    --     which is also the most complete one.
    --   * Leading/trailing spaces in cst_firstname / cst_lastname: TRIM.
    --     NULL names stay NULL.
    --   * cst_marital_status coded M/S: Married / Single; other or NULL -> n/a.
    --   * cst_gndr coded M/F: Male / Female; other or NULL -> n/a.
    -- Expected result: 18,494 - 4 - 6 = 18,484 rows.
    -- =======================================================================
    v_table_start := clock_timestamp();
    RAISE NOTICE '>> Loading silver.crm_cust_info';
    TRUNCATE TABLE silver.crm_cust_info;

    INSERT INTO silver.crm_cust_info (
        cst_id, cst_key, cst_firstname, cst_lastname,
        cst_marital_status, cst_gndr, cst_create_date
    )
    SELECT
        cst_id,
        cst_key,
        TRIM(cst_firstname),
        TRIM(cst_lastname),
        CASE UPPER(TRIM(cst_marital_status))
            WHEN 'M' THEN 'Married'
            WHEN 'S' THEN 'Single'
            ELSE 'n/a'
        END,
        CASE UPPER(TRIM(cst_gndr))
            WHEN 'M' THEN 'Male'
            WHEN 'F' THEN 'Female'
            ELSE 'n/a'
        END,
        cst_create_date
    FROM (
        SELECT b.*,
               ROW_NUMBER() OVER (PARTITION BY cst_id ORDER BY cst_create_date DESC) AS rn
        FROM bronze.crm_cust_info b
        WHERE cst_id IS NOT NULL
    ) d
    WHERE rn = 1;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    v_total_rows := v_total_rows + v_rows;
    RAISE NOTICE '   silver.crm_cust_info loaded: % rows in % s', v_rows,
        round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);

    -- =======================================================================
    -- silver.crm_prd_info
    -- Problems found in bronze and treatment:
    --   * prd_key mixes category and product ("CO-RF-FR-R92B-58"): derive
    --     cat_id = first 5 chars with '-' replaced by '_' (matches
    --     erp_px_cat_g1v2.id) and keep prd_key = substr(prd_key, 7) (matches
    --     crm_sales_details.sls_prd_key). Category CO_PE has no row in the ERP
    --     catalog (7 products); it is kept untouched, Gold shows 'n/a'.
    --   * prd_line has a trailing space and is coded: TRIM, then R -> Road,
    --     M -> Mountain, S -> Other Sales, T -> Touring; NULL/other -> n/a.
    --   * prd_cost is NULL in 2 rows: left as NULL (unknown, not zero).
    --   * prd_end_dt is NOT reliable: 200 rows end before they start (e.g.
    --     2011-07-01 .. 2007-12-28). The original value is DISCARDED and
    --     recalculated as the next version's start date minus 1 day, per
    --     prd_key. The latest version of each key gets NULL (= current), so
    --     every prd_key has exactly one current row.
    --   * Several versions per prd_key (77 keys, 179 rows) are all kept; Gold
    --     uses only the current one (prd_end_dt IS NULL).
    -- Expected result: 397 rows (none discarded).
    -- =======================================================================
    v_table_start := clock_timestamp();
    RAISE NOTICE '>> Loading silver.crm_prd_info';
    TRUNCATE TABLE silver.crm_prd_info;

    INSERT INTO silver.crm_prd_info (
        prd_id, cat_id, prd_key, prd_nm, prd_cost, prd_line,
        prd_start_dt, prd_end_dt
    )
    SELECT
        prd_id,
        REPLACE(LEFT(prd_key, 5), '-', '_'),
        SUBSTR(prd_key, 7),
        prd_nm,
        prd_cost,
        CASE UPPER(TRIM(prd_line))
            WHEN 'R' THEN 'Road'
            WHEN 'M' THEN 'Mountain'
            WHEN 'S' THEN 'Other Sales'
            WHEN 'T' THEN 'Touring'
            ELSE 'n/a'
        END,
        prd_start_dt,
        LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt) - 1
    FROM bronze.crm_prd_info;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    v_total_rows := v_total_rows + v_rows;
    RAISE NOTICE '   silver.crm_prd_info loaded: % rows in % s', v_rows,
        round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);

    -- =======================================================================
    -- silver.crm_sales_details
    -- Problems found in bronze and treatment:
    --   * Dates stored as integers yyyymmdd: converted to date.
    --   * sls_order_dt invalid in 19 rows (17 zeros, 2 values of length <> 8
    --     such as 32154 and 5489): replaced by sls_ship_dt - 7 days. In every
    --     valid row the shipment is exactly 7 days after the order.
    --   * sls_price NULL (7 rows) or 0: derived as sls_sales / sls_quantity;
    --     negative prices (5 rows): abs(). The price wins over the amount.
    --   * sls_sales NULL (8), <= 0 (5) or <> sls_quantity * price (10): set to
    --     sls_quantity * price. Afterwards sales = quantity * price always.
    --   * Type: price and sales are numeric(12,2) because the derived price
    --     can have decimals (e.g. 35 / 2 = 17.50).
    --   * Every row is kept; all customers and products have a match.
    -- Expected result: 60,398 rows (none discarded).
    -- =======================================================================
    v_table_start := clock_timestamp();
    RAISE NOTICE '>> Loading silver.crm_sales_details';
    TRUNCATE TABLE silver.crm_sales_details;

    INSERT INTO silver.crm_sales_details (
        sls_ord_num, sls_prd_key, sls_cust_id,
        sls_order_dt, sls_ship_dt, sls_due_dt,
        sls_sales, sls_quantity, sls_price
    )
    SELECT
        sls_ord_num,
        sls_prd_key,
        sls_cust_id,
        CASE
            WHEN sls_order_dt IS NULL OR sls_order_dt = 0 OR LENGTH(sls_order_dt::text) <> 8
                THEN TO_DATE(sls_ship_dt::text, 'YYYYMMDD') - 7
            ELSE TO_DATE(sls_order_dt::text, 'YYYYMMDD')
        END,
        TO_DATE(sls_ship_dt::text, 'YYYYMMDD'),
        TO_DATE(sls_due_dt::text, 'YYYYMMDD'),
        CASE
            WHEN sls_sales IS NULL OR sls_sales <= 0
                 OR sls_sales <> sls_quantity * sls_price_fix
                THEN sls_quantity * sls_price_fix
            ELSE sls_sales
        END,
        sls_quantity,
        sls_price_fix
    FROM (
        SELECT b.*,
               CASE
                   WHEN sls_price IS NULL OR sls_price = 0
                       THEN ROUND(sls_sales::numeric / NULLIF(sls_quantity, 0), 2)
                   ELSE ABS(sls_price)::numeric
               END AS sls_price_fix
        FROM bronze.crm_sales_details b
    ) s;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    v_total_rows := v_total_rows + v_rows;
    RAISE NOTICE '   silver.crm_sales_details loaded: % rows in % s', v_rows,
        round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);

    -- =======================================================================
    -- silver.erp_cust_az12
    -- Problems found in bronze and treatment:
    --   * cid has the prefix 'NAS' in 11,042 rows: removed, so it matches
    --     crm_cust_info.cst_key (all 18,484 rows match afterwards).
    --   * bdate in the future (16 rows, e.g. 9999-11-20, 2980-03-09): NULL.
    --     Dates before 1924 (15 rows) are kept as they are.
    --   * gen has 9 variants (Male, Female, F, M, with spaces, blank, NULL):
    --     TRIM + UPPER, then F/FEMALE -> Female, M/MALE -> Male, anything else
    --     (blank, only spaces, NULL) -> n/a.
    -- Expected result: 18,484 rows (none discarded).
    -- =======================================================================
    v_table_start := clock_timestamp();
    RAISE NOTICE '>> Loading silver.erp_cust_az12';
    TRUNCATE TABLE silver.erp_cust_az12;

    INSERT INTO silver.erp_cust_az12 (cid, bdate, gen)
    SELECT
        REGEXP_REPLACE(cid, '^NAS', ''),
        CASE WHEN bdate > CURRENT_DATE THEN NULL ELSE bdate END,
        CASE UPPER(TRIM(gen))
            WHEN 'F' THEN 'Female'
            WHEN 'FEMALE' THEN 'Female'
            WHEN 'M' THEN 'Male'
            WHEN 'MALE' THEN 'Male'
            ELSE 'n/a'
        END
    FROM bronze.erp_cust_az12;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    v_total_rows := v_total_rows + v_rows;
    RAISE NOTICE '   silver.erp_cust_az12 loaded: % rows in % s', v_rows,
        round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);

    -- =======================================================================
    -- silver.erp_loc_a101
    -- Problems found in bronze and treatment:
    --   * cid has a hyphen (AW-00011000): removed, so it matches
    --     crm_cust_info.cst_key.
    --   * cntry: spaces (TRIM); US and USA -> United States; DE -> Germany;
    --     NULL, empty or only spaces (337 rows) -> n/a.
    -- Expected result: 18,484 rows (none discarded).
    -- =======================================================================
    v_table_start := clock_timestamp();
    RAISE NOTICE '>> Loading silver.erp_loc_a101';
    TRUNCATE TABLE silver.erp_loc_a101;

    INSERT INTO silver.erp_loc_a101 (cid, cntry)
    SELECT
        REPLACE(cid, '-', ''),
        CASE
            WHEN TRIM(cntry) IN ('US', 'USA') THEN 'United States'
            WHEN TRIM(cntry) = 'DE' THEN 'Germany'
            WHEN cntry IS NULL OR TRIM(cntry) = '' THEN 'n/a'
            ELSE TRIM(cntry)
        END
    FROM bronze.erp_loc_a101;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    v_total_rows := v_total_rows + v_rows;
    RAISE NOTICE '   silver.erp_loc_a101 loaded: % rows in % s', v_rows,
        round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);

    -- =======================================================================
    -- silver.erp_px_cat_g1v2
    -- Problems found in bronze and treatment:
    --   * None found (no nulls, no extra spaces, 37 distinct ids). TRIM is
    --     applied as a preventive measure.
    -- Expected result: 37 rows.
    -- =======================================================================
    v_table_start := clock_timestamp();
    RAISE NOTICE '>> Loading silver.erp_px_cat_g1v2';
    TRUNCATE TABLE silver.erp_px_cat_g1v2;

    INSERT INTO silver.erp_px_cat_g1v2 (id, cat, subcat, maintenance)
    SELECT TRIM(id), TRIM(cat), TRIM(subcat), TRIM(maintenance)
    FROM bronze.erp_px_cat_g1v2;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    v_total_rows := v_total_rows + v_rows;
    RAISE NOTICE '   silver.erp_px_cat_g1v2 loaded: % rows in % s', v_rows,
        round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);

    RAISE NOTICE '================================================';
    RAISE NOTICE 'Silver layer loaded: % rows in total, % s',
        v_total_rows,
        round(extract(epoch FROM clock_timestamp() - v_batch_start)::numeric, 3);
    RAISE NOTICE '================================================';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '================================================';
        RAISE NOTICE 'ERROR while loading silver layer';
        RAISE NOTICE 'Message : %', SQLERRM;
        RAISE NOTICE 'SQLSTATE: %', SQLSTATE;
        RAISE NOTICE '================================================';
        RAISE;
END;
$$;
