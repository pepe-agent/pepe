---
title: Aprendizaje
description: Cómo un agente convierte conversaciones de confianza en memoria y habilidades duraderas, cómo ver lo que aprendió, y cómo mantener ese conocimiento ordenado.
---

## Convertir conversaciones en conocimiento

Un agente puede convertir conversaciones en conocimiento duradero por su cuenta, mediante el
ciclo de "reflexión". Solo aprende de conversaciones **de confianza**, así que el chat de un
cliente con un bot de soporte nunca se convierte en memoria.

## De quién aprende un agente

Quién cuenta como de confianza lo define una lista de permisos `trainers`, una por bot:

| `trainers` | Qué significa |
|------------|---------------|
| `["*"]` | Aprende de todo el mundo. |
| `[]` | No aprende de nadie. Es lo que quiere un bot orientado al cliente. |
| `[id1, id2]` | Aprende solo de esos ids de usuario, que son tus ids, los entrenadores. |
| omitido o `null` | El valor predeterminado, que es todo el mundo. |

La convención de listas de permisos es la misma en todo Pepe: `["*"]` es todos, `[]` es
nadie, `[elementos]` es exactamente esos, y omitido o `null` es el valor predeterminado de ese
campo.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# un bot orientado al cliente que nunca aprende; tu propio bot de DM (sin --trainers) sigue aprendiendo
```

Esa misma lista es la que controla el comando `/learn` y el cambio de modelo por canal.
Consulta [Canales](../channels/) para ver dónde se configura `trainers` en cada conexión.

## Memoria y habilidades, separadas

Después de una sesión de confianza, el agente revisa la conversación y actualiza dos cosas,
mantenidas aparte a propósito:

- **Memoria** trata sobre *ti*, y vive en `USER.md`, `MEMORY.md` y `people.md`. Se mantiene
  ligera, así que el agente consolida en lugar de ir amontonando.
- **Habilidades** tratan sobre *técnica*. El revisor prefiere actualizar una habilidad existente
  y rica antes que crear una nueva y estrecha.

La revisión es una ejecución en segundo plano con las herramientas restringidas a la gestión de
archivos y habilidades. No tiene shell ni red, así que puede actualizar el workspace y nada más,
y la sesión en vivo queda intacta. Se dispara con `/compact`, por inactividad (unos 90 segundos
después del último turno) y a demanda con **`/learn`** (Telegram y la consola).

## Ver lo que aprendió: TimeLearn

TimeLearn muestra lo que un agente ha aprendido, en una línea de tiempo: habilidades (🧠) y
entradas de memoria (📝), de las más nuevas a las más antiguas, con origen y fecha.

```bash
pepe timelearn assistant         # en la terminal
```

Esa misma línea de tiempo es la pestaña **Learning** del panel, con un selector de agente. El
reparto de trabajo es simple: el generador (la reflexión) produce, y TimeLearn muestra.

## Consolidación

La revisión por conversación mantiene la memoria ligera sobre la marcha, pero cada ejecución solo
ve su propia sesión. A lo largo de muchas conversaciones, la memoria de un agente todavía puede
acumular solapamientos.

**Consolidación** es una pasada de mantenimiento independiente. El agente relee *toda* su memoria
permanente y sus habilidades, sin ninguna conversación delante, y las ordena. Fusiona duplicados,
descarta líneas obsoletas o contradichas, y combina habilidades que se solapan, sin perder ningún
dato duradero. Usa el mismo revisor restringido, limitado a archivos.

```bash
pepe learn consolidate assistant              # ejecuta una pasada ahora
pepe learn auto assistant                     # prográmala cada noche (por defecto 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # o con un horario a tu medida
pepe learn auto assistant --off               # detén la programación
pepe learn status                             # qué agentes consolidan de forma programada
```

En el panel, la pestaña **Learning** tiene un botón **Consolidate now** y un interruptor
**Nightly**. La programación nocturna es una entrada gestionada en la página de
[Tareas programadas](../scheduled/) (un job `consolidate`), y cada pasada se registra como
cualquier otra ejecución, así que puedes reproducirla en los Traces del panel. Consulta
[Panel](../dashboard/).
