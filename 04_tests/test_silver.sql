/*
===============================================================================
Tests: Silver layer
===============================================================================
Purpose:
    Quality checks for the silver schema. Every check is a query that returns
    rows ONLY when there is a problem. An empty result means the check passed.

Usage (after CALL silver.load_silver();):
    docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_silver.sql

Warnings:
    - Read-only: only SELECT statements.
    - Each check prints its own title first (\echo), then its rows (if any).
===============================================================================
*/

\echo '--- 01 crm_cust_info: duplicated or NULL cst_id (expected: 0 rows)'
SELECT cst_id, COUNT(*) AS n
FROM silver.crm_cust_info
GROUP BY cst_id
HAVING COUNT(*) > 1 OR cst_id IS NULL;

\echo '--- 02 crm_cust_info: marital status / gender outside the domain (expected: 0 rows)'
SELECT cst_id, cst_marital_status, cst_gndr
FROM silver.crm_cust_info
WHERE cst_marital_status IS NULL OR cst_marital_status NOT IN ('Married', 'Single', 'n/a')
   OR cst_gndr IS NULL OR cst_gndr NOT IN ('Male', 'Female', 'n/a');

\echo '--- 03 crm_cust_info: cst_key does not follow the AW######## format (expected: 0 rows)'
SELECT cst_id, cst_key
FROM silver.crm_cust_info
WHERE cst_key IS NULL OR cst_key !~ '^AW[0-9]{8}$';

\echo '--- 04 crm_prd_info: duplicated prd_id or duplicated (prd_key, prd_start_dt) (expected: 0 rows)'
SELECT 'prd_id' AS check_on, prd_id::text AS value, COUNT(*) AS n
FROM silver.crm_prd_info GROUP BY prd_id HAVING COUNT(*) > 1 OR prd_id IS NULL
UNION ALL
SELECT 'prd_key+start', prd_key || ' ' || prd_start_dt, COUNT(*)
FROM silver.crm_prd_info GROUP BY prd_key, prd_start_dt HAVING COUNT(*) > 1
UNION ALL
SELECT 'null prd_key/start', prd_id::text, 1
FROM silver.crm_prd_info WHERE prd_key IS NULL OR prd_start_dt IS NULL;

\echo '--- 05 crm_prd_info: prd_line outside the domain (expected: 0 rows)'
SELECT prd_id, prd_key, prd_line
FROM silver.crm_prd_info
WHERE prd_line IS NULL OR prd_line NOT IN ('Road', 'Mountain', 'Other Sales', 'Touring', 'n/a');

\echo '--- 06 crm_prd_info: prd_end_dt earlier than prd_start_dt (expected: 0 rows)'
SELECT prd_id, prd_key, prd_start_dt, prd_end_dt
FROM silver.crm_prd_info
WHERE prd_end_dt < prd_start_dt;

\echo '--- 07 crm_prd_info: prd_key without exactly one current row (prd_end_dt IS NULL) (expected: 0 rows)'
SELECT prd_key, COUNT(*) FILTER (WHERE prd_end_dt IS NULL) AS current_rows
FROM silver.crm_prd_info
GROUP BY prd_key
HAVING COUNT(*) FILTER (WHERE prd_end_dt IS NULL) <> 1;

\echo '--- 08 crm_prd_info: versions of the same prd_key that overlap (expected: 0 rows)'
SELECT prd_key, prd_start_dt, prd_end_dt, next_start
FROM (
    SELECT prd_key, prd_start_dt, prd_end_dt,
           LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt) AS next_start
    FROM silver.crm_prd_info
) v
WHERE next_start IS NOT NULL AND (prd_end_dt IS NULL OR prd_end_dt >= next_start);

\echo '--- 09 crm_prd_info: cat_id not derived from the original key or without ERP category (CO_PE is the only accepted exception) (expected: 0 rows)'
SELECT p.prd_id, p.cat_id, p.prd_key
FROM silver.crm_prd_info p
WHERE p.cat_id IS NULL OR p.cat_id !~ '^[A-Z]{2}_[A-Z0-9]{2}$'
   OR (p.cat_id <> 'CO_PE'
       AND NOT EXISTS (SELECT 1 FROM silver.erp_px_cat_g1v2 c WHERE c.id = p.cat_id));

