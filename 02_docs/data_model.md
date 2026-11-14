# Modelo de datos (Gold)

Esquema en estrella: una tabla de hechos (`fact_sales`) rodeada de dos dimensiones (`dim_customers` y `dim_products`). Los tres objetos son **vistas** del esquema `gold`, por lo que las claves y relaciones que se muestran son lógicas: la base de datos no define restricciones sobre ellas.

```mermaid
erDiagram
    dim_customers ||--o{ fact_sales : "customer_key"
    dim_products  ||--o{ fact_sales : "product_key"

    dim_customers {
        bigint  customer_key PK "clave subrogada"
        integer customer_id "clave de negocio (CRM)"
        varchar customer_number "cst_key, enlaza con el ERP"
        varchar first_name
        varchar last_name
        varchar country
        varchar marital_status
        varchar gender
        date    birthdate
        date    create_date
    }

    dim_products {
        bigint  product_key PK "clave subrogada"
        integer product_id
        varchar product_number "clave de negocio, enlaza con las ventas"
        varchar product_name
        varchar category_id
        varchar category
        varchar subcategory
        varchar maintenance
        integer cost
        varchar product_line
        date    start_date
    }

    fact_sales {
        varchar order_number
        bigint  product_key FK
        bigint  customer_key FK
        date    order_date
        date    shipping_date
        date    due_date
        numeric sales_amount
        integer quantity
        numeric price
    }
```

## Granularidad de la tabla de hechos

Cada fila de `fact_sales` es **una línea de pedido**: un producto dentro de un pedido. La combinación `order_number` + `product_key` es única (verificado en `04_tests/test_gold.sql`). Un mismo pedido puede tener varias filas, una por producto.

Medidas: `sales_amount`, `quantity` y `price`. Se cumple siempre `sales_amount = quantity * price`. `sales_amount` es aditivo y se puede sumar por cualquier dimensión; `price` es un precio unitario y no se debe sumar, solo promediar o comparar.

Fechas: `order_date`, `shipping_date` y `due_date`. Son atributos de la tabla de hechos; no hay una dimensión de fechas.

## Granularidad de las dimensiones

| Dimensión | Una fila por | Filas |
|-----------|--------------|-------|
| `dim_customers` | Cliente (`customer_id`) | 18 484 |
| `dim_products` | Producto vigente (`product_number`). No hay historial de versiones. | 295 |

## Relaciones

| Hechos | Dimensión | Cardinalidad | Unión (definida en la vista `fact_sales`) |
|--------|-----------|--------------|-------------------------------------------|
| `fact_sales.customer_key` | `dim_customers.customer_key` | Muchas ventas por cliente | `sls_cust_id = customer_id` |
| `fact_sales.product_key` | `dim_products.product_key` | Muchas ventas por producto | `sls_prd_key = product_number` |

Las claves subrogadas (`customer_key`, `product_key`) se generan dentro de la vista con `ROW_NUMBER()` y **no son estables**: pueden cambiar si cambian los datos de origen. No se deben guardar fuera del almacén. Para enlazar con otros sistemas se usan las claves de negocio (`customer_id`, `customer_number`, `product_number`).

Descripción de cada columna: [`data_catalog.md`](data_catalog.md).
