# SQL Data Warehouse - Arquitectura Medallion

Data warehouse sobre PostgreSQL que consolida información de ventas de un sistema CRM y un sistema ERP en un modelo en estrella listo para análisis.

Proyecto del curso ISW623, Universidad Técnica Nacional.

## Objetivo

Importar los datos de dos sistemas de origen, depurarlos y exponerlos en un modelo analítico que permita generar reportes y apoyar la toma de decisiones.

## Alcance

|Aspecto|Descripción|
|-|-|
|Fuentes|6 archivos CSV: 3 del CRM y 3 del ERP|
|Calidad de datos|Los problemas se resuelven en la capa Silver, antes de cualquier análisis|
|Integración|CRM y ERP se combinan en un único modelo de datos|
|Datos|Solo el conjunto más reciente. No se mantiene historial|
|Documentación|Modelo de datos y catálogo para usuarios de negocio y analistas|

## Stack técnico

* **Motor:** PostgreSQL 16, en Docker (`postgres:16`)
* **Lenguaje:** SQL y PL/pgSQL
* **Carga:** `COPY` desde archivos CSV
* **Cliente:** `psql`
* **Control de versiones:** Git, con Conventional Commits

## Arquitectura

Una sola base de datos con un esquema por capa. Los esquemas permiten consultar entre capas, algo que no es posible con bases de datos separadas en PostgreSQL.

```
CSV (CRM y ERP) ──▶ bronze ──▶ silver ──▶ gold ──▶ BI, consultas SQL, machine learning
                    tablas     tablas     vistas
                    originales depurados  estrella
```

Diagramas en Mermaid: [`02_docs/data_architecture.md`](02_docs/data_architecture.md).

|Capa|Esquema|Objeto|Carga|Transformación|Modelado|Público|
|-|-|-|-|-|-|-|
|Bronze|`bronze`|Tablas|Completa (truncate + copy)|Ninguna|Ninguno|Ingenieros de datos|
|Silver|`silver`|Tablas|Completa (truncate + insert)|Limpieza, estandarización, normalización, columnas derivadas, enriquecimiento|Ninguno|Analistas e ingenieros de datos|
|Gold|`gold`|Vistas|No aplica|Integración, agregaciones, reglas de negocio|Esquema en estrella|Analistas y usuarios de negocio|

### Flujo de carga

1. `bronze.load_bronze()` vacía cada tabla y la carga desde su CSV con `COPY`, sin transformar.
2. `silver.load_silver()` vacía cada tabla, lee de Bronze y aplica la limpieza y las columnas derivadas.
3. Las vistas de `gold` leen de Silver y se actualizan solas al cambiar los datos subyacentes.

Cada procedimiento se ejecuta en una transacción y reporta filas cargadas y duración por tabla. Si una tabla falla, la carga se revierte completa.

## Fuentes de datos

|Sistema|Tabla|Contenido|
|-|-|-|
|CRM|`crm_cust_info`|Información de clientes|
|CRM|`crm_prd_info`|Productos, vigentes e históricos|
|CRM|`crm_sales_details`|Transacciones de ventas y pedidos|
|ERP|`erp_cust_az12`|Datos adicionales del cliente (fecha de nacimiento)|
|ERP|`erp_loc_a101`|Ubicación del cliente (país)|
|ERP|`erp_px_cat_g1v2`|Categorías de productos|

Relaciones entre fuentes:

```
crm_sales_details ──(prd_key)──▶ crm_prd_info ──(prd_key)──▶ erp_px_cat_g1v2
        │
     (cst_id)
        ▼
  crm_cust_info ──(cst_key)──▶ erp_cust_az12
                       └─────▶ erp_loc_a101
```

## Modelo analítico (Gold)

Esquema en estrella con una tabla de hechos y dos dimensiones.

|Vista|Tipo|Descripción|
|-|-|-|
|`gold.dim_customers`|Dimensión|Clientes del CRM enriquecidos con datos del ERP|
|`gold.dim_products`|Dimensión|Productos del CRM con su categoría del ERP|
|`gold.fact_sales`|Hechos|Transacciones de venta, referenciadas a las claves subrogadas de las dimensiones|

El diagrama del modelo está en [`02_docs/data_model.md`](02_docs/data_model.md) y el catálogo de datos en [`02_docs/data_catalog.md`](02_docs/data_catalog.md).

## Calidad de datos

* Cada tabla de Bronze se perfila antes de escribir su transformación en Silver: duplicados, nulos, espacios sobrantes, valores fuera de dominio y fechas inválidas.
* Cada problema encontrado y su tratamiento se documenta en el script de Silver correspondiente.
* Las pruebas de `04_tests/` son consultas que devuelven filas solo cuando detectan un problema. Un resultado vacío indica que la verificación pasó.

## Estructura del repositorio

