/*
===============================================================================
Tests: Gold layer
===============================================================================
Purpose:
    Quality checks for the gold star schema. Every check is a query that returns
    rows ONLY when there is a problem. An empty result means the check passed.

Usage (after CALL silver.load_silver(); and 03_scripts/gold/ddl_gold.sql):
    docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_gold.sql

Warnings:
    - Read-only: only SELECT statements.
    - Each check prints its own title first (\echo), then its rows (if any).
===============================================================================
*/

\echo '--- 01 dim_customers: duplicated or NULL customer_key (expected: 0 rows)'
SELECT customer_key, COUNT(*) AS n
FROM gold.dim_customers
GROUP BY customer_key
HAVING COUNT(*) > 1 OR customer_key IS NULL;

\echo '--- 02 dim_customers: duplicated or NULL customer_id (expected: 0 rows)'
SELECT customer_id, COUNT(*) AS n
FROM gold.dim_customers
GROUP BY customer_id
HAVING COUNT(*) > 1 OR customer_id IS NULL;

\echo '--- 03 dim_customers: row count differs from silver.crm_cust_info, i.e. a join duplicated or lost customers (expected: 0 rows)'
SELECT d.n AS gold_rows, s.n AS silver_rows
FROM (SELECT COUNT(*) AS n FROM gold.dim_customers) d,
     (SELECT COUNT(*) AS n FROM silver.crm_cust_info) s
WHERE d.n <> s.n OR d.n <> 18484;

\echo '--- 04 dim_customers: gender NULL, empty or outside the domain (expected: 0 rows)'
SELECT customer_key, customer_id, gender
FROM gold.dim_customers
WHERE gender IS NULL OR TRIM(gender) = '' OR gender NOT IN ('Male', 'Female', 'n/a');

\echo '--- 05 dim_customers: country NULL or empty (expected: 0 rows)'
SELECT customer_key, customer_id, country
FROM gold.dim_customers
WHERE country IS NULL OR TRIM(country) = '';

\echo '--- 06 dim_customers: CRM gender known but gold gender differs (CRM must win) (expected: 0 rows)'
SELECT d.customer_key, d.customer_id, c.cst_gndr AS crm_gender, d.gender AS gold_gender
FROM gold.dim_customers d
JOIN silver.crm_cust_info c ON c.cst_id = d.customer_id
WHERE c.cst_gndr <> 'n/a' AND d.gender <> c.cst_gndr;

\echo '--- 07 dim_products: duplicated or NULL product_key (expected: 0 rows)'
SELECT product_key, COUNT(*) AS n
FROM gold.dim_products
GROUP BY product_key
HAVING COUNT(*) > 1 OR product_key IS NULL;

\echo '--- 08 dim_products: duplicated or NULL product_number (expected: 0 rows)'
SELECT product_number, COUNT(*) AS n
FROM gold.dim_products
GROUP BY product_number
HAVING COUNT(*) > 1 OR product_number IS NULL;

\echo '--- 09 dim_products: row count differs from 295 or from distinct prd_key in silver (expected: 0 rows)'
SELECT d.n AS gold_rows, s.n AS silver_distinct_prd_key
FROM (SELECT COUNT(*) AS n FROM gold.dim_products) d,
     (SELECT COUNT(DISTINCT prd_key) AS n FROM silver.crm_prd_info) s
WHERE d.n <> s.n OR d.n <> 295;

\echo '--- 10 dim_products: a silver product without exactly one row in the dimension (expected: 0 rows)'
SELECT s.prd_key, COUNT(d.product_key) AS rows_in_dim
FROM (SELECT DISTINCT prd_key FROM silver.crm_prd_info) s
LEFT JOIN gold.dim_products d ON d.product_number = s.prd_key
GROUP BY s.prd_key
HAVING COUNT(d.product_key) <> 1;

\echo '--- 11 dim_products: category, subcategory or maintenance NULL or empty (expected: 0 rows)'
SELECT product_key, product_number, category, subcategory, maintenance
FROM gold.dim_products
WHERE category IS NULL OR TRIM(category) = ''
   OR subcategory IS NULL OR TRIM(subcategory) = ''
   OR maintenance IS NULL OR TRIM(maintenance) = '';

\echo '--- 12 fact_sales: row count differs from silver.crm_sales_details (rows lost or duplicated) (expected: 0 rows)'
SELECT f.n AS gold_rows, s.n AS silver_rows
FROM (SELECT COUNT(*) AS n FROM gold.fact_sales) f,
     (SELECT COUNT(*) AS n FROM silver.crm_sales_details) s
WHERE f.n <> s.n OR f.n <> 60398;

\echo '--- 13 fact_sales: duplicated or NULL (order_number, product_key) (expected: 0 rows)'
SELECT order_number, product_key, COUNT(*) AS n
FROM gold.fact_sales
GROUP BY order_number, product_key
HAVING COUNT(*) > 1 OR order_number IS NULL OR product_key IS NULL;

\echo '--- 14 fact_sales: orphan rows, NULL customer_key or product_key (expected: 0 rows)'
SELECT order_number, product_key, customer_key
FROM gold.fact_sales
WHERE customer_key IS NULL OR product_key IS NULL;

\echo '--- 15 fact_sales: customer_key or product_key not present in its dimension (expected: 0 rows)'
SELECT f.order_number, f.customer_key, f.product_key
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c ON c.customer_key = f.customer_key
LEFT JOIN gold.dim_products  p ON p.product_key  = f.product_key
WHERE c.customer_key IS NULL OR p.product_key IS NULL;

\echo '--- 16 fact_sales: total sales_amount differs from silver.crm_sales_details (expected: 0 rows)'
SELECT f.total AS gold_total, s.total AS silver_total
FROM (SELECT SUM(sales_amount) AS total FROM gold.fact_sales) f,
     (SELECT SUM(sls_sales)    AS total FROM silver.crm_sales_details) s
WHERE f.total IS DISTINCT FROM s.total;
