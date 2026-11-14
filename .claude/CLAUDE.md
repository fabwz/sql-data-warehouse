# CLAUDE.md

Guía para desarrollar este proyecto con Claude Code. Léela completa al iniciar cada sesión.

## Proyecto

Data warehouse con arquitectura Medallion (Bronze, Silver, Gold) sobre **PostgreSQL**. Integra dos sistemas de origen, CRM y ERP, entregados como 6 archivos CSV, en un modelo en estrella para análisis de ventas.

Proyecto académico (ISW623, UTN).

- Documentación (README, `02_docs/`): español.
- Código, identificadores SQL, comentarios en scripts y mensajes de commit: inglés.

### Alcance

- Solo el conjunto de datos más reciente. No se guarda historial ni se implementan cargas incrementales ni SCD.
- Los problemas de calidad de datos se resuelven en Silver, nunca en Bronze ni en Gold.
- El resultado debe quedar documentado para usuarios de negocio y analistas.

## Arquitectura

Una sola base de datos con tres esquemas. No usar bases de datos separadas por capa: en Postgres no se pueden hacer consultas entre bases de datos.

| Capa | Esquema | Objeto | Carga | Transformación | Modelado |
|------|---------|--------|-------|----------------|----------|
| Bronze | `bronze` | Tablas | Completa: `TRUNCATE` + `COPY` | Ninguna | Ninguno |
| Silver | `silver` | Tablas | Completa: `TRUNCATE` + `INSERT ... SELECT` | Limpieza, estandarización, normalización, columnas derivadas, enriquecimiento | Ninguno |
| Gold | `gold` | Vistas | No aplica | Integración CRM + ERP, agregaciones, reglas de negocio | Esquema en estrella |

Flujo: `CSV` → `bronze` → `silver` → `gold` → BI, consultas SQL, machine learning.

Reglas por capa:

- **Bronze**: copia fiel del CSV. Todas las columnas de origen, con el mismo nombre. No limpiar, no filtrar, no convertir valores. Sirve para trazabilidad y depuración.
- **Silver**: lee solo de Bronze. Cada tabla Silver corresponde a una tabla Bronze, con el mismo nombre. Se agregan las columnas técnicas.
- **Gold**: lee solo de Silver. Vistas que integran las seis fuentes en dimensiones y una tabla de hechos.
- Ninguna capa lee de una capa posterior ni se salta una capa.

## Fuentes de datos

| Sistema | Tabla | Contenido | Clave |
|---------|-------|-----------|-------|
| CRM | `crm_cust_info` | Información de clientes | `cst_id`, `cst_key` |
| CRM | `crm_prd_info` | Productos, vigentes e históricos | `prd_key` |
| CRM | `crm_sales_details` | Transacciones de ventas y pedidos | `prd_key`, `cst_id` |
| ERP | `erp_cust_az12` | Datos adicionales del cliente (fecha de nacimiento) | `cid` |
| ERP | `erp_loc_a101` | Ubicación del cliente (país) | `cid` |
| ERP | `erp_px_cat_g1v2` | Categorías de productos | `id` |

Relaciones entre fuentes:

- `crm_sales_details.prd_key` → `crm_prd_info.prd_key`
- `crm_sales_details.cst_id` → `crm_cust_info.cst_id`
- `crm_cust_info.cst_key` → `erp_cust_az12.cid` y `erp_loc_a101.cid`
- `crm_prd_info.prd_key` → `erp_px_cat_g1v2.id`

Estas relaciones salen de la documentación del curso. Los formatos reales de las claves (prefijos, guiones, mayúsculas) deben verificarse en los datos antes de escribir los joins de Silver y Gold.

Solo se conocen los nombres de las tablas y sus claves. **Las columnas y tipos salen de los encabezados de los CSV en `01_datasets/`. No inventar columnas.**

## Estructura del repositorio

```
sql-data-warehouse-project/
├── 00_setup/          Guía de configuración
├── 01_datasets/       Archivos de origen (solo lectura)
│   ├── source_crm/    3 archivos CSV del CRM
│   └── source_erp/    3 archivos CSV del ERP
├── 02_docs/           Requisitos, diagramas, catálogo de datos
├── 03_scripts/
│   ├── init_database.sql   Crea la base de datos y los esquemas. Se ejecuta primero.
│   ├── bronze/             DDL de tablas y procedimiento de carga
│   ├── silver/             DDL de tablas y procedimiento de carga
│   └── gold/               Vistas del modelo analítico
└── 04_tests/          Verificaciones de calidad de Silver y Gold
```

Orden de scripts dentro de cada capa: primero el DDL (`ddl_<capa>.sql`), luego el procedimiento (`proc_load_<capa>.sql`). Gold usa un solo archivo `ddl_gold.sql` con todas las vistas.

