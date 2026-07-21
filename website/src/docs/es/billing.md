---
title: Facturación y límites
description: Mide cada llamada al modelo por proyecto, ponle precio, aplica un margen a lo que facturas, limita el gasto o el volumen de mensajes mensual, y exporta la factura del cliente.
---

## Cuánto cuesta una llamada

Cada llamada al modelo se mide y se atribuye al proyecto del agente, así puedes facturarle a un cliente por token. La medición ocurre en el único punto por el que pasan todas las superficies (la consola, la API HTTP `/v1`, el WebSocket, Telegram y todos los canales por webhook), y se va anexando a un ledger duradero, de solo adición, en el mismo pequeño archivo SQLite embebido que los compromisos, las vigilancias y los traces, agrupado por proyecto (p. ej. `default`). Ese es el rastro de auditoría de lo que se cobra. ¿Actualizas desde un Pepe más antiguo que lo escribía como un archivo JSONL por proyecto por mes bajo `~/.pepe/data/usage/<slug>/YYYY-MM.jsonl`? Ejecuta `mix pepe config migrate-data` una vez para traer las entradas antiguas - los archivos de origen se dejan intactos, no se borran, así que puedes eliminar ese directorio a mano una vez que confirmes la importación.

El **coste** es `tokens × el precio del modelo`, cotizado por cada 1M de tokens. Un precio se resuelve por capas, y gana la primera capa que responde:

1. El **precio manual** definido en la conexión del modelo.
2. Una **caché en vivo** en `~/.pepe/data/price_book.json`, actualizada desde OpenRouter y el mapa de precios de LiteLLM.
3. Una **semilla incorporada** de precios conocidos, que es la salida sin conexión.

Así un modelo conocido ya queda con precio automáticamente, y solo escribes un precio para sobrescribir alguno o para rellenar un hueco. Define precios por modelo en Models, luego Edit, en el panel, o actualiza tú mismo la caché en vivo:

```bash
pepe usage prices --refresh
```

Los precios también se actualizan solos una vez por semana mientras `serve` o una pasarela estén en marcha.

El **importe a facturar** es `precio de lista × el margen del proyecto`, el multiplicador opcional por proyecto que se describe más abajo. Lo que pagaste y lo que facturas se muestran siempre uno al lado del otro, así que un margen nunca le esconde el coste real a tu propio equipo.

## Suscripciones (ChatGPT Plus, Claude Max)

Una conversación que corre sobre un login de suscripción no cuesta nada por token: el mes se pagó por adelantado, envíes un mensaje o diez mil. Aun así vale exactamente lo mismo para el cliente que una que corrió sobre la API de pago, así que Pepe mantiene tres números en lugar de dos.

| Número | Qué significa |
|---|---|
| **Lista** | `tokens × el precio del modelo`. Lo que estos tokens habrían costado en la API, lo hayan costado o no. |
| **A facturar** | `lista × margen`. Lo que paga el cliente, calculado a partir del precio de lista y **no** a partir de lo que gastaste. |
| **Coste** | Lo que realmente pagaste. Cero para los tokens que sirvió una suscripción, más la cuota mensual fija de esa suscripción, contada una sola vez. |

Facturar a partir del precio de lista es la razón de todo esto. Algún día la suscripción caducará y el mismo trabajo caerá en la API de pago, y ese día la factura del cliente no puede moverse. Un precio que sigue tus acuerdos de suministro es un precio que tienes que explicar.

Dile a Pepe cuánto te cuesta una suscripción y el margen sale bien:

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

El bloque `oauth` lo escribe por ti `pepe model login`. `monthly_cost` es lo que esa suscripción te cuesta al mes. Deja `monthly_cost` sin definir y la cuota sencillamente nunca aparece contra el margen, lo que convierte el margen informado en una cota superior optimista en lugar de en un número equivocado. `pepe doctor` lo dice.

Si una llamada corrió sobre una suscripción se decide **cuando se registra**, no cuando se lee el ledger. Cambia una conexión de un login a una clave de API y las entradas del mes pasado siguen significando lo que significaban.

## Facturación y límites

Cada llamada al modelo se mide por proyecto (consulta Agentes para entender qué es un proyecto y cómo crear uno). Además de esa medición, un proyecto puede llevar opcionalmente dos topes mensuales independientes, más un margen de facturación:

