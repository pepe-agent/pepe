---
title: Base de datos
description: Deja que un agente conteste preguntas usando tu propia base de datos Postgres, en modo solo lectura, con los datos de cada cliente separados por la propia base de datos, no por el modelo.
---

La herramienta `db_query` le permite a un agente contestar preguntas
directamente desde tus propios datos: corre consultas SQL de solo lectura contra
una base de datos Postgres externa que configura el operador (los datos de un
cliente, no el almacén interno de Pepe). **Solo Postgres.** Si esa base de datos
ya mezcla las filas de varios clientes en las mismas tablas (una columna al
estilo `company_id` que separa a los clientes de ese cliente entre sí), Pepe ata
el valor de tenant, ya validado, a la conexión, y jamás deja que el modelo lo
vea ni lo modifique. El aislamiento real lo impone el propio Postgres, mediante
Row-Level Security, no una decisión que el código de Pepe tome en tiempo de
ejecución.

## Por qué el modelo nunca ve el valor del tenant

Un argumento que el modelo rellena en una llamada a herramienta se puede
equivocar, ya sea por error o porque una página o documento que el agente leyó
le sugirió otro valor. Eso no es simplemente una redacción que falló: es una
fuga de datos entre clientes. Por eso la especificación de `db_query` no incluye
ningún parámetro de tenant ni de `company_id`: el modelo solo entrega
`connection` (un nombre) y `query` (SQL de solo lectura). El valor del tenant
sale de la configuración que dejó el operador, se resuelve del lado del
servidor, y se aplica automáticamente a cada consulta de esa conexión.

## Configura Row-Level Security antes que nada

Esta es la parte que Pepe no puede hacer por ti: la base de datos del operador
necesita un rol dedicado, sin privilegios, y una política propia. Ejecuta algo
así, a mano y una sola vez, sobre la base de datos de destino:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- las tablas que el agente deba leer

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Dos detalles importan aquí:

- **`NOBYPASSRLS`, y nunca el dueño de la tabla.** Por defecto, los superusuarios
  y los dueños de tabla ignoran RLS aunque la política ya esté puesta. Para que
  esa política signifique algo, el rol con el que Pepe se conecta tiene que ser
  uno común, sin privilegios especiales.
- **`current_setting('app.pepe_tenant_id', true)`**: este nombre exacto es una
  convención fija de Pepe, no algo que se configure por conexión. El `true`
  como segundo argumento le dice a Postgres que devuelva `NULL` si el valor no
  está definido en lugar de fallar, y como `company_id = NULL` nunca es
  verdadero en SQL, una conexión que por algún motivo corra sin ese valor
  definido termina sin acceso a nada, no con acceso a todo. Falla cerrado por
  diseño.

**Una tabla sin política de RLS queda totalmente fuera de esta protección.**
`db_query` corre igual contra cualquier tabla de una conexión, así que si una
tabla en particular está de verdad aislada depende solo de si esa tabla tiene
una política que funcione. Esto es intencional, no un hueco que Pepe deba
tapar: intentar imponer el aislamiento de tenant reescribiendo o validando en
la propia aplicación el SQL arbitrario que escribe un agente nunca puede
hacerse confiable (un `WITH`, un `JOIN`, un agregado, cualquiera de esos puede
colar una lectura más allá de un chequeo a nivel de texto). Row-Level Security
es el único mecanismo que de verdad se sostiene sin importar cómo esté escrita
la consulta, porque actúa dentro del propio motor de base de datos y no sobre
el texto de la consulta.

## Agregar una conexión

La página **Databases** del panel lista las conexiones, muestra si cada una
tiene ámbito de tenant, y trae un formulario para agregar o quitar una; el
campo de contraseña nunca se precarga ni vuelve a mostrarse una vez guardado.
Lo mismo se puede hacer desde la CLI:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc
```

```bash
pepe db list
pepe db remove clientes_prod
```

Una conexión sin `--tenant-column` (o con el campo "Tenant column" vacío en el
panel) queda sin ámbito, lo cual está bien para una base de datos que de
entrada solo guarda los datos de un cliente y no tiene nada que aislar. Una que
sí tiene columna de tenant necesita además un modo:

- **`fixed`**: el valor es literal, pensado para una conexión por cliente (en
  el ejemplo de arriba, `clientes_prod` siempre es `acme-inc`, pregunte quien
  pregunte).
- **`agent_field`**: el valor es `"project"` o `"bare"`, y se resuelve a partir
  del propio proyecto o handle del *agente que hace la llamada*, en el momento
  de la consulta. Útil cuando una sola instalación de Pepe atiende a varios
  clientes, cada uno mapeado a su propio agente o proyecto.

Un agente también puede gestionar conexiones desde la conversación con la
herramienta `manage_db` (las mismas acciones de agregar, listar y quitar), y
consultar con `db_query` en cuanto tenga las dos herramientas habilitadas.
Ambas son herramientas riesgosas: no forman parte del conjunto siempre seguro,
así que cada llamada pasa por el mismo aviso de permiso que cualquier otra
herramienta que sale hacia afuera.

## Lo que llega a ver el agente

Un resultado de `db_query` vuelve envuelto en el mismo marcador de contenido no
confiable que trae un resultado de `fetch_url`: son datos que vienen de fuera
de la conversación, y se tratan igual. La herramienta en sí es exclusiva de
Postgres, no existe un equivalente para MySQL, SQLite ni ningún otro motor,
porque tanto Row-Level Security como la garantía de fallo cerrado de arriba son
propias de Postgres.
