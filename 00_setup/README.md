# Guía de configuración

Levanta PostgreSQL 16 en Docker y crea la base de datos `data_warehouse` con los esquemas `bronze`, `silver` y `gold`.

## Requisitos

* Docker (con Docker Compose)
* Cliente `psql` opcional: todos los comandos pueden ejecutarse dentro del contenedor

## 1. Variables de entorno

```bash
cp .env.example .env
```

Edita `.env` si quieres cambiar el usuario o la contraseña. El archivo `.env` no se versiona.

## 2. Levantar el contenedor

```bash
docker compose up -d
docker compose ps
```

El contenedor se llama `dwh_postgres`, escucha en el puerto 5432 y guarda los datos en el volumen `pgdata`. La carpeta `01_datasets/` se monta en `/datasets` (solo lectura) para que `COPY` pueda leer los CSV:

```bash
docker compose exec postgres ls /datasets
```

## 3. Crear la base de datos y los esquemas

Sin `psql` local (recomendado):

```bash
docker compose exec -T postgres psql -U postgres -f - < 03_scripts/init_database.sql
```

Con `psql` local:

```bash
psql -h localhost -U postgres -f 03_scripts/init_database.sql
```

El script es idempotente: se puede ejecutar varias veces sin errores y sin borrar datos.

## 4. Conectarse

```bash
docker compose exec postgres psql -U postgres -d data_warehouse
# o, con psql local:
psql -h localhost -U postgres -d data_warehouse
```

Verificar los esquemas con `\dn`: deben aparecer `bronze`, `silver` y `gold`.

Parámetros para un cliente gráfico: host `localhost`, puerto `5432`, base `data_warehouse`, usuario y contraseña de `.env`.

## Detener y reiniciar

```bash
docker compose down       # detiene y elimina el contenedor, conserva los datos
docker compose down -v    # además elimina el volumen: borra TODOS los datos
```

## Ruta de los CSV para la carga de Bronze

Dentro del contenedor los archivos están en `/datasets`, por lo que la carga es `CALL bronze.load_bronze('/datasets');` (`/datasets` es también el valor por defecto del parámetro).

Orden completo para Bronze:

```bash
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/bronze/ddl_bronze.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/bronze/proc_load_bronze.sql
docker compose exec postgres psql -U postgres -d data_warehouse -c "CALL bronze.load_bronze();"
```

`ddl_bronze.sql` hace `DROP TABLE IF EXISTS`: volver a ejecutarlo vacía las tablas, y hay que recargarlas con el `CALL`.

## Orden completo para Silver

Requiere Bronze cargado. Silver lee solo de Bronze:

```bash
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/silver/ddl_silver.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/silver/proc_load_silver.sql
docker compose exec postgres psql -U postgres -d data_warehouse -c "CALL silver.load_silver();"
docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_silver.sql
```

`ddl_silver.sql` también hace `DROP TABLE IF EXISTS`: volver a ejecutarlo vacía las tablas y hay que recargarlas con el `CALL`. La carga es completa (`TRUNCATE` + `INSERT`) y atómica: si una tabla falla, ninguna queda a medias. Resultado esperado: 18 484, 397, 60 398, 18 484, 18 484 y 37 filas. `test_silver.sql` debe devolver cero filas en cada verificación.

## Orden completo para Gold

Requiere Silver cargado. Gold son solo vistas (sin datos propios), por lo que no hay paso de carga:

```bash
docker compose exec -T postgres psql -U postgres -d data_warehouse -v ON_ERROR_STOP=1 < 03_scripts/gold/ddl_gold.sql
docker compose exec -T postgres psql -U postgres -d data_warehouse < 04_tests/test_gold.sql
```

`ddl_gold.sql` usa `CREATE OR REPLACE VIEW` y es idempotente. Resultado esperado: `dim_customers` 18 484 filas, `dim_products` 295 y `fact_sales` 60 398. `test_gold.sql` debe devolver cero filas en cada verificación. Las claves subrogadas se generan en la vista y no son estables si cambian los datos de origen.

En Git Bash (Windows), si pasas rutas del contenedor como argumento, antepón `MSYS_NO_PATHCONV=1` para que no se conviertan en rutas de Windows. En PowerShell no hace falta, pero el operador `<` no existe: usa `Get-Content archivo.sql | docker compose exec -T postgres psql ...`.
