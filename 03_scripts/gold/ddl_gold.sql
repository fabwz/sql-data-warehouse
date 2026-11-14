/*
===============================================================================
DDL: Gold layer views (star schema)
===============================================================================
Purpose:
    Creates the analytical model of the gold schema as three views, in this
    order: dim_customers, dim_products, fact_sales. Integrates the CRM and ERP
    sources already cleaned in silver. No cleaning logic lives here.
      - dim_customers: CRM is the master source; ERP adds birthdate, country and
        a gender fallback (used only when the CRM gender is 'n/a').
      - dim_products : current version of each product only (prd_end_dt IS NULL),
        enriched with category data from the ERP ('n/a' when there is no match).
      - fact_sales   : one row per sales line, with the surrogate keys of both
        dimensions.

Usage (requires silver loaded: CALL silver.load_silver();):
    docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/gold/ddl_gold.sql

Warnings:
    - Idempotent: CREATE OR REPLACE VIEW, safe to run more than once. Views hold
      no data, so nothing is lost.
    - Surrogate keys (customer_key, product_key) are generated inside the view
      with ROW_NUMBER(). They are NOT stable: if the source data changes (rows
      added or removed), the keys can be reassigned. Do not store them outside
      the warehouse.
    - Exception to "gold reads only from silver": fact_sales joins the gold
      dimension views to obtain the surrogate keys.
    - CREATE OR REPLACE VIEW cannot drop or rename columns of an existing view;
      if the column list changes, DROP VIEW first (fact_sales, then dimensions).
===============================================================================
*/

-- ---------------------------------------------------------------------------
-- gold.dim_customers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gold.dim_customers AS
SELECT
    ROW_NUMBER() OVER (ORDER BY ci.cst_id)  AS customer_key,
    ci.cst_id                               AS customer_id,
    ci.cst_key                              AS customer_number,
    ci.cst_firstname                        AS first_name,
    ci.cst_lastname                         AS last_name,
    COALESCE(la.cntry, 'n/a')               AS country,
    ci.cst_marital_status                   AS marital_status,
    CASE
        WHEN ci.cst_gndr IS NOT NULL AND ci.cst_gndr <> 'n/a' THEN ci.cst_gndr  -- CRM is the master
        ELSE COALESCE(ca.gen, 'n/a')                                            -- ERP as fallback
    END                                     AS gender,
    ca.bdate                                AS birthdate,
    ci.cst_create_date                      AS create_date
FROM silver.crm_cust_info ci
LEFT JOIN silver.erp_cust_az12 ca
       ON ci.cst_key = ca.cid
LEFT JOIN silver.erp_loc_a101 la
       ON ci.cst_key = la.cid;

-- ---------------------------------------------------------------------------
-- gold.dim_products
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gold.dim_products AS
SELECT
    ROW_NUMBER() OVER (ORDER BY pn.prd_start_dt, pn.prd_key) AS product_key,
    pn.prd_id                               AS product_id,
    pn.prd_key                              AS product_number,
    pn.prd_nm                               AS product_name,
    pn.cat_id                               AS category_id,
    COALESCE(pc.cat, 'n/a')                 AS category,
    COALESCE(pc.subcat, 'n/a')              AS subcategory,
    COALESCE(pc.maintenance, 'n/a')         AS maintenance,
    pn.prd_cost                             AS cost,
    pn.prd_line                             AS product_line,
    pn.prd_start_dt                         AS start_date
FROM silver.crm_prd_info pn
LEFT JOIN silver.erp_px_cat_g1v2 pc
       ON pn.cat_id = pc.id
WHERE pn.prd_end_dt IS NULL;                -- current version only

-- ---------------------------------------------------------------------------
-- gold.fact_sales
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gold.fact_sales AS
SELECT
    sd.sls_ord_num      AS order_number,
    pr.product_key      AS product_key,
    cu.customer_key     AS customer_key,
    sd.sls_order_dt     AS order_date,
    sd.sls_ship_dt      AS shipping_date,
    sd.sls_due_dt       AS due_date,
    sd.sls_sales        AS sales_amount,
    sd.sls_quantity     AS quantity,
    sd.sls_price        AS price
FROM silver.crm_sales_details sd
LEFT JOIN gold.dim_products pr
       ON sd.sls_prd_key = pr.product_number
LEFT JOIN gold.dim_customers cu
       ON sd.sls_cust_id = cu.customer_id;