## Convenciones de nombres

### Principios generales

- `snake_case`, todo en minúsculas.
- Inglés para todos los identificadores.
- Sin palabras reservadas de SQL como nombres de objetos.
- Sin comillas dobles en identificadores.

### Tablas

| Capa | Patrón | Ejemplo |
|------|--------|---------|
| Bronze | `<sistema>_<entidad>`, igual que el origen | `crm_cust_info`, `erp_loc_a101` |
| Silver | Igual que Bronze | `crm_cust_info` |
| Gold | `<tipo>_<entidad>`, con nombres de negocio | `dim_customers`, `dim_products`, `fact_sales` |

- `<sistema>`: `crm` o `erp`.
- `<tipo>` en Gold: `dim` para dimensiones, `fact` para hechos, `report` para vistas agregadas de reporte.
- Las entidades en Gold van en plural.
- No repetir el esquema en el nombre: `bronze.crm_cust_info`, no `bronze.bronze_crm_cust_info`.

### Columnas

- **Bronze y Silver**: conservan el nombre original del CSV.
- **Gold**: nombres descriptivos de negocio, en `snake_case` (por ejemplo `customer_id`, `first_name`, `country`, `order_date`, `sales_amount`). Renombrar las columnas de origen cuando su nombre no sea claro.
- **Claves subrogadas**: `<entidad>_key`. Ejemplo: `customer_key`, `product_key`. Solo existen en Gold, generadas con `ROW_NUMBER() OVER (ORDER BY ...)`.
- **Columnas técnicas**: prefijo `dwh_`. Se agregan en Silver. Ejemplo: `dwh_create_date`, con valor por defecto `now()`.
- Tipos de dato: usar el tipo más preciso que permitan los datos (`date`, `integer`, `numeric`, `varchar(n)`, `text`). Bronze puede usar `text` o `varchar` si el CSV trae valores sucios que impiden un tipo estricto.

### Procedimientos y vistas

- Procedimientos: `load_<capa>`, dentro de su esquema. `bronze.load_bronze()`, `silver.load_silver()`.
- Vistas Gold: mismo patrón que las tablas Gold, sin sufijo `_view`.
- Archivos: `ddl_<capa>.sql`, `proc_load_<capa>.sql`, `test_<capa>.sql`.

## Procedimientos de carga

Aplican a Bronze y Silver.

- Se crean con `CREATE OR REPLACE PROCEDURE` y se invocan con `CALL`.
- Cada tabla se carga con `TRUNCATE` seguido de la carga. Sin `DROP TABLE`.
- Cada procedimiento muestra con `RAISE NOTICE`: inicio, tabla cargada, filas insertadas, duración por tabla y duración total.
- Manejo de errores con bloque `EXCEPTION`: mostrar el mensaje (`SQLERRM`) y el código (`SQLSTATE`), y relanzar el error.
- Cada carga se ejecuta dentro de una transacción: si una tabla falla, no queda la capa a medias.

### Carga de Bronze con Postgres

`COPY ... FROM '<ruta>'` lee el archivo desde el servidor de Postgres, no desde la máquina del cliente. Requiere el rol `pg_read_server_files` o superusuario, y que el servidor tenga acceso a la ruta. Si Postgres corre en Docker, hay que montar `01_datasets/` como volumen.

- El procedimiento recibe la ruta base como parámetro (`p_base_path text`) en lugar de tenerla fija.
- `\copy` es un comando de `psql`, no SQL, y no se puede usar dentro de un procedimiento.
- Revisar en cada CSV: delimitador, encabezado (`HEADER true`), codificación y representación de nulos antes de definir las opciones de `COPY`.

## Calidad de datos (Silver)

- Perfilar cada tabla de Bronze antes de escribir Silver: duplicados en claves, nulos, espacios sobrantes, valores fuera de dominio, fechas inválidas, inconsistencias entre columnas relacionadas.
- Documentar cada problema encontrado y su tratamiento en un comentario al inicio del bloque de la tabla, dentro del script Silver.
- Tratamientos típicos: `TRIM`, estandarización de valores categóricos, conversión de tipos, manejo de nulos y ceros, deduplicación con `ROW_NUMBER()`, derivación de columnas.
- Nunca borrar datos sin dejar constancia. Si un registro se descarta, el motivo queda en el comentario.

## Gold

- Vistas con `CREATE OR REPLACE VIEW`.
- Modelo en estrella: dimensiones de clientes y productos, y una tabla de hechos de ventas que referencia las claves subrogadas de las dimensiones.
- La integración CRM + ERP se hace en la dimensión (por ejemplo, el cliente toma sexo y fecha de nacimiento del ERP si el CRM no los tiene).
- Si hay conflicto entre fuentes, el CRM es la fuente principal.
- Las vistas no contienen lógica de limpieza: eso ya se hizo en Silver.

