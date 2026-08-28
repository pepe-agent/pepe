---
title: Facturación y límites
description: Mide cada llamada al modelo por proyecto, ponle precio, aplica un margen a lo que facturas, limita el gasto o el volumen de mensajes al mes, y exporta la factura de un cliente.
---

## Cuánto cuesta una llamada

Cada llamada al modelo se mide y se atribuye al proyecto del agente, así que
puedes facturarle a un cliente por token. Ninguna superficie escapa a esta
medición: la consola, la API HTTP `/v1`, el WebSocket, Telegram y todos los
canales por webhook pasan por el mismo punto. Cada llamada se agrega a un
ledger que nunca se reescribe, guardado en el mismo pequeño archivo SQLite
embebido donde viven los compromisos, las vigilancias y los traces, y
agrupado por proyecto (por ejemplo, `default`). Ese es el rastro de auditoría
de todo lo que se cobra.

El **costo** es `tokens × el precio del modelo`, cotizado por cada millón de
tokens. Un precio se resuelve en capas, y gana la primera que responde:

1. El **precio manual** definido en la conexión del modelo.
2. Una **caché en vivo** en `~/.pepe/data/price_book.json`, que se actualiza
   desde OpenRouter y el mapa de precios de LiteLLM.
3. Una **semilla incorporada** de precios conocidos, que sirve de respaldo sin
   conexión.

Así, un modelo conocido ya viene con precio de manera automática, y solo
escribes uno cuando quieres sobrescribirlo o cuando falta. Define precios por
modelo desde Models, luego Edit, en el panel, o actualiza tú mismo la caché en
vivo:

```bash
pepe usage prices --refresh
```

Los precios también se actualizan solos una vez por semana mientras `serve` o
alguna pasarela estén corriendo.

**El importe a facturar** es `precio de lista × el margen del proyecto`, el
multiplicador opcional por proyecto que se describe más abajo. Lo que pagaste
y lo que facturas siempre se muestran uno junto al otro, así que un margen
nunca le esconde el costo real a tu propio equipo.

## Suscripciones (ChatGPT Plus, Claude Max)

Una conversación que corre sobre el login de una suscripción no cuesta nada
por token: el mes ya se pagó por adelantado, mandes un mensaje o mandes diez
mil. Aun así, vale exactamente lo mismo para el cliente que una conversación
que corrió sobre la API de pago, así que Pepe lleva tres números en vez de
dos.

| Número | Qué significa |
|---|---|
| **Lista** | `tokens × el precio del modelo`. Lo que esos tokens habrían costado en la API, los haya costado de verdad o no. |
| **A facturar** | `lista × margen`. Lo que paga el cliente, calculado a partir del precio de lista y **no** de lo que gastaste realmente. |
| **Costo** | Lo que de verdad pagaste tú. Cero para los tokens que cubrió una suscripción, más la cuota mensual fija de esa suscripción, contada una sola vez. |

Facturar a partir del precio de lista es justamente el punto de todo esto. La
suscripción va a caducar algún día, y ese mismo trabajo pasará a correr sobre
la API de pago; ese día, la factura del cliente no debe moverse ni un poco. Un
precio que sigue tus propios acuerdos de suministro es un precio que después
tienes que andar explicando.

Dile a Pepe cuánto te cuesta una suscripción y el margen sale correcto:

```json
{
  "models": {
    "claude-max": {
      "oauth": { "provider": "anthropic" },
      "monthly_cost": 100
    }
  }
}
```

El bloque `oauth` lo escribe por ti `pepe model login`. `monthly_cost` es lo
que esa suscripción te cuesta cada mes. Si dejas `monthly_cost` sin definir, la
cuota simplemente nunca aparece descontada del margen, lo que convierte el
margen informado en un límite superior optimista, no en un número incorrecto.
`pepe doctor` te lo hace notar.

Si una llamada corrió sobre una suscripción se decide **en el momento en que se
registra**, no cuando se lee el ledger después. Cambia una conexión de un
login a una clave de API, y las entradas del mes pasado van a seguir
significando exactamente lo mismo que significaban.

## Facturación y límites

Cada llamada al modelo se mide por proyecto (consulta Agentes para ver qué es
un proyecto y cómo crear uno). Además de esa medición, un proyecto puede
llevar, opcionalmente, dos topes mensuales independientes, más un margen de
facturación:

- **Tope de gasto** (`--budget`): un límite estricto en tu moneda configurada.
  En cuanto el total facturable del mes en curso lo alcanza, los agentes de
  ese proyecto dejan de hacer llamadas nuevas al modelo hasta que el tope se
  reinicie.
- **Tope de mensajes** (`--message-limit`): un límite estricto sobre los
  mensajes que originan los clientes. En cuanto se alcanza, los agentes de ese
  proyecto dejan de responder a mensajes entrantes nuevos hasta que se
  reinicie.
- **Margen** (`--markup`): un multiplicador que se aplica sobre el costo del
  proveedor para obtener lo que le cobras al cliente (por ejemplo, `1.3`
  equivale al costo del proveedor más un 30%). Sin definir, facturas
  exactamente el costo del proveedor.

Los tres son opcionales e independientes entre sí: puedes definir cualquiera
de ellos, todos, o ninguno. El proyecto por defecto lleva los mismos topes que
cualquier otro, y se configuran con `pepe project set default ...` (o con el
nombre que le hayas puesto).

### Qué cuenta para el tope de mensajes

El tope de mensajes cuenta **un mensaje del cliente, una sola vez**, sin
importar cuántas llamadas al modelo hicieron falta para responderlo. Si un
agente llama a tres herramientas antes de contestar, eso sigue siendo un solo
mensaje contra el tope, igual que es un solo mensaje dentro del chat. Las
iteraciones del ciclo de llamadas a herramientas, las ejecuciones de cron, los
mensajes de agente a agente y los heartbeats nunca cuentan.

Solo se cuentan los mensajes que llegan por superficies orientadas al
cliente: Telegram, WhatsApp y el resto de los canales por webhook, o el widget
incrustable. Deliberadamente quedan fuera la consola de `pepe chat`, el chat de
prueba propio del panel y la API HTTP, porque en esos casos es el propio
operador usando su runtime, no un cliente escribiéndole.

Un agente en particular puede quedar exento del tope de mensajes por
completo, lo que resulta útil para algo como un agente de escalamiento que
siempre debe seguir activo, aunque el resto del proyecto ya haya llegado a su
tope:

```bash
pepe agent add escalation --exempt-message-limit
```

Por ahora no hay forma de activar esa opción por CLI en un agente que ya
existe sin tocar el resto de su configuración, porque `agent add` reemplaza
toda la definición del agente en vez de corregir un solo campo. Cámbialo, en
cambio, desde la página de edición del agente en el panel.

### Configurar los topes

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

`project set` solo toca las opciones que le pases; el resto de la
configuración del proyecto queda intacta. Pasa `none` para borrar un tope:

```bash
pepe project set acme --budget none
```

Los mismos campos se pueden editar desde la página Projects del panel.

### Reiniciar un tope antes de tiempo

Un tope se reinicia solo, de forma natural, al comenzar cada mes de
facturación, pero no hace falta esperar a eso:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

La página Projects del panel tiene los mismos dos botones junto a la insignia
de cada tope, con una confirmación que muestra el conteo actual antes de
reiniciar.

Un reinicio no borra nada, solo marca un punto de corte. El gasto o los
mensajes registrados antes del reinicio se quedan en el ledger; simplemente
dejan de contar para el tope de ahí en adelante. Esto importa por un motivo
concreto: **la insignia del tope de gasto y su botón de reinicio solo afectan
el conteo operativo que se usa para bloquear llamadas nuevas al modelo.** El
registro de facturación real del mes, el que le facturarías a un cliente,
vive en Usage y siempre refleja el total verdadero, se haya reiniciado el tope
o no. Si reinicias el tope de gasto de un proyecto a mitad de mes, la insignia
de la página Projects va a mostrar un número menor que el de la página Usage
para ese mismo mes; eso es lo esperado, no una inconsistencia, porque cada una
responde una pregunta distinta ("¿se limitó este proyecto desde el último
reinicio?" contra "¿cuánto le costó de verdad este proyecto este mes?").

## Saldos prepago (dinero real acreditado, no un tope mensual)

El tope de gasto de arriba se reinicia solo cada mes: es un freno, no es
dinero. Un **saldo prepago** es otra cosa: fondos reales que se acreditan (un
pago recibido, o una carga hecha a mano), que se van consumiendo con el gasto
facturable real, y que rechazan llamadas nuevas al modelo en cuanto llegan a
cero, quedando así hasta que se recargan. Es útil para operar Pepe como un
servicio de pago: el agente de un cliente funciona hasta que se le acaba lo
que pagó, no hasta que cambia el mes en el calendario.

Un proyecto al que nunca se le acreditó nada queda completamente sin cambios:
solo se le aplica el tope de gasto de arriba, exactamente como si esto no
existiera. En el momento en que algo acredita a un proyecto, pasa a existir un
saldo para él, y ahí sí se aplican los dos frenos a la vez: tanto el tope de
gasto como el saldo llegando a cero detienen las llamadas nuevas.

```bash
pepe project credit acme 50          # agrega $50 (o la moneda que tengas configurada)
pepe project balance acme            # muestra el saldo actual
```

La página de Proyectos del panel muestra una insignia de saldo (azul, o roja
una vez agotado) junto a la insignia del tope de gasto del proyecto, en cuanto
se le acreditó algo por primera vez.

### Acreditarlo automáticamente desde un pago

Un webhook genérico, que no depende de ningún procesador en particular,
acredita un saldo a partir de cualquier procesador de pagos: es una decisión
deliberada no atarlo al SDK ni al esquema de firma de un procesador
específico. Apunta hacia él el manejador de webhooks de tu propio procesador
de pagos (una función relay pequeña, un paso de Zapier o Make, o directamente
si el procesador te permite fijar un bearer token estático) una vez que ese
procesador ya haya verificado el pago de su lado:

```bash
pepe project webhook-secret TU_SECRETO

curl -X POST https://TU_HOST/webhooks/balance/acme \
  -H "Authorization: Bearer TU_SECRETO" \
  -d '{"amount": 10}'
```

Hay un único secreto para el endpoint de saldo de todos los proyectos: la
idea es que se quede en tu propio relay o automatización, no que se lo entregues
a un tercero por cada cliente. El endpoint rechaza cualquier petición (404)
mientras no se defina un secreto; `pepe project webhook-secret --clear` lo
vuelve a desactivar.

## Leer el consumo y exportar facturas

```bash
pepe usage                                   # todos los proyectos, por mes, por proyecto
pepe usage --project acme --granularity day  # un proyecto, por día
pepe usage export --project acme             # una factura de cliente (Markdown, o --format csv)
pepe usage prices --refresh                  # actualiza la caché de precios en vivo
pepe usage help                              # el recorrido completo
```

`usage export` convierte el mes de un proyecto en una factura de cliente, en
Markdown o en CSV. Un agente puede hacer lo mismo por su cuenta con la
herramienta `export_invoice`, así que una tarea programada mensual puede
exportar la factura de cada cliente y enviarla, usando al propio Pepe para
facturar su propio uso.

En el panel, la sección Usage & billing muestra tokens, costo e importe a
facturar por ciclo (hora, día, semana, mes, año), con desgloses por proyecto,
modelo y agente. Los precios por modelo se definen desde Models, luego Edit;
el margen de un proyecto, desde Projects, luego Edit.

La moneda es solo una etiqueta. Por defecto es `USD`, y la cambias definiendo
`"currency"` en `config.json`. No hay ninguna conversión de divisas, así que
el número queda en la moneda en la que tu proveedor cotiza sus propios
precios.

En el panel, esa misma página termina con una tabla **Por mensaje**: una fila
por cada mensaje entrante, con las herramientas que ejecutó, cuántas llamadas
al modelo le costó, cuánto duró y cuánto costó. Haz clic en una fila para ver
esas llamadas una por una. Esa misma vista es `pepe usage runs`, y
`pepe usage runs <id>` para un solo mensaje. Un informe por ciclo cuenta
llamadas al modelo, así que nunca puede mostrar este nivel de detalle: lo que
encarece un mensaje es su número de llamadas, no su número de herramientas,
porque cada iteración vuelve a enviar un contexto que el resultado de la
herramienta anterior acaba de hacer más grande.

Las mismas cifras también se pueden leer por HTTP, desde el sistema de
facturación del propio cliente, con un token creado solo para leer y nada más:
consulta la [API de consumo](../usage-api/). Ahí se baja un nivel más de
detalle que en la factura, hasta lo que costó un solo mensaje y qué
herramientas ejecutó.