```
.
├── 00_setup/       Guía de configuración
├── 01_datasets/    Archivos CSV de origen
│   ├── source_crm/
│   └── source_erp/
├── 02_docs/        Requisitos, diagramas, catálogo de datos y convenciones de nombres
├── 03_scripts/     Scripts SQL
│   ├── init_database.sql
│   ├── bronze/
│   ├── silver/
│   └── gold/
├── 04_tests/       Pruebas de calidad de Silver y Gold
├── docker-compose.yml
└── .env.example
```

## Requisitos

* Docker con Docker Compose
* `psql` (opcional: también se puede usar el de dentro del contenedor)
* Git
* `COPY` lee los archivos desde el servidor, no desde el cliente. Por eso `docker-compose.yml` monta `01_datasets/` en `/datasets` (solo lectura).

## Puesta en marcha

1. Clonar el repositorio y verificar que los CSV estén en `01_datasets/`.
2. Crear el archivo de variables de entorno y levantar PostgreSQL en Docker:

```bash
cp .env.example .env
docker compose up -d
```

3. Crear la base de datos `data_warehouse` y los esquemas:

```bash
docker compose exec -T postgres psql -U postgres -f - < 03_scripts/init_database.sql
```

4. Crear las tablas y los procedimientos de Bronze y Silver (los DDL borran y recrean las tablas) y cargar las capas, en orden (dentro del contenedor los CSV están en `/datasets`):

```bash
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/bronze/ddl_bronze.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/bronze/proc_load_bronze.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/silver/ddl_silver.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/silver/proc_load_silver.sql
docker compose exec postgres psql -U postgres -d data_warehouse -c "CALL bronze.load_bronze('/datasets');"
docker compose exec postgres psql -U postgres -d data_warehouse -c "CALL silver.load_silver();"
```

5. Crear las vistas de Gold (idempotente; requiere Silver cargado) y ejecutar las pruebas (cada verificación devuelve filas solo si hay un problema):

```bash
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/gold/ddl_gold.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_silver.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_gold.sql
```

6. Consultar el modelo analítico en el esquema `gold`.

La guía detallada está en [`00_setup/README.md`](00_setup/README.md).

## Documentación

Todo en [`02_docs/`](02_docs/):

|Documento|Contenido|
|-|-|
|[`requirements.md`](02_docs/requirements.md)|Objetivo, alcance y criterios de aceptación|
|[`data_architecture.md`](02_docs/data_architecture.md)|Diagrama de capas y detalle de Bronze, Silver y Gold|
|[`data_flow.md`](02_docs/data_flow.md)|Linaje de cada tabla de origen hasta las vistas de Gold|
|[`data_model.md`](02_docs/data_model.md)|Esquema en estrella y granularidad de la tabla de hechos|
|[`data_catalog.md`](02_docs/data_catalog.md)|Catálogo de Gold para usuarios de negocio, con ejemplos de consultas|
|[`data_quality_rules.md`](02_docs/data_quality_rules.md)|Reglas de limpieza aplicadas en Silver|
|[`convenciones_nomenclatura_es.md`](02_docs/convenciones_nomenclatura_es.md)|Convenciones de nombres (oficial)|

## Estado

Las pruebas (`04_tests/`) se escribieron junto con cada capa, no como un paso aparte.

|Paso|Estado|
|-|-|
|1. Estructura del repositorio|Hecho|
|2. Base de datos y esquemas (Docker)|Hecho y verificado|
|3. Bronze|Hecho y verificado (6 tablas, `bronze.load_bronze()`: 18 494, 397, 60 398, 18 484, 18 484 y 37 filas)|
|4. Silver|Hecho y verificado (6 tablas, `silver.load_silver()` y `04_tests/test_silver.sql`: 26 verificaciones sin hallazgos)|
|5. Gold|Hecho y verificado (3 vistas: 18 484, 295 y 60 398 filas; `04_tests/test_gold.sql`: 16 verificaciones sin hallazgos)|
|6. Documentación y verificación final|Hecho y verificado (6 documentos en `02_docs/`; flujo completo ejecutado desde cero con `docker compose down -v`)|

## Convenciones

**Nombres de objetos**

La referencia completa es [`02_docs/convenciones_nomenclatura_es.md`](02_docs/convenciones_nomenclatura_es.md). Resumen:

|Elemento|Convención|Ejemplo|
|-|-|-|
|General|`snake_case`, minúsculas, inglés, sin palabras reservadas de SQL|`sales_amount`|
|Tablas Bronze y Silver|`<sourcesystem>_<entity>`, con el nombre original sin modificar|`crm_cust_info`|
|Tablas/vistas Gold|`<category>_<entity>` con `dim_`, `fact_` o `report_`|`dim_customers`|
|Claves subrogadas|`<table_name>_key`|`customer_key`|
|Columnas técnicas|prefijo `dwh_`|`dwh_load_date`|
|Procedimientos|`load_<layer>`|`silver.load_silver()`|

**Commits**

Conventional Commits con el formato `type(scope): description`.

* Tipos: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`
* Scopes: `setup`, `bronze`, `silver`, `gold`, `tests`, `docs`
* Ejemplo: `feat(bronze): add ddl for crm tables`

