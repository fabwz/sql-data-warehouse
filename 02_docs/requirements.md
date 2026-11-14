# Requisitos del proyecto

## Objetivo

Importar los datos de dos sistemas de origen (CRM y ERP), depurarlos y exponerlos en un modelo analítico en estrella que permita generar reportes y apoyar la toma de decisiones sobre ventas.

## Alcance

| Aspecto | Descripción |
|---------|-------------|
| Fuentes | 6 archivos CSV en `01_datasets/`: 3 del CRM (`crm_cust_info`, `crm_prd_info`, `crm_sales_details`) y 3 del ERP (`erp_cust_az12`, `erp_loc_a101`, `erp_px_cat_g1v2`). Son de solo lectura. |
| Calidad de datos | Los problemas se detectan con perfilado de Bronze y se resuelven en Silver, nunca en Bronze ni en Gold. Cada problema y su tratamiento queda documentado en el script de Silver y resumido en [`data_quality_rules.md`](data_quality_rules.md). |
| Integración | CRM y ERP se combinan en un único modelo. El CRM es la fuente maestra; el ERP aporta fecha de nacimiento, país, categorías de producto y un respaldo para el género. |
| Sin historial | Solo se conserva el conjunto de datos más reciente. No hay cargas incrementales ni dimensiones de cambio lento (SCD). Cada carga reemplaza todo el contenido. |
| Documentación | Modelo de datos y catálogo para usuarios de negocio y analistas, en `02_docs/`. |

Fuera de alcance: cargas incrementales, historial de cambios, automatización o programación de las cargas, y herramientas de BI.

## Restricciones técnicas

- PostgreSQL 16 en Docker, una sola base de datos (`data_warehouse`) con tres esquemas: `bronze`, `silver` y `gold`.
- Bronze y Silver son tablas con carga completa (`TRUNCATE` + carga). Gold son vistas.
- Nombres según [`convenciones_nomenclatura_es.md`](convenciones_nomenclatura_es.md).
- Los scripts son idempotentes y los procedimientos de carga son atómicos (si falla una tabla, no queda la capa a medias).

## Criterios de aceptación

Cada criterio es verificable. Todos se comprobaron en una ejecución desde cero (`docker compose down -v`, luego el orden documentado en [`00_setup/README.md`](../00_setup/README.md)).

| # | Criterio | Cómo se verifica | Resultado esperado |
|---|----------|------------------|--------------------|
| 1 | Los 6 CSV se cargan completos en Bronze, sin transformar | `CALL bronze.load_bronze();` | 18 494, 397, 60 398, 18 484, 18 484 y 37 filas |
| 2 | Silver contiene las 6 tablas depuradas | `CALL silver.load_silver();` | 18 484, 397, 60 398, 18 484, 18 484 y 37 filas |
| 3 | Silver no tiene claves duplicadas ni nulas, espacios sobrantes, valores fuera de dominio ni fechas incoherentes | `04_tests/test_silver.sql` | 0 filas en cada una de las 26 verificaciones |
| 4 | Gold expone el esquema en estrella: `dim_customers`, `dim_products` y `fact_sales` | `03_scripts/gold/ddl_gold.sql` | 18 484, 295 y 60 398 filas |
| 5 | Las claves subrogadas son únicas y la tabla de hechos no tiene filas huérfanas | `04_tests/test_gold.sql` | 0 filas en cada una de las 16 verificaciones |
| 6 | No se pierde ni se duplica ningún importe entre Silver y Gold | verificación 16 de `test_gold.sql` | `SUM(sales_amount)` de `fact_sales` = `SUM(sls_sales)` de Silver |
| 7 | Cada capa respeta su regla de lectura: Silver lee solo de Bronze y Gold solo de Silver (excepción: `fact_sales` usa las dimensiones Gold para las claves subrogadas) | Revisión de los scripts | Sin lecturas hacia atrás ni saltos de capa |
| 8 | Los scripts se pueden ejecutar más de una vez sin errores | Reejecución de los scripts | Mismos conteos, sin duplicados |
| 9 | La documentación está completa: arquitectura, flujo de datos, modelo, catálogo y reglas de calidad | Archivos de `02_docs/` | Ver [`README.md`](../README.md), sección "Documentación" |
| 10 | Todo el flujo se reproduce siguiendo solo la guía de configuración | `00_setup/README.md` | Mismos resultados desde cero |