\echo '--- 10 crm_sales_details: duplicated (sls_ord_num, sls_prd_key) (expected: 0 rows)'
SELECT sls_ord_num, sls_prd_key, COUNT(*) AS n
FROM silver.crm_sales_details
GROUP BY sls_ord_num, sls_prd_key
HAVING COUNT(*) > 1;

\echo '--- 11 crm_sales_details: NULL keys, dates, quantity, price or sales (expected: 0 rows)'
SELECT sls_ord_num, sls_prd_key, sls_cust_id
FROM silver.crm_sales_details
WHERE sls_ord_num IS NULL OR sls_prd_key IS NULL OR sls_cust_id IS NULL
   OR sls_order_dt IS NULL OR sls_ship_dt IS NULL OR sls_due_dt IS NULL
   OR sls_sales IS NULL OR sls_quantity IS NULL OR sls_price IS NULL;

\echo '--- 12 crm_sales_details: dates out of order, must be order <= ship <= due (expected: 0 rows)'
SELECT sls_ord_num, sls_prd_key, sls_order_dt, sls_ship_dt, sls_due_dt
FROM silver.crm_sales_details
WHERE sls_order_dt > sls_ship_dt OR sls_ship_dt > sls_due_dt;

\echo '--- 13 crm_sales_details: sls_sales <> sls_quantity * sls_price (expected: 0 rows)'
SELECT sls_ord_num, sls_prd_key, sls_sales, sls_quantity, sls_price
FROM silver.crm_sales_details
WHERE sls_sales <> sls_quantity * sls_price;

\echo '--- 14 crm_sales_details: quantity, price or sales not positive (expected: 0 rows)'
SELECT sls_ord_num, sls_prd_key, sls_sales, sls_quantity, sls_price
FROM silver.crm_sales_details
WHERE sls_quantity <= 0 OR sls_price <= 0 OR sls_sales <= 0;

\echo '--- 15 crm_sales_details: sales without customer or without product (expected: 0 rows)'
SELECT s.sls_ord_num, s.sls_prd_key, s.sls_cust_id
FROM silver.crm_sales_details s
WHERE NOT EXISTS (SELECT 1 FROM silver.crm_cust_info c WHERE c.cst_id = s.sls_cust_id)
   OR NOT EXISTS (SELECT 1 FROM silver.crm_prd_info p WHERE p.prd_key = s.sls_prd_key);

\echo '--- 16 erp_cust_az12: duplicated or NULL cid (expected: 0 rows)'
SELECT cid, COUNT(*) AS n
FROM silver.erp_cust_az12
GROUP BY cid
HAVING COUNT(*) > 1 OR cid IS NULL;

\echo '--- 17 erp_cust_az12: cid with NAS prefix or without a customer in the CRM (expected: 0 rows)'
SELECT a.cid
FROM silver.erp_cust_az12 a
WHERE a.cid LIKE 'NAS%'
   OR NOT EXISTS (SELECT 1 FROM silver.crm_cust_info c WHERE c.cst_key = a.cid);

\echo '--- 18 erp_cust_az12: bdate in the future (expected: 0 rows)'
SELECT cid, bdate
FROM silver.erp_cust_az12
WHERE bdate > CURRENT_DATE;

\echo '--- 19 erp_cust_az12: gen outside the domain (expected: 0 rows)'
SELECT cid, gen
FROM silver.erp_cust_az12
WHERE gen IS NULL OR gen NOT IN ('Male', 'Female', 'n/a');

\echo '--- 20 erp_loc_a101: duplicated or NULL cid (expected: 0 rows)'
SELECT cid, COUNT(*) AS n
FROM silver.erp_loc_a101
GROUP BY cid
HAVING COUNT(*) > 1 OR cid IS NULL;

\echo '--- 21 erp_loc_a101: cid with hyphen or without a customer in the CRM (expected: 0 rows)'
SELECT l.cid
FROM silver.erp_loc_a101 l
WHERE l.cid LIKE '%-%'
   OR NOT EXISTS (SELECT 1 FROM silver.crm_cust_info c WHERE c.cst_key = l.cid);

