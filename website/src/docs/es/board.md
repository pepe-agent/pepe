---
title: Board
description: Una lista de trabajo compartida entre agentes y personas. Las tarjetas esperan su turno, respetan dependencias y sobreviven a un reinicio en vez de perderse.
---

## Qué es

Un board es la lista de tareas que agentes y personas comparten: cargas el trabajo ahí en forma de tarjetas, y cada una sigue su camino hasta quedar recogida, trabajada y cerrada. Piénsalo como una cola de trabajo duradera y reanudable, no como un pipeline de ventas ni un CRM, así que una tarjeta representa una pieza de trabajo, nunca un contacto o un lead. La diferencia con una tarea programada, que repite el mismo prompt cada cierto tiempo, está en que la tarjeta es un encargo puntual: recorre un pipeline de estados, puede esperar a que otras tarjetas terminen primero, y aguanta una caída o un reinicio del sistema sin desaparecer.

```
todo → ready → running → done | blocked → archived
```

Una tarjeta pasa de `todo` a `ready` en cuanto todas sus dependencias llegan a `done`. Ahí alguien la **reclama** (una persona, un agente, o el propio sistema) y arranca `running`. Desde ahí solo hay dos finales posibles: `done`, o `blocked` con un motivo cuando algo la frena, ya sea una reclamación que se quedó a medias o una ejecución que terminó sin avisar que había acabado. Salir de `blocked` exige siempre un `unblock` explícito; nada aquí reintenta por su cuenta, porque cada tarjeta es un turno real de un agente, no un script que puedes relanzar sin más.

### Crear un board desde la CLI

```bash
pepe board add --name "Ingeniería" --project acme
```

`--auto-dispatch` habilita el disparo sin intervención humana: en cuanto el board detecta una tarjeta `ready` con responsable asignado, la arranca sola, sin esperar a que nadie la reclame. Viene apagado de fábrica, así que conviene leer la nota de seguridad de más abajo antes de encenderlo. Con `--claim-timeout-s` fijas cuánto puede durar una reclamación antes de darla por atascada y bloquearla (1800 por defecto; `0` la deja correr para siempre).

```bash
pepe board card add acme/eng \
  --title "Arregla el timeout del checkout" \
  --body "Todo lo que necesita el responsable: es lo único que recibe, sin memoria de chat." \
  --assignee acme/soporte \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

Cada tarjeta puede anular el `auto_dispatch` de su board en cualquiera de los dos sentidos, con `--auto-dispatch` o `--no-auto-dispatch` en `card add`, o después con `pepe board card auto-dispatch ID on|off|inherit` sobre una ya creada. Reclamar a mano funciona siempre, pase lo que pase con esta configuración: lo único que decide es si el propio ciclo del scheduler dispara la tarjeta sin que nadie se lo pida.

El conjunto completo de comandos:

```bash
pepe board list                          # todos los boards
pepe board add --name N [...]            # crea un board
pepe board remove ID [--force]           # elimina (--force borra también sus tarjetas)

