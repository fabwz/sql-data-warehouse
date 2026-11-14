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

Dentro del contenedor los archivos están en `/datasets`, por lo que la carga será `CALL bronze.load_bronze('/datasets');`.