## Pruebas (`04_tests/`)

- Un script por capa: `test_silver.sql`, `test_gold.sql`.
- Cada verificación es una consulta que **devuelve filas solo cuando hay un problema**. Resultado vacío significa que pasó.
- Cada consulta lleva un comentario con lo que verifica y el resultado esperado.
- Verificaciones mínimas:
  - Silver: claves primarias sin duplicados ni nulos, sin espacios sobrantes, valores dentro de dominio, fechas coherentes, valores derivados consistentes.
  - Gold: unicidad de claves subrogadas, integridad referencial entre hechos y dimensiones, sin filas huérfanas.

## Commits

Conventional Commits, un commit por cambio lógico:

```
type(scope): description
```

- Tipos: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`.
- Scopes: `setup`, `bronze`, `silver`, `gold`, `tests`, `docs`.
- Descripción en inglés, en minúsculas, modo imperativo, sin punto final.
- Ejemplos:
  - `chore(setup): initialize repository structure`
  - `feat(bronze): add ddl for crm tables`
  - `feat(silver): clean crm_cust_info`
  - `fix(silver): trim whitespace in prd_key`
  - `test(silver): add duplicate key checks`
- Al terminar cada paso, proponer el mensaje de commit y los archivos que lo componen. El usuario hace el commit.

## Git: restricciones

Claude tiene **prohibido ejecutar comandos de git que modifiquen el repositorio o su historial**. Todo el control de versiones lo hace el usuario manualmente.

Prohibido, sin excepciones y aunque el usuario lo sugiera de pasada:

- `git init`, `git add`, `git commit`, `git push`, `git pull`, `git fetch`
- `git merge`, `git rebase`, `git cherry-pick`, `git revert`, `git reset`, `git restore`, `git checkout`, `git switch`, `git clean`
- `git branch` (crear, renombrar o borrar), `git tag`, `git stash`, `git remote`, `git config`
- Cualquier otro comando que cambie archivos rastreados, el índice, ramas, etiquetas, remotos o el historial

Permitido, solo lectura:

- `git status`, `git diff`, `git log`, `git show`, `git blame`, `git branch --list`, `git ls-files`

Si un paso requiere una acción de git, Claude no la ejecuta: indica al usuario el comando exacto y espera a que lo ejecute.

## Cómo trabajar

- Un paso a la vez. Terminar y verificar una capa antes de empezar la siguiente.
- Orden del proyecto: estructura del repo → base de datos y esquemas → Bronze → Silver → Gold → pruebas → documentación.
- Los scripts deben poder ejecutarse más de una vez sin errores (idempotentes): `CREATE SCHEMA IF NOT EXISTS`, `DROP TABLE IF EXISTS` en el DDL, `CREATE OR REPLACE` en procedimientos y vistas.
- Probar cada script contra una base real antes de dar un paso por terminado. Mostrar el resultado de la ejecución.
- Revisar los datos antes de escribir transformaciones: no asumir formatos.
- No modificar los archivos de `01_datasets/`.
- Ante una decisión de modelado con más de una opción razonable, preguntar antes de implementar.
- Mantener el `README.md` al día: actualizar la sección de estado al terminar cada paso.

## Documentación

Se mantiene en `02_docs/`:

- Diagrama de arquitectura (capas y flujo de datos).
- Diagrama de flujo de datos (de origen a Gold).
- Modelo de datos de Gold (esquema en estrella).
- Catálogo de datos de Gold: por cada vista, descripción y por cada columna, su tipo y significado.

Cada script SQL lleva al inicio un comentario con su propósito y las advertencias de uso.

## Comandos

Postgres corre en Docker (`postgres:16`, contenedor `dwh_postgres`, base `data_warehouse`). Credenciales en `.env` (copiar de `.env.example`, no se versiona). `01_datasets/` se monta en `/datasets` (solo lectura). Los comandos de carga y pruebas se completan cuando existan los scripts correspondientes.

```bash
# primera vez
cp .env.example .env

# levantar / detener el contenedor
docker compose up -d
docker compose down          # conserva los datos; "down -v" los borra

# crear base de datos y esquemas (idempotente)
docker compose exec -T postgres psql -U postgres -f - < 03_scripts/init_database.sql

# consola psql
docker compose exec postgres psql -U postgres -d data_warehouse

# cargar capas (dentro del contenedor los CSV están en /datasets)
docker compose exec postgres psql -U postgres -d data_warehouse -c "CALL bronze.load_bronze('/datasets');"
docker compose exec postgres psql -U postgres -d data_warehouse -c "CALL silver.load_silver();"

# ejecutar pruebas
docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_silver.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_gold.sql
```