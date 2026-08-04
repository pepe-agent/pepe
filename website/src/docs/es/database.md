---
title: Base de datos
description: Deja que un agente lea de una base de datos Postgres externa, con la multi-tenencia propia de un cliente aplicada por la propia base de datos, no por el modelo.
---

La herramienta `db_query` deja que un agente ejecute una consulta SQL de solo lectura contra
una base de datos Postgres externa configurada por el operador —datos propios de un cliente,
no el almacén interno de Pepe. **Solo Postgres.** Si esa base de datos tiene su propia
multi-tenencia (una columna al estilo `company_id` que separa los propios clientes de ese
cliente), Pepe vincula el valor de tenant de confianza a la conexión y nunca deja que el
modelo lo vea o lo fije —el aislamiento real lo aplica el propio Postgres, vía Row-Level
Security, no algo que el código de Pepe decida en tiempo de ejecución.

## Por qué el modelo nunca ve el valor del tenant

Un argumento de herramienta que el modelo rellena puede salir mal —por error, o porque una
página o documento que el agente leyó le dijo que usara un valor distinto. Eso no es un fallo
de redacción, es una fuga real de datos entre clientes. Por eso el esquema de la herramienta
`db_query` no tiene ningún parámetro de tenant/`company_id`: el modelo solo aporta
`connection` (un nombre) y `query` (SQL de solo lectura). El valor del tenant viene de la
configuración que puso el operador, se resuelve del lado del servidor, y se aplica a cada
consulta de esa conexión automáticamente.

## Configurar Row-Level Security (haz esto primero)

Esta es la parte que Pepe no puede hacer por ti: la propia base de datos del operador
necesita un rol dedicado y sin privilegios, y una política. Ejecuta algo así una vez, a mano,
en la base de datos objetivo:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- las tablas que el agente deba leer

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Dos cosas importan aquí:

- **`NOBYPASSRLS`, y nunca el dueño de la tabla.** Los superusuarios y los dueños de tabla
  ignoran RLS por defecto, incluso con la política puesta. El rol con el que Pepe se conecta
  tiene que ser un rol ordinario, sin privilegios, para que la política signifique algo.
- **`current_setting('app.pepe_tenant_id', true)`** —este nombre de GUC exacto es la
  convención fija de Pepe, no se configura por conexión. El `true` como segundo argumento
  significa "devuelve `NULL` si no está definido, no des error" —y `company_id = NULL` nunca
  es verdadero en SQL, así que una conexión que de algún modo corra sin el valor definido
  queda sin acceso a nada, no con acceso a todo. Falla cerrado, por construcción.

**Una tabla sin política de RLS no está protegida por esta función en absoluto.** `db_query`
funciona igual contra cada tabla de una conexión; que una tabla en concreto esté realmente
aislada depende por completo de si *esa tabla* tiene una política que funcione. Esto es
deliberado, no un hueco que haya que tapar en Pepe: intentar aplicar el aislamiento de tenant
reescribiendo o validando SQL arbitrario escrito por el agente en el código de la aplicación
no se puede hacer confiable (una cláusula `WITH`, un `JOIN`, un agregado pueden colar una
lectura más allá de una verificación a nivel de texto). Row-Level Security es el único
mecanismo que de verdad se sostiene sin importar cómo esté escrita la consulta, porque actúa
dentro del propio motor de base de datos, no sobre el texto de la consulta.

## Añadir una conexión

La página **Bases de datos** del panel lista las conexiones, muestra si cada una tiene ámbito
de tenant, y tiene un formulario para añadir o quitar una —el campo de la contraseña nunca
viene precargado ni se vuelve a mostrar una vez guardado. Lo mismo desde la CLI:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc

pepe db list
pepe db remove clientes_prod
```

Una conexión sin `--tenant-column` (o con el campo "Columna de tenant" vacío en el panel) no
tiene ámbito —está bien para una base de datos de un solo cliente, sin nada que aislar. Una
con columna de tenant también necesita un modo:

- **`fixed`** —el valor es un literal, p. ej. una conexión por cliente
  (`clientes_prod` arriba siempre es `acme-inc`, sin importar quién pregunte).
- **`agent_field`** —el valor es `"project"` o `"bare"`, resuelto desde el propio
  proyecto o nombre del *agente que llama* en el momento de la consulta —útil cuando una sola
  instalación de Pepe atiende a varios clientes, cada uno mapeado a su propio agente/proyecto.

Un agente también puede gestionar conexiones desde una conversación con la herramienta
`manage_db` (las mismas acciones add/list/remove), y consultar con `db_query` una vez que
tenga ambas herramientas. Las dos son herramientas de riesgo —no están en el conjunto siempre
seguro, y pasan por el aviso de permiso habitual como cualquier otra herramienta que alcanza
hacia afuera.

## Lo que ve el agente

Un resultado de `db_query` vuelve envuelto en el mismo marcador de contenido no confiable que
lleva un resultado de `fetch_url` —es contenido de fuera de la conversación, tratado igual. La
herramienta en sí es solo para Postgres; no hay equivalente para MySQL, SQLite ni ningún otro
motor, porque Row-Level Security (y la garantía de fallo cerrado de arriba) es específica de
Postgres.