- **Tope de gasto** (`--budget`) - un límite estricto en tu moneda configurada. En cuanto el total facturable del mes lo alcanza, los agentes de ese proyecto dejan de hacer nuevas llamadas al modelo hasta que el tope se reinicie.
- **Tope de mensajes** (`--message-limit`) - un límite estricto en mensajes originados por clientes. En cuanto se alcanza, los agentes de ese proyecto dejan de responder a nuevos mensajes hasta que se reinicie.
- **Margen** (`--markup`) - un multiplicador aplicado sobre el coste del proveedor para llegar al importe que cobras al cliente (p. ej., `1.3` = coste del proveedor +30%). Sin definir, facturas exactamente el coste del proveedor.

Los tres son opcionales e independientes: define cualquiera de ellos, todos, o ninguno. El proyecto por defecto lleva los mismos topes que cualquier otro, definidos con `pepe project set default ...` (o como lo hayas renombrado).

### Qué cuenta para el tope de mensajes

El tope de mensajes cuenta **un mensaje del cliente, una vez**, no cada llamada al modelo que hace falta para responderlo. Si un agente llama a tres herramientas antes de responder, eso sigue siendo un mensaje contra el tope, igual que es un mensaje en el chat. Las iteraciones del bucle de llamadas a herramientas, las ejecuciones de cron, los mensajes de agente a agente y los heartbeats nunca cuentan.

Solo cuenta mensajes provenientes de superficies orientadas al cliente: Telegram, WhatsApp y otros canales por webhook, el widget incrustable. Excluye deliberadamente la consola TUI, el chat de prueba propio del panel, y la API HTTP, ya que esos son el operador usando su propio runtime, no un cliente enviándole mensajes.

Un agente individual puede quedar exento del tope de mensajes por completo, lo que resulta útil para algo como un agente de escalado siempre activo que nunca debe quedarse callado solo porque el resto del proyecto alcanzó el tope:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoy no hay forma desde la consola de activar esa opción en un agente que ya existe sin tocar el resto de su configuración, ya que `agent add` reemplaza toda la definición del agente en lugar de corregir un solo campo. Cámbialo desde la página de edición del agente en el panel.

### Configurar los topes

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

`project set` solo modifica las opciones que pases; el resto de la configuración del proyecto queda intacta. Pasa `none` para borrar un tope:

```bash
pepe project set acme --budget none
```

Los mismos campos son editables desde la página Projects del panel.

### Reiniciar un tope antes de tiempo

Un tope se reinicia naturalmente al comienzo de cada mes de facturación, pero no hace falta esperar:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

La página Projects del panel tiene los mismos dos botones junto al indicador de cada tope, con una confirmación que muestra el recuento actual antes de reiniciar.

Un reinicio no borra nada; solo marca un punto de corte. El gasto o los mensajes registrados antes del reinicio siguen en el ledger; simplemente dejan de contar para el tope de ahí en adelante. Esto importa por un motivo concreto: **el indicador del tope de gasto y el botón de reinicio solo afectan al recuento operativo usado para bloquear nuevas llamadas al modelo.** El registro de facturación real del mes, lo que le facturarías a un cliente, vive en Usage y siempre refleja el total real, reiniciado o no. Si reinicias el tope de gasto de un proyecto a mitad de mes, el indicador de la página Projects mostrará un número menor que la página Usage para ese mismo mes; eso es lo esperado, no una inconsistencia, ya que responden a preguntas distintas ("¿se ha limitado este proyecto desde el último reinicio?" frente a "¿cuánto costó realmente este proyecto este mes?").

## Leer el consumo y exportar facturas

```bash
pepe usage                                   # todos los proyectos, por mes, por proyecto
pepe usage --project acme --granularity day  # un proyecto, por día
pepe usage export --project acme             # una factura de cliente (Markdown, o --format csv)
pepe usage prices --refresh                  # actualiza la caché en vivo de precios
pepe usage help                              # el recorrido completo
```

`usage export` convierte el mes de un proyecto en una factura de cliente, en Markdown o CSV. Un agente puede hacer lo mismo por su cuenta con la herramienta `export_invoice`, así que una tarea programada mensual puede exportar la factura de cada cliente y enviarla, usando Pepe para facturar el propio uso de Pepe.

En el panel, la sección Usage & billing muestra tokens, coste e importe a facturar por ciclo (hora, día, semana, mes, año), con desgloses por proyecto, modelo y agente. Los precios por modelo se definen en Models, luego Edit; el margen de un proyecto en Projects, luego Edit.

La moneda es solo una etiqueta. Por defecto es `USD` y la cambias definiendo `"currency"` en `config.json`. No hay conversión de divisas, así que el número está en la moneda en la que tu proveedor cotiza sus precios.
