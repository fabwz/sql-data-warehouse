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

* **Motor:** PostgreSQL 15 o superior
* **Lenguaje:** SQL y PL/pgSQL
* **Carga:** `COPY` desde archivos CSV
* **Cliente:** `psql`
* **Control de versiones:** Git, con Conventional Commits

## Arquitectura

Una sola base de datos con un esquema por capa. Los esquemas permiten consultar entre capas, algo que no es posible con bases de datos separadas en PostgreSQL.

```
 Fuentes              Data Warehouse (PostgreSQL)                    Consumo
┌─────────┐   ┌──────────┐    ┌──────────┐    ┌──────────┐   ┌───────────────────┐
│ CRM CSV │   │  bronze  │    │  silver  │    │   gold   │   │ BI y reportes     │
│         │──▶│ datos    │──▶ │ datos    │──▶ │ datos    │──▶│ Consultas SQL     │
│ ERP CSV │   │ originales    │ depurados│    │ analíticos   │ Machine learning  │
└─────────┘   └──────────┘    └──────────┘    └──────────┘   └───────────────────┘
               tablas          tablas          vistas
               truncate+copy   truncate+insert estrella
```

|Capa|Esquema|Objeto|Carga|Transformación|Modelado|Público|
|-|-|-|-|-|-|-|
|Bronze|`bronze`|Tablas|Completa (truncate + copy)|Ninguna|Ninguno|Ingenieros de datos|
|Silver|`silver`|Tablas|Completa (truncate + insert)|Limpieza, estandarización, normalización, columnas derivadas, enriquecimiento|Ninguno|Analistas e ingenieros de datos|
|Gold|`gold`|Vistas|No aplica|Integración, agregaciones, reglas de negocio|Esquema en estrella|Analistas y usuarios de negocio|

### Flujo de carga

1. `bronze.load\_bronze()` vacía cada tabla y la carga desde su CSV con `COPY`, sin transformar.
2. `silver.load\_silver()` vacía cada tabla, lee de Bronze y aplica la limpieza y las columnas derivadas.
3. Las vistas de `gold` leen de Silver y se actualizan solas al cambiar los datos subyacentes.

Cada procedimiento se ejecuta en una transacción y reporta filas cargadas y duración por tabla. Si una tabla falla, la carga se revierte completa.

## Fuentes de datos

|Sistema|Tabla|Contenido|
|-|-|-|
|CRM|`crm\_cust\_info`|Información de clientes|
|CRM|`crm\_prd\_info`|Productos, vigentes e históricos|
|CRM|`crm\_sales\_details`|Transacciones de ventas y pedidos|
|ERP|`erp\_cust\_az12`|Datos adicionales del cliente (fecha de nacimiento)|
|ERP|`erp\_loc\_a101`|Ubicación del cliente (país)|
|ERP|`erp\_px\_cat\_g1v2`|Categorías de productos|

Relaciones entre fuentes:

```
crm\_sales\_details ──(prd\_key)──▶ crm\_prd\_info ──(prd\_key)──▶ erp\_px\_cat\_g1v2
        │
     (cst\_id)
        ▼
  crm\_cust\_info ──(cst\_key)──▶ erp\_cust\_az12
                       └─────▶ erp\_loc\_a101
```

## Modelo analítico (Gold)

Esquema en estrella con una tabla de hechos y dos dimensiones.

|Vista|Tipo|Descripción|
|-|-|-|
|`gold.dim\_customers`|Dimensión|Clientes del CRM enriquecidos con datos del ERP|
|`gold.dim\_products`|Dimensión|Productos del CRM con su categoría del ERP|
|`gold.fact\_sales`|Hechos|Transacciones de venta, referenciadas a las claves subrogadas de las dimensiones|

El diagrama del modelo y el catálogo de datos estarán en `02\_docs/`.

## Calidad de datos

* Cada tabla de Bronze se perfila antes de escribir su transformación en Silver: duplicados, nulos, espacios sobrantes, valores fuera de dominio y fechas inválidas.
* Cada problema encontrado y su tratamiento se documenta en el script de Silver correspondiente.
* Las pruebas de `04\_tests/` son consultas que devuelven filas solo cuando detectan un problema. Un resultado vacío indica que la verificación pasó.

## Estructura del repositorio

```
.
├── 00\_setup/       Guía de configuración
├── 01\_datasets/    Archivos CSV de origen
│   ├── source\_crm/
│   └── source\_erp/
├── 02\_docs/        Requisitos, diagramas y catálogo de datos
├── 03\_scripts/     Scripts SQL
│   ├── init\_database.sql
│   ├── bronze/
│   ├── silver/
│   └── gold/
└── 04\_tests/       Pruebas de calidad de Silver y Gold
```

## Requisitos

* PostgreSQL 15 o superior
* `psql`
* Git
* Acceso del servidor de Postgres a los archivos de `01\_datasets/`. `COPY` lee los archivos desde el servidor, no desde el cliente. Si Postgres corre en un contenedor, hay que montar esa carpeta como volumen.

## Puesta en marcha

1. Clonar el repositorio y verificar que los CSV estén en `01\_datasets/`.
2. Crear la base de datos y los esquemas:

```bash
   psql -U postgres -f 03\_scripts/init\_database.sql
   ```

3. Cargar las capas, en orden:

```sql
   CALL bronze.load\_bronze('<ruta\_datasets>');
   CALL silver.load\_silver();
   ```

4. Ejecutar las pruebas:

```bash
   psql -U postgres -d <database> -f 04\_tests/test\_silver.sql
   psql -U postgres -d <database> -f 04\_tests/test\_gold.sql
   ```

5. Consultar el modelo analítico en el esquema `gold`.

Los scripts y la guía detallada de `00\_setup/` se completan a medida que avanza el proyecto.

## Convenciones

**Nombres de objetos**

|Elemento|Convención|Ejemplo|
|-|-|-|
|General|`snake\_case`, minúsculas, inglés|`sales\_amount`|
|Tablas Bronze y Silver|`<sistema>\_<entidad>`, igual que el origen|`crm\_cust\_info`|
|Vistas Gold|`dim\_<entidad>`, `fact\_<entidad>`|`dim\_customers`|
|Claves subrogadas|`<entidad>\_key`|`customer\_key`|
|Columnas técnicas|prefijo `dwh\_`|`dwh\_create\_date`|
|Procedimientos|`load\_<capa>`|`silver.load\_silver()`|

**Commits**

Conventional Commits con el formato `type(scope): description`.

* Tipos: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`
* Scopes: `setup`, `bronze`, `silver`, `gold`, `tests`, `docs`
* Ejemplo: `feat(bronze): add ddl for crm tables`

