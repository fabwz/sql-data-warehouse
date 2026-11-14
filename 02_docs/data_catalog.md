# Catálogo de datos: capa Gold

Catálogo para usuarios de negocio y analistas. Describe las tres vistas del esquema `gold`. Los tipos de dato se tomaron de la base (`information_schema.columns`) y los orígenes, de `03_scripts/gold/ddl_gold.sql`.

Convenciones que aplican a todas las vistas:

- Cuando un dato de texto es desconocido se muestra `'n/a'`. Los nombres y apellidos desconocidos se dejan en `NULL`.
- El CRM es la fuente maestra; el ERP complementa. Si hay conflicto, manda el CRM.
- Las claves `customer_key` y `product_key` son claves técnicas generadas en la vista y **no son estables**: no las guarde fuera del almacén. Use las claves de negocio.
- Las columnas "Origen" indican la tabla y columna de `silver` de donde sale el dato. Silver ya contiene los datos depurados; ver [`data_quality_rules.md`](data_quality_rules.md).

Resumen:

| Vista | Tipo | Filas | Granularidad |
|-------|------|-------|--------------|
| `gold.dim_customers` | Dimensión | 18 484 | Un cliente |
| `gold.dim_products` | Dimensión | 295 | Un producto (versión vigente) |
| `gold.fact_sales` | Hechos | 60 398 | Una línea de pedido |

---

## gold.dim_customers

**Propósito:** lista única de clientes con sus datos personales y de ubicación. Combina el CRM (identidad, estado civil, género) con el ERP (fecha de nacimiento, país).

**Granularidad:** una fila por cliente (`customer_id` es único).

| Columna | Tipo de dato | Descripción | Origen |
|---------|--------------|-------------|--------|
| `customer_key` | `bigint` | Clave técnica del cliente. Es la que usa `fact_sales`. | Regla: `ROW_NUMBER() OVER (ORDER BY cst_id)` |
| `customer_id` | `integer` | Identificador del cliente en el CRM. Clave de negocio. | `silver.crm_cust_info.cst_id` |
| `customer_number` | `character varying` | Código alfanumérico del cliente (formato `AW########`). Es el que lo enlaza con el ERP. | `silver.crm_cust_info.cst_key` |
| `first_name` | `character varying` | Nombre. Puede ser `NULL` si no se registró. | `silver.crm_cust_info.cst_firstname` |
| `last_name` | `character varying` | Apellido. Puede ser `NULL` si no se registró. | `silver.crm_cust_info.cst_lastname` |
| `country` | `character varying` | País de residencia, con el nombre completo (por ejemplo `United States`, `Germany`). `'n/a'` si el ERP no lo informa. | `silver.erp_loc_a101.cntry`, unido por `cst_key = cid`. Regla: `COALESCE(cntry, 'n/a')` |
| `marital_status` | `character varying` | Estado civil: `Married` o `Single` (`'n/a'` si se desconoce). | `silver.crm_cust_info.cst_marital_status` |
| `gender` | `character varying` | Género: `Male`, `Female` o `'n/a'`. | Regla: si `silver.crm_cust_info.cst_gndr` es distinto de `'n/a'`, se usa ese valor (el CRM manda). Si es `'n/a'`, se usa `silver.erp_cust_az12.gen` como respaldo; si tampoco hay dato, `'n/a'`. |
| `birthdate` | `date` | Fecha de nacimiento. `NULL` si no se conoce o si la fecha original era futura (inválida). | `silver.erp_cust_az12.bdate`, unido por `cst_key = cid` |
| `create_date` | `date` | Fecha en que se creó el cliente en el CRM. | `silver.crm_cust_info.cst_create_date` |

Notas de uso:

- Hay 57 clientes con género distinto entre CRM y ERP; en esos casos se muestra el del CRM.
- El respaldo del ERP completa el género de 4 554 clientes que el CRM no informaba. Después de esto quedan 15 clientes con `'n/a'`.
- 337 clientes tienen país `'n/a'` (871 líneas de venta). 16 clientes no tienen fecha de nacimiento.
- Se conservan fechas de nacimiento anteriores a 1924 (15 casos) tal como vienen del origen; revíselas antes de calcular edades.

---

## gold.dim_products

**Propósito:** catálogo de productos vigentes con su categoría, subcategoría, costo y línea.

**Granularidad:** una fila por producto (`product_number` es único). Solo se incluye la **versión vigente** de cada producto; las versiones históricas no están en Gold.

