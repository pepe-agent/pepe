---
title: Board
description: Tarjetas de tarea duraderas, con dependencias, para pasar trabajo entre agentes y humanos.
---

## Qué es

Un board es una cola duradera y reanudable de elementos de trabajo: **no** es un pipeline de ventas/CRM. Una tarjeta es un elemento de trabajo, no un contacto o un lead. Mientras que una tarea programada dispara el mismo prompt en un reloj recurrente, una tarjeta de board es un trabajo puntual que pasa por un pipeline de estados, puede depender de que otras tarjetas terminen antes, y sobrevive a una caída o a un reinicio en vez de simplemente perderse.

```
todo → ready → running → done | blocked → archived
```

Una tarjeta se promueve de `todo` a `ready` en cuanto toda tarjeta de la que depende llega a `done`. Desde `ready` se **reclama** (por un humano, un agente, o automáticamente) y pasa a `running`. Termina en `done`, o en `blocked` con un motivo si algo la detuvo, incluyendo una reclamación que se atascó o una ejecución que terminó sin decir nunca que había acabado. Una tarjeta bloqueada siempre necesita un `unblock` explícito antes de volver a correr: nada aquí reintenta solo, porque una tarjeta es un turno de agente de verdad, no un script.

### Crear un board desde la CLI

```bash
pepe board add --name "Ingeniería" --project acme
```

`--auto-dispatch` activa el disparo sin supervisión: una tarjeta `ready` con un responsable arranca sola en cuanto el board se da cuenta, en vez de esperar a que alguien la reclame. Viene desactivado por defecto: lee la nota de seguridad más abajo antes de activarlo. `--claim-timeout-s` controla cuánto puede correr una reclamación antes de tratarse como atascada y bloquearse (por defecto 1800; `0` significa nunca).

```bash
pepe board card add acme/eng \
  --title "Arreglar el timeout del checkout" \
  --body "Todo lo que el responsable necesita saber: es lo único que recibe, sin memoria de chat." \
  --assignee acme/soporte \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

Una tarjeta puede anular el `auto_dispatch` de su propio board, en cualquier dirección: `--auto-dispatch` / `--no-auto-dispatch` en `card add`, o `pepe board card auto-dispatch ID on|off|inherit` en una ya existente. Un `claim` manual siempre funciona sin importar esto: solo decide si el propio reloj del scheduler dispara la tarjeta sin que se le pida.

El conjunto completo de comandos:

```bash
pepe board list                          # todos los boards
pepe board add --name N [...]            # crea un board
pepe board remove ID [--force]           # elimina (--force también borra sus tarjetas)

pepe board card list BOARD_ID [--status S]
pepe board card show ID
pepe board card add BOARD_ID --title T [...] [--auto-dispatch|--no-auto-dispatch]
pepe board card link ID DEP_ID           # añade una dependencia
pepe board card force-ready ID           # salta la comprobación de dependencias
pepe board card auto-dispatch ID on|off|inherit  # anula el dispatch de esta tarjeta
pepe board card claim ID [--as NOMBRE]
pepe board card complete ID [--text NOTA]
pepe board card block ID --text MOTIVO
pepe board card unblock ID
pepe board card comment ID --text NOTA   # una nota, sin cambiar el estado
pepe board card archive ID [--force]     # --force archiva incluso una tarjeta en ejecución
pepe board card unarchive ID
```

### Hazlo desde el panel

Ejecuta `pepe serve` y abre la página **Board**. Elige un board (o crea uno) para ver sus tarjetas agrupadas en columnas por estado. Desde ahí puedes crear una tarjeta, reclamar una que esté lista, desbloquear una bloqueada, o archivar una, incluido forzar el archivo de algo que sigue en `running`, la única acción deliberadamente **no** disponible para un agente (ver abajo). La página se actualiza en vivo a medida que las tarjetas cambian, venga ese cambio del panel, de la CLI, o de un agente trabajando en el board.

### Hazlo por chat

Un agente gestiona boards y tarjetas con la herramienta `board`, si está en su conjunto de herramientas:

> Crea un board llamado "Escalaciones de soporte" y pon una tarjeta para el bug de login que reportó Sara, asignada al agente de guardia.

Cuando un agente es despachado para trabajar una tarjeta (un board con `auto_dispatch` que reclama y ejecuta a su responsable), no necesita pasar el id de la tarjeta a `complete`, `block` o `comment`: Pepe lo infiere automáticamente a partir de esa sesión.

<div class="note"><strong>Un responsable de board con auto-dispatch necesita <code>auto_approve</code> para <code>board</code>.</strong> Una tarjeta despachada por un board con auto-dispatch no tiene ningún humano al lado para aprobar nada, igual que la ejecución sin supervisión de una tarea programada. Sin <code>board</code> en la lista <code>auto_approve</code> del agente responsable, cada llamada a <code>complete</code>/<code>block</code>/<code>comment</code> que haga se deniega en silencio, y la tarjeta se queda quieta hasta que el tiempo límite de reclamación del board la bloquea.</div>

## Dependencias y ciclos

`depends_on` apunta a otras tarjetas del **mismo board** que deben llegar a `done` primero: una dependencia de otro board, un id desconocido, o cualquier cosa que crease un ciclo se rechaza al intentar añadirla. Una tarjeta `archived` nunca satisface una dependencia, solo `done` lo hace: si algo de lo que depende una tarjeta se cancela, la tarjeta que espera se queda visiblemente atascada en `todo` en vez de promoverse en silencio por encima de una decisión abandonada.

## Las reclamaciones no tienen disputa

Dos interesados (un humano haciendo clic en "Reclamar" y la llamada de herramienta de un agente, o dos ciclos de auto-dispatch) nunca pueden ganar la misma reclamación de una tarjeta a la vez. El primero que llega gana; el otro recibe un error limpio de "no está lista". Esto se cumple sin que tengas que añadir ningún bloqueo extra por tu cuenta: así es como está construido `claim`.

## Auto-dispatch y el tiempo límite de reclamación

Con `auto_dispatch` desactivado (por defecto), una tarjeta `ready` solo espera: nada la dispara salvo un `claim` explícito, desde el panel, la CLI, o un agente. Con él activado, el propio reloj del board (cada 30 segundos, aproximadamente) reclama y despacha cualquier tarjeta `ready` que tenga un responsable, ejecutando a ese agente en una sesión nueva construida alrededor de la tarjeta. Una tarjeta `ready` sin responsable nunca se dispara sola, de ninguna forma.

Cualquier tarjeta concreta puede anular la configuración de su propio board: forzar que una tarjeta se dispare sola dentro de un board normalmente manual, o forzar que una tarjeta se quede manual en un board normalmente automático. Configúralo al crear la tarjeta, cámbialo después desde el panel (un selector pequeño en la propia tarjeta), la CLI (`card auto-dispatch ID on|off|inherit`), o por chat (`board set_auto_dispatch`).

`claim_timeout_s` es la red de seguridad para una ejecución despachada que se queda callada: si una reclamación sobrevive más allá de ese tiempo, la tarjeta se bloquea con "claim timed out" en vez de quedar reclamada para siempre. Lo mismo ocurre si la sesión despachada termina (normalmente o cayéndose) sin llamar nunca a `complete` o `block`: eso se trata como una violación de protocolo, no se reintenta en silencio.