pepe board card list BOARD_ID [--status S]
pepe board card show ID
pepe board card add BOARD_ID --title T [...] [--auto-dispatch|--no-auto-dispatch]
pepe board card link ID DEP_ID           # añade una dependencia
pepe board card force-ready ID           # se salta la comprobación de dependencias
pepe board card auto-dispatch ID on|off|inherit  # anula el auto-dispatch propio de esta tarjeta
pepe board card claim ID [--as NAME]
pepe board card complete ID [--text NOTE]
pepe board card block ID --text REASON
pepe board card heartbeat ID [--as NAME] # reinicia el reloj de expiración de una reclamación en curso
pepe board card unblock ID
pepe board card comment ID --text NOTE   # una nota, sin tocar el estado
pepe board card archive ID [--force]     # --force archiva incluso una tarjeta en ejecución
pepe board card unarchive ID
```

### Hazlo desde el panel

Levanta `pepe serve` y entra a la página **Board**. Elige un board, o crea uno nuevo, y vas a ver sus tarjetas repartidas en columnas según el estado. Ahí mismo puedes dar de alta una tarjeta, reclamar una que esté lista, desbloquear una bloqueada, o archivarla, incluso forzando el archivo de una que sigue `running`; esa es, de hecho, la única acción que un agente **no** tiene disponible (lo vemos más abajo). La página se refresca sola conforme cambian las tarjetas, sin importar si el cambio vino del panel, de la CLI o de un agente trabajando el board.

### Hazlo por chat

Con la herramienta `board` en su caja de herramientas, un agente gestiona boards y tarjetas directamente:

> Crea un board llamado "Escalamientos de soporte" y súbele una tarjeta para el bug de login que reportó Sara, asignada al agente de guardia.

Cuando el propio agente es quien queda despachado a trabajar una tarjeta (un board con `auto_dispatch` que la reclama y lanza a su responsable), no hace falta pasarle el id a `complete`, `block` ni a `comment`: Pepe ya lo sabe, porque lo deduce solo de esa sesión.

<div class="note"><strong>Un responsable despachado por auto-dispatch necesita <code>board</code> en su <code>auto_approve</code>.</strong> Una tarjeta que lanza un board con auto-dispatch no tiene a ningún humano detrás para aprobar nada, igual que pasa con la corrida desatendida de una tarea programada. Si el agente responsable no trae <code>board</code> en su lista de <code>auto_approve</code>, cada llamada a <code>complete</code>, <code>block</code> o <code>comment</code> se rechaza en silencio, y la tarjeta se queda ahí parada hasta que el tiempo límite de reclamación del board termine bloqueándola.</div>

## Dependencias y ciclos

En `depends_on` solo caben tarjetas del **mismo board** que tienen que llegar a `done` antes: intenta añadir una dependencia de otro board, un id que no existe, o algo que cerraría un ciclo, y el sistema lo rechaza en el acto. Una tarjeta `archived` jamás cuenta como dependencia satisfecha, solo `done` vale para eso: si cancelan aquello de lo que dependía una tarjeta, esa tarjeta se queda visiblemente clavada en `todo`, en vez de avanzar en silencio por encima de una decisión que quedó abandonada.

## Sin condiciones de carrera al reclamar

Dos aspirantes a la vez (una persona haciendo clic en "Reclamar" y la llamada de herramienta de un agente, o dos ciclos de auto-dispatch corriendo juntos) nunca se quedan los dos con la misma tarjeta. Gana quien llega primero, y al otro le devuelve un error limpio de "no está lista". Esto no exige que añadas ningún bloqueo por tu cuenta: así es como `claim` está construido desde la base.

## Auto-dispatch y el tiempo límite de reclamación

Con `auto_dispatch` apagado (la opción por defecto), una tarjeta `ready` simplemente espera: nada la mueve salvo un `claim` explícito, venga del panel, de la CLI o de un agente. Encendido, el propio reloj interno del board (cada 30 segundos, más o menos) reclama y despacha cualquier tarjeta `ready` que tenga responsable, arrancando a ese agente en una sesión nueva armada alrededor de la tarjeta. Una tarjeta `ready` sin responsable jamás se dispara sola, tenga o no activado el auto-dispatch.

Cualquier tarjeta suelta puede saltarse la regla general de su board: forzarla a dispararse sola dentro de un board que por lo demás es manual, o mantenerla manual dentro de uno que por lo demás dispara solo. Lo defines al crear la tarjeta, o lo cambias después desde el panel (un selector pequeño en la propia tarjeta), la CLI (`card auto-dispatch ID on|off|inherit`), o por chat (`board set_auto_dispatch`).

`claim_timeout_s` funciona como red de seguridad cuando una ejecución despachada se queda callada: si una reclamación dura más que ese límite, la tarjeta pasa a `blocked` con el motivo "claim timed out" en vez de quedarse reclamada para siempre. Pasa lo mismo si la sesión despachada termina, sea normalmente o por una caída, sin haber llamado nunca a `complete` ni a `block`: eso cuenta como una violación del protocolo, y no se reintenta por su cuenta.

Cuando un trabajo de verdad necesita más tiempo del que da `claim_timeout_s`, llama a `board heartbeat` de vez en cuando (o a `pepe board card heartbeat ID` desde fuera de la sesión). Eso reinicia el reloj de expiración sin tocar el estado, para que la tarjeta no se bloquee mientras alguien sigue trabajándola de verdad. Es una señal de que sigue con vida, no un registro de avance: para dejar constancia de actualizaciones en el historial de la tarjeta, usa `comment`.