| Columna | Tipo de dato | Descripción | Origen |
|---------|--------------|-------------|--------|
| `product_key` | `bigint` | Clave técnica del producto. Es la que usa `fact_sales`. | Regla: `ROW_NUMBER() OVER (ORDER BY prd_start_dt, prd_key)` |
| `product_id` | `integer` | Identificador de la versión vigente del producto en el CRM. | `silver.crm_prd_info.prd_id` |
| `product_number` | `character varying` | Código del producto, sin el prefijo de categoría. Clave de negocio; es el que usan las ventas. | `silver.crm_prd_info.prd_key` |
| `product_name` | `character varying` | Nombre del producto. | `silver.crm_prd_info.prd_nm` |
| `category_id` | `character varying` | Código de la categoría (con guion bajo, por ejemplo `CO_RF`). | `silver.crm_prd_info.cat_id` (derivado de los primeros 5 caracteres de la clave original) |
| `category` | `character varying` | Categoría: `Bikes`, `Components`, `Clothing` o `Accessories`. `'n/a'` si la categoría no está en el catálogo del ERP. | `silver.erp_px_cat_g1v2.cat`, unido por `cat_id = id`. Regla: `COALESCE(cat, 'n/a')` |
| `subcategory` | `character varying` | Subcategoría del producto. `'n/a'` si no hay match. | `silver.erp_px_cat_g1v2.subcat`. Regla: `COALESCE(subcat, 'n/a')` |
| `maintenance` | `character varying` | Indica si el producto requiere mantenimiento: `Yes` o `No` (`'n/a'` si no hay match). | `silver.erp_px_cat_g1v2.maintenance`. Regla: `COALESCE(maintenance, 'n/a')` |
| `cost` | `integer` | Costo del producto. `NULL` si se desconoce (no significa cero). | `silver.crm_prd_info.prd_cost` |
| `product_line` | `character varying` | Línea de producto: `Road`, `Mountain`, `Touring`, `Other Sales` o `'n/a'`. | `silver.crm_prd_info.prd_line` |
| `start_date` | `date` | Fecha desde la que rige la versión vigente del producto. | `silver.crm_prd_info.prd_start_dt` |

Notas de uso:

- Regla de vigencia: `WHERE prd_end_dt IS NULL`. En Silver cada producto tiene una sola versión sin fecha de fin.
- 7 productos de la categoría `CO_PE` no existen en el catálogo del ERP, por eso su categoría, subcategoría y mantenimiento son `'n/a'`.
- 2 productos no tienen costo (`cost` es `NULL`).

---

## gold.fact_sales

**Propósito:** registro de las ventas, con sus importes y fechas, enlazado a las dimensiones de clientes y productos.

**Granularidad:** una fila por línea de pedido (producto dentro de un pedido). La combinación `order_number` + `product_key` es única; un pedido puede tener varias filas.

| Columna | Tipo de dato | Descripción | Origen |
|---------|--------------|-------------|--------|
| `order_number` | `character varying` | Número de pedido. Se repite si el pedido tiene varios productos. | `silver.crm_sales_details.sls_ord_num` |
| `product_key` | `bigint` | Producto vendido. Referencia a `dim_products.product_key`. | Regla: `gold.dim_products.product_key`, unido por `sls_prd_key = product_number` |
| `customer_key` | `bigint` | Cliente que compró. Referencia a `dim_customers.customer_key`. | Regla: `gold.dim_customers.customer_key`, unido por `sls_cust_id = customer_id` |
| `order_date` | `date` | Fecha del pedido. Si el origen no la traía o era inválida (19 líneas), se calcula como fecha de envío menos 7 días. | `silver.crm_sales_details.sls_order_dt` |
| `shipping_date` | `date` | Fecha de envío. | `silver.crm_sales_details.sls_ship_dt` |
| `due_date` | `date` | Fecha de vencimiento del pedido. | `silver.crm_sales_details.sls_due_dt` |
| `sales_amount` | `numeric(12,2)` | Importe de la línea. Siempre es `quantity * price`. | `silver.crm_sales_details.sls_sales` |
| `quantity` | `integer` | Unidades vendidas. | `silver.crm_sales_details.sls_quantity` |
| `price` | `numeric(12,2)` | Precio unitario, siempre positivo. Si el origen no lo traía, se calcula como importe / cantidad. | `silver.crm_sales_details.sls_price` |

Notas de uso:

- Las ventas van de 2010-12-29 a 2014-01-28 (por fecha de pedido).
- `sales_amount` se puede sumar por cualquier dimensión; `price` no.
- No hay ventas sin cliente ni sin producto (`customer_key` y `product_key` nunca son `NULL`).
- El total de `sales_amount` coincide con el total de importes de Silver.

---

## Ejemplos de consultas analíticas

### 1. Ventas y unidades por año y categoría

```sql
SELECT EXTRACT(YEAR FROM f.order_date)::int AS order_year,
       p.category,
       SUM(f.sales_amount) AS total_sales,
       SUM(f.quantity)     AS units_sold
FROM gold.fact_sales f
JOIN gold.dim_products p ON p.product_key = f.product_key
GROUP BY 1, 2
ORDER BY 1, total_sales DESC;
```

### 2. Ventas por país y venta promedio por cliente

```sql
SELECT c.country,
       COUNT(DISTINCT c.customer_key) AS customers,
       SUM(f.sales_amount)            AS total_sales,
       ROUND(SUM(f.sales_amount) / COUNT(DISTINCT c.customer_key), 2) AS sales_per_customer
FROM gold.fact_sales f
JOIN gold.dim_customers c ON c.customer_key = f.customer_key
GROUP BY c.country
ORDER BY total_sales DESC;
```

### 3. Pedidos e importe por línea de producto y género

```sql
SELECT p.product_line,
       c.gender,
       COUNT(DISTINCT f.order_number) AS orders,
       SUM(f.sales_amount)            AS total_sales
FROM gold.fact_sales f
JOIN gold.dim_products  p ON p.product_key  = f.product_key
JOIN gold.dim_customers c ON c.customer_key = f.customer_key
WHERE c.gender <> 'n/a'
GROUP BY p.product_line, c.gender
ORDER BY p.product_line, c.gender;
```

Las tres consultas se ejecutaron contra la base de datos. Por ejemplo, la segunda devuelve `United States` con 7 482 clientes y 9 162 327,00 en ventas, y `Australia` con 3 591 clientes y 9 060 172,00.
