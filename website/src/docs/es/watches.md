---
title: Vigilancias
description: Dile a Pepe que vigile algo y te avise justo cuando pase. Comprueba solo, sobrevive a reinicios y avisa una única vez.
---

## Vigilancias

Una vigilancia responde a una pregunta distinta de la de las tareas programadas: no es "haz esto según el reloj", sino "mantén el ojo puesto en algo y avísame en el momento en que ocurra". Vuelve a comprobar una condición cada cierto tiempo y, apenas se cumple, te notifica **una sola vez** y se detiene ahí. Es duradera: sobrevive a un reinicio y al cierre de la sesión que la creó, y siempre contesta por el mismo canal desde el que se creó.

### Disparadores de sonda y de agente

La parte barata de una vigilancia es el **disparador**, que corre en cada intervalo. La notificación, que puede ser costosa, solo se ejecuta una vez, cuando el disparador finalmente se activa. Hay dos tipos:

- Una **sonda** corre un comando de shell y no gasta tokens en cada comprobación. Por defecto, el éxito es que el comando salga con código 0, aunque también puedes pedir que aparezca una cadena determinada en su salida. Conviene usar una sonda siempre que la condición se pueda scriptear (que una URL responda, que un job haya escrito un archivo, que un log contenga cierta línea).
- Un disparador de **agente** le vuelve a hacer al agente una pregunta de sí o no en cada intervalo, y eso sí cuesta una llamada al modelo por cada comprobación. Úsalo solo cuando de verdad haga falta criterio para decidir si la condición se cumplió.

Como las comprobaciones de agente consumen tokens, su intervalo mínimo es más alto: 300 segundos para los disparadores de agente, contra 30 segundos para las sondas. El intervalo por defecto es de 120 segundos.

### Qué manda cuando se dispara

Cuando el disparador finalmente pasa, la vigilancia entrega un mensaje. Ese mensaje puede ser una **plantilla** fija, que armas de antemano y no gasta ninguna llamada al modelo, o puede quedar **compuesto por el agente** en el momento del disparo (ahí sí, una llamada al modelo, una única vez), lo que le permite incluir detalles frescos, como un resumen de lo que realmente pasó.

La combinación que más conviene conocer es una sonda gratuita que controla un mensaje compuesto por el agente: el sondeo con `curl` no cuesta nada, y al modelo solo se le pide que escriba el resumen justo en el momento en que la condición se cumple.

### Crear una vigilancia desde la CLI

La CLI crea vigilancias por sonda. Las que se juzgan por criterio de un agente se crean desde el chat, donde el modelo ya está metido en el proceso.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- La descripción (`"api-up"`) pasa a ser el id de la vigilancia.
- `--probe` es el comando de shell que se sondea. Sin `--contains`, el éxito significa que el comando salió con código 0.
- `--contains STR`, en cambio, hace que el éxito dependa de que `STR` aparezca en la salida del comando.
- `--message` es el texto que se manda al dispararse. Si lo omites, usa una confirmación por defecto.
- `--every` es el intervalo de sondeo en segundos (mínimo 30).
- `--deliver telegram:<chat>` manda la notificación a ese chat. Si lo omites, la notificación va al log de la aplicación.

Para administrar vigilancias:

```bash
pepe watch list                 # todas las vigilancias, con su estado y comprobaciones hechas
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Hazlo desde el panel

Abre la página **Watches** en `pepe serve` para ver cada vigilancia con su estado, su disparador, su intervalo y cuántas comprobaciones lleva usadas de su presupuesto. Desde ahí puedes pausarla, reanudarla o cancelarla. Las vigilancias nuevas se crean desde la CLI o por chat, que es donde defines el disparador y el destino de entrega.

### Hazlo por chat

Pídelo con tus propias palabras y el agente crea la vigilancia usando su herramienta `watch`. Igual que `schedule_task`, la herramienta `watch` viene habilitada por defecto (quítasela a un agente si nunca debería poder crear una) y cada creación pasa por el mismo aviso de permiso.

> Avísame cuando termine el despliegue. Revisa cada pocos minutos.

Si la comprobación se puede scriptear, el agente arma una sonda. Si hace falta criterio, arma un disparador de agente, formulando una pregunta de sí o no que se responde en cada intervalo. También puede optar por que el mensaje de disparo lo componga el modelo en vez de usar una plantilla fija, así la notificación lleva un resumen real en lugar de una frase enlatada. Las acciones de la herramienta `watch` son `create`, `list`, `pause`, `resume` y `cancel`.

Para que esto no se descontrole, puede haber como máximo 50 vigilancias activas al mismo tiempo, y Pepe rechaza una vigilancia nueva cuya condición sea idéntica a una que ya está corriendo, así que no puedes terminar apilando duplicados por accidente. Además, cada vigilancia tiene un número máximo de comprobaciones; si la condición nunca llega a cumplirse dentro de ese presupuesto, la vigilancia expira en silencio en lugar de sondear para siempre.

### Entrega en el canal de origen

Al crearse, una vigilancia guarda su **origen**: el canal y la conversación desde donde nació. Cuando se dispara, entrega ahí mismo, incluso después de un reinicio, ya sea un chat de Telegram (con envío directo), una sesión de terminal o WebSocket conectada, o el log de la aplicación. Por WebSocket, la notificación llega como un evento `"watch"` en el canal; si al conectarte pasas un `session` estable, la recibirás incluso después de reconectarte, en lugar de solo en el socket que la creó originalmente. En `pepe chat` se imprime directo en la consola. Si la vigilancia se creó desde la API HTTP, que no tiene conversación a la cual responderle, cae de vuelta al log.

Hay dos garantías que hacen que esto sea confiable:

- **A lo sumo una vez.** El nuevo estado de la vigilancia (normalmente "done") se guarda en disco *antes* de intentar la entrega. Si el proceso se cae justo entre el disparo y la entrega, no va a volver a comprobar ni a dispararse una segunda vez. Lo único que se reintenta es la entrega.
- **Entrega en cuanto se pueda.** Si una vigilancia se dispara mientras su canal está fuera de línea (por ejemplo, una sesión de terminal que se desconectó), el mensaje queda retenido y se reintenta en cada ciclo hasta que consigue entregarse. Recibes la notificación en cuanto vuelves, sin que la vigilancia tenga que volver a comprobar nada.

Una vigilancia pasa por un conjunto pequeño de estados a lo largo de su vida: `pending` (todavía vigilando), `paused`, `done` (ya se disparó y entregó), `expired` (agotó su presupuesto de comprobaciones), o `cancelled`.

<div class="note"><strong>Sin base de datos que instalar, sin crontab.</strong> Las tareas programadas son simples registros dentro de <code>~/.pepe/config.json</code> (bajo <code>"crons"</code>), con un archivo JSONL de historial por tarea en <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Las vigilancias viven en ese mismo archivo SQLite embebido, junto con los compromisos, sin que tengas que instalar ni administrar nada aparte. En cualquiera de los dos casos no hay ningún otro proceso que mantener corriendo: todo el planificador es un temporizador dentro del propio proceso, activo en cualquier superficie de vida larga que esté en pie (<code>pepe serve</code>, un gateway, o un <code>pepe chat</code> interactivo), y se detiene apenas detienes esa superficie. Corre solo una a la vez contra la misma configuración: si corrieran dos, ambas harían tick a la par, y una vigilancia terminaría avisando dos veces.</div>