\echo '--- 22 erp_loc_a101: cntry NULL, empty or with a non-standardized abbreviation (expected: 0 rows)'
SELECT cid, cntry
FROM silver.erp_loc_a101
WHERE cntry IS NULL OR cntry = '' OR cntry IN ('US', 'USA', 'DE');

\echo '--- 23 erp_px_cat_g1v2: duplicated or NULL id, NULL text columns (expected: 0 rows)'
SELECT id, COUNT(*) AS n
FROM silver.erp_px_cat_g1v2
GROUP BY id
HAVING COUNT(*) > 1 OR id IS NULL
UNION ALL
SELECT id, 1
FROM silver.erp_px_cat_g1v2
WHERE cat IS NULL OR subcat IS NULL OR maintenance IS NULL;

\echo '--- 24 all tables: text values with leading or trailing spaces, or empty (expected: 0 rows)'
WITH t AS (
    SELECT 'crm_cust_info' AS tbl, to_jsonb(x) AS j FROM silver.crm_cust_info x UNION ALL
    SELECT 'crm_prd_info',      to_jsonb(x) FROM silver.crm_prd_info x UNION ALL
    SELECT 'crm_sales_details', to_jsonb(x) FROM silver.crm_sales_details x UNION ALL
    SELECT 'erp_cust_az12',     to_jsonb(x) FROM silver.erp_cust_az12 x UNION ALL
    SELECT 'erp_loc_a101',      to_jsonb(x) FROM silver.erp_loc_a101 x UNION ALL
    SELECT 'erp_px_cat_g1v2',   to_jsonb(x) FROM silver.erp_px_cat_g1v2 x
)
SELECT tbl, e.key AS col, COUNT(*) AS bad_rows
FROM t, jsonb_each(j) e
WHERE jsonb_typeof(e.value) = 'string'
  AND (e.value #>> '{}' <> TRIM(e.value #>> '{}') OR e.value #>> '{}' = '')
GROUP BY tbl, e.key;

\echo '--- 25 all tables: dwh_load_date NULL (expected: 0 rows)'
SELECT 'crm_cust_info' AS tbl, COUNT(*) AS bad_rows FROM silver.crm_cust_info WHERE dwh_load_date IS NULL HAVING COUNT(*) > 0
UNION ALL SELECT 'crm_prd_info', COUNT(*) FROM silver.crm_prd_info WHERE dwh_load_date IS NULL HAVING COUNT(*) > 0
UNION ALL SELECT 'crm_sales_details', COUNT(*) FROM silver.crm_sales_details WHERE dwh_load_date IS NULL HAVING COUNT(*) > 0
UNION ALL SELECT 'erp_cust_az12', COUNT(*) FROM silver.erp_cust_az12 WHERE dwh_load_date IS NULL HAVING COUNT(*) > 0
UNION ALL SELECT 'erp_loc_a101', COUNT(*) FROM silver.erp_loc_a101 WHERE dwh_load_date IS NULL HAVING COUNT(*) > 0
UNION ALL SELECT 'erp_px_cat_g1v2', COUNT(*) FROM silver.erp_px_cat_g1v2 WHERE dwh_load_date IS NULL HAVING COUNT(*) > 0;

\echo '--- 26 row counts: silver differs from the expected count (expected: 0 rows)'
SELECT tbl, actual, expected
FROM (
    SELECT 'crm_cust_info' AS tbl, (SELECT COUNT(*) FROM silver.crm_cust_info) AS actual, 18484 AS expected
    UNION ALL SELECT 'crm_prd_info',      (SELECT COUNT(*) FROM silver.crm_prd_info),      397
    UNION ALL SELECT 'crm_sales_details', (SELECT COUNT(*) FROM silver.crm_sales_details), 60398
    UNION ALL SELECT 'erp_cust_az12',     (SELECT COUNT(*) FROM silver.erp_cust_az12),     18484
    UNION ALL SELECT 'erp_loc_a101',      (SELECT COUNT(*) FROM silver.erp_loc_a101),      18484
    UNION ALL SELECT 'erp_px_cat_g1v2',   (SELECT COUNT(*) FROM silver.erp_px_cat_g1v2),   37
) c
WHERE actual <> expected;
