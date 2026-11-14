# Reglas de calidad de datos (Silver)

Reglas de limpieza que aplica `silver.load_silver()` (`03_scripts/silver/proc_load_silver.sql`). Los problemas se encontraron al perfilar Bronze; cada regla se resuelve únicamente en Silver. Bronze conserva el dato original para trazabilidad y Gold no contiene lógica de limpieza.

Las cifras salen de los comentarios del script y se recontaron contra Bronze en una carga desde cero. Las columnas con "(medido)" no figuran en los comentarios del script y se contaron directamente en Bronze.

Regla general: no se borran datos sin dejar constancia. Los únicos registros descartados son 10 filas de `crm_cust_info` (4 sin `cst_id` y 6 repetidas); el resto de las tablas conserva todas sus filas.

## Resumen de filas

| Tabla | Filas en Bronze | Filas en Silver | Diferencia |
|-------|-----------------|-----------------|------------|
| `crm_cust_info` | 18 494 | 18 484 | -10 (4 sin `cst_id` + 6 repetidas) |
| `crm_prd_info` | 397 | 397 | 0 |
| `crm_sales_details` | 60 398 | 60 398 | 0 |
| `erp_cust_az12` | 18 484 | 18 484 | 0 |
| `erp_loc_a101` | 18 484 | 18 484 | 0 |
| `erp_px_cat_g1v2` | 37 | 37 | 0 |

## silver.crm_cust_info

| Problema encontrado | Filas afectadas | Tratamiento aplicado | Motivo |
|---------------------|-----------------|----------------------|--------|
| `cst_id` nulo (registros vacíos, con claves que no siguen el formato `AW########`) | 4 | Se descartan | No se pueden enlazar con ninguna venta |
| Clientes repetidos, con distinta `cst_create_date` | 5 clientes (6 filas sobrantes) | Deduplicación con `ROW_NUMBER() OVER (PARTITION BY cst_id ORDER BY cst_create_date DESC)`; se conserva la fila más reciente | La más reciente es también la más completa; garantiza una fila por cliente |
| Espacios al inicio o al final en nombre y apellido | 29 (medido) | `TRIM`. Los nombres nulos se dejan `NULL` | Estandarización; un nulo es "desconocido", no un texto |
| Estado civil codificado (`M`/`S`) | Todas las filas | `M` → `Married`, `S` → `Single`; otro valor o nulo → `n/a` | Etiquetas legibles para el negocio. En los datos actuales ninguna queda en `n/a` (medido) |
| Género codificado (`M`/`F`) | Todas las filas | `M` → `Male`, `F` → `Female`; otro valor o nulo → `n/a` | Etiquetas legibles. 4 569 clientes quedan en `n/a` (medido); Gold los completa con el ERP cuando puede |

## silver.crm_prd_info

| Problema encontrado | Filas afectadas | Tratamiento aplicado | Motivo |
|---------------------|-----------------|----------------------|--------|
| `prd_key` mezcla categoría y producto (`CO-RF-FR-R92B-58`) | 397 | `cat_id` = primeros 5 caracteres con `-` → `_`; `prd_key` = desde el carácter 7 | `cat_id` coincide con `erp_px_cat_g1v2.id` y `prd_key` coincide con `crm_sales_details.sls_prd_key` |
| Categoría `CO_PE` sin fila en el catálogo del ERP | 7 | Se conservan con `cat_id = 'CO_PE'` | No se descarta el dato; Gold muestra `'n/a'` en categoría, subcategoría y mantenimiento |
| `prd_line` codificada y con espacio al final | 380 con espacios (medido); 397 codificadas | `TRIM`; `R` → `Road`, `M` → `Mountain`, `S` → `Other Sales`, `T` → `Touring`; nulo u otro → `n/a` | Etiquetas legibles. 17 quedan en `n/a` (medido) |
| `prd_cost` nulo | 2 | Se deja `NULL` | Es un dato desconocido; poner 0 falsearía los promedios |
| `prd_end_dt` no confiable: la fecha de fin es anterior a la de inicio | 200 | Se descarta el valor original y se recalcula: `LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt) - 1 día`. La última versión queda en `NULL` (vigente) | Las fechas originales eran incoherentes. Cada `prd_key` queda con exactamente una fila vigente |
| Varias versiones por producto | 77 productos, 179 filas | Se conservan todas | Silver no pierde información; Gold usa solo la vigente (`prd_end_dt IS NULL`): 295 productos |

