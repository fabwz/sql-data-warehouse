/*
===============================================================================
Stored procedure: bronze.load_bronze
===============================================================================
Purpose:
    Full reload of the bronze layer. For each of the six tables it runs
    TRUNCATE followed by COPY from the source CSV. No transformation at all.

Usage:
    CALL bronze.load_bronze();                    -- default path: /datasets
    CALL bronze.load_bronze('/datasets');         -- explicit base path

Parameters:
    p_base_path  Folder that contains source_crm/ and source_erp/, as seen by
                 the POSTGRES SERVER (not by the client). With the project's
                 docker-compose.yml, 01_datasets/ is mounted at /datasets.

Warnings:
    - Run ddl_bronze.sql first; the tables must exist.
    - COPY ... FROM '<file>' reads the file on the server. It needs the
      pg_read_server_files role or superuser, and the path must be reachable
      from the server (in Docker: the mounted volume).
    - Full load: every run empties the tables first, so running it twice does
      not duplicate data.
    - Atomic: the whole procedure runs in the caller's transaction. If any
      table fails, the error is re-raised and ALL tables roll back to their
      previous content. Do not call it with COMMIT-per-table wrappers.
    - COPY options, decided after inspecting the CSV files: comma delimiter,
      header row, UTF-8 without BOM, CRLF line endings (handled by COPY), no
      quoted fields, and NULL '' so that empty fields become NULL. Whitespace
      is never trimmed.
===============================================================================
*/

CREATE OR REPLACE PROCEDURE bronze.load_bronze(p_base_path text DEFAULT '/datasets')
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec           record;
    v_rows          bigint;
    v_total_rows    bigint := 0;
    v_table_start   timestamptz;
    v_batch_start   timestamptz;
BEGIN
    v_batch_start := clock_timestamp();
    RAISE NOTICE '================================================';
    RAISE NOTICE 'Loading bronze layer from: %', p_base_path;
    RAISE NOTICE '================================================';

    FOR v_rec IN
        SELECT t.tbl, t.file
        FROM (VALUES
            ('crm_cust_info',     '/source_crm/cust_info.csv'),
            ('crm_prd_info',      '/source_crm/prd_info.csv'),
            ('crm_sales_details', '/source_crm/sales_details.csv'),
            ('erp_cust_az12',     '/source_erp/CUST_AZ12.csv'),
            ('erp_loc_a101',      '/source_erp/LOC_A101.csv'),
            ('erp_px_cat_g1v2',   '/source_erp/PX_CAT_G1V2.csv')
        ) AS t(tbl, file)
    LOOP
        v_table_start := clock_timestamp();
        RAISE NOTICE '>> Loading bronze.%', v_rec.tbl;

        EXECUTE format('TRUNCATE TABLE bronze.%I', v_rec.tbl);

        EXECUTE format(
            'COPY bronze.%I FROM %L WITH (FORMAT csv, HEADER true, DELIMITER '','', NULL '''', ENCODING ''UTF8'')',
            v_rec.tbl,
            p_base_path || v_rec.file
        );
        GET DIAGNOSTICS v_rows = ROW_COUNT;

        v_total_rows := v_total_rows + v_rows;
        RAISE NOTICE '   bronze.% loaded: % rows in % s',
            v_rec.tbl, v_rows,
            round(extract(epoch FROM clock_timestamp() - v_table_start)::numeric, 3);
    END LOOP;

    RAISE NOTICE '================================================';
    RAISE NOTICE 'Bronze layer loaded: % rows in total, % s',
        v_total_rows,
        round(extract(epoch FROM clock_timestamp() - v_batch_start)::numeric, 3);
    RAISE NOTICE '================================================';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '================================================';
        RAISE NOTICE 'ERROR while loading bronze layer';
        RAISE NOTICE 'Message : %', SQLERRM;
        RAISE NOTICE 'SQLSTATE: %', SQLSTATE;
        RAISE NOTICE '================================================';
        RAISE;
END;
$$;