## silver.crm_sales_details

| Problema encontrado | Filas afectadas | Tratamiento aplicado | Motivo |
|---------------------|-----------------|----------------------|--------|
| Fechas guardadas como entero `yyyymmdd` | Todas | Conversión a `date` con `TO_DATE` | Tipo correcto para filtrar y calcular |
| `sls_order_dt` inválida: 0, nula o con longitud distinta de 8 | 19 (17 ceros y 2 valores como `32154` y `5489`) | `sls_ship_dt - 7 días` | En todas las filas válidas el envío ocurre exactamente 7 días después del pedido |
| `sls_price` nulo | 7 | `ROUND(sls_sales / sls_quantity, 2)` | El precio manda sobre el importe |
| `sls_price` igual a 0 | 0 en los datos actuales (medido) | Misma regla que el nulo | Regla preventiva: el script la contempla pero ninguna fila la activa hoy |
| `sls_price` negativo | 5 | `ABS()` | Un precio negativo es un error de signo |
| `sls_sales` nulo | 8 | `sls_quantity * sls_price` | Garantiza importe = cantidad × precio |
| `sls_sales` menor o igual a 0 | 5 | `sls_quantity * sls_price` | Ídem |
| `sls_sales` distinto de `sls_quantity * sls_price` | 10 | `sls_quantity * sls_price` | Ídem. Después de esto la igualdad se cumple siempre |
| Tipo de `sls_sales` y `sls_price` | Todas | `numeric(12,2)` en lugar de entero | El precio derivado puede tener decimales (por ejemplo 35 / 2 = 17,50) |

Las filas no se descartan: todos los clientes y productos de las ventas tienen correspondencia.

## silver.erp_cust_az12

| Problema encontrado | Filas afectadas | Tratamiento aplicado | Motivo |
|---------------------|-----------------|----------------------|--------|
| `cid` con prefijo `NAS` | 11 042 | `REGEXP_REPLACE(cid, '^NAS', '')` | Coincide con `crm_cust_info.cst_key`. Después, las 18 484 filas tienen correspondencia |
| `bdate` en el futuro (por ejemplo `9999-11-20`, `2980-03-09`) | 16 | Se reemplaza por `NULL` | Fecha imposible |
| `bdate` anterior a 1924 | 15 | Se conservan | Decisión registrada en `.claude/CLAUDE.md`: solo las fechas futuras se anulan |
| `gen` con 9 variantes (`Male`, `Female`, `F`, `M`, con espacios, vacío, nulo) | Todas | `TRIM` + `UPPER`; `F`/`FEMALE` → `Female`, `M`/`MALE` → `Male`; el resto → `n/a` | Estandarización. 1 476 quedan en `n/a` (medido) |

## silver.erp_loc_a101

| Problema encontrado | Filas afectadas | Tratamiento aplicado | Motivo |
|---------------------|-----------------|----------------------|--------|
| `cid` con guion (`AW-00011000`) | 18 484 (medido) | `REPLACE(cid, '-', '')` | Coincide con `crm_cust_info.cst_key` |
| `cntry` con abreviaturas | `US`/`USA`: 4 091; `DE`: 566 (medido) | `US`, `USA` → `United States`; `DE` → `Germany` | Un solo nombre por país |
| `cntry` con espacios sobrantes | 5 (medido) | `TRIM` | Estandarización |
| `cntry` nulo, vacío o solo espacios | 337 | `n/a` | Dato desconocido. Estos clientes aparecen con país `'n/a'` en Gold (871 líneas de venta) |

## silver.erp_px_cat_g1v2

| Problema encontrado | Filas afectadas | Tratamiento aplicado | Motivo |
|---------------------|-----------------|----------------------|--------|
| Ninguno (sin nulos, sin espacios sobrantes, 37 ids distintos) | 0 | `TRIM` preventivo en todas las columnas | Protege ante cargas futuras |

## Columna técnica

Todas las tablas de Silver tienen `dwh_load_date` (`timestamptz`, por defecto `now()`), que registra cuándo se cargó cada fila. El procedimiento no la incluye en los `INSERT`: toma el valor por defecto.

## Verificación

Cada regla tiene su prueba en `04_tests/test_silver.sql` (26 verificaciones, cada una devuelve filas solo si hay un problema). Ver el resultado esperado en el encabezado de cada consulta.
