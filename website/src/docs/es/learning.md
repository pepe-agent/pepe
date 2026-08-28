---
title: Aprendizaje
description: Cómo un agente convierte conversaciones de confianza en memoria y habilidades duraderas, cómo revisar lo que aprendió, y cómo mantener ese conocimiento ordenado.
---

## Convertir conversaciones en conocimiento

Un agente puede convertir conversaciones en conocimiento duradero por su cuenta, mediante el ciclo de "reflexión". Solo aprende de conversaciones **de confianza**, así que el chat de un cliente con un bot de soporte jamás termina en su memoria.

## De quién aprende un agente

Una lista de permisos `trainers`, propia de cada bot, decide quién cuenta como de confianza:

| `trainers` | Qué significa |
|------------|---------------|
| `["*"]` | Aprende de todo el mundo. |
| `[]` | No aprende de nadie. Lo que quiere un bot orientado al cliente. |
| `[id1, id2]` | Aprende solo de esos ids de usuario: los tuyos, los de los entrenadores. |
| omitido o `null` | El valor por defecto, que equivale a todo el mundo. |

Esta convención de listas de permisos se repite en todo Pepe: `["*"]` es todos, `[]` es nadie, `[elementos]` es exactamente esos, y omitir el campo (o poner `null`) cae en su valor por defecto.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# un bot orientado al cliente que nunca aprende; tu propio bot de DM (sin --trainers) sí sigue aprendiendo
```

La misma lista controla el comando `/learn` y el cambio de modelo por canal. Consulta [Canales](../channels/) para ver dónde se configura `trainers` en cada conexión.

## Memoria y habilidades, cada una por su lado

Tras una sesión de confianza, el agente revisa la conversación y actualiza dos cosas que se mantienen deliberadamente separadas:

- **La memoria** habla de *ti*, y vive en `USER.md`, `MEMORY.md` y `people.md`. Se mantiene ligera a propósito: el agente consolida en lugar de ir amontonando entradas.
- **Las habilidades** hablan de *técnica*. El revisor prefiere ampliar una habilidad rica que ya existe antes que crear una nueva y estrecha.

Para encontrar algo puntual sin tener que leer un archivo entero, el agente cuenta con la herramienta `memory_search`: una búsqueda simple, sin distinguir mayúsculas de minúsculas, sobre sus propias entradas de `MEMORY.md`, `USER.md` y `people.md`, con cada resultado marcado según el archivo del que viene. Es una búsqueda léxica, no semántica: no hay embeddings ni una llamada extra a ninguna API, lo que encaja bien con una memoria que se mantiene pequeña a propósito.

La revisión corre en segundo plano, con las herramientas limitadas a gestionar archivos y habilidades. No tiene shell ni red, así que solo puede tocar el workspace y nada más, dejando intacta la sesión en vivo. Se dispara al ejecutar `/compact`, tras un rato de inactividad (unos 90 segundos desde el último turno) y a demanda con **`/learn`** (en Telegram y en la consola).

## Ver lo que aprendió: TimeLearn

TimeLearn muestra en una línea de tiempo lo que un agente ha aprendido: habilidades (🧠) y entradas de memoria (📝), de la más reciente a la más antigua, cada una con su origen y su fecha.

```bash
pepe timelearn assistant         # en la terminal
```

Esa misma línea de tiempo aparece en la pestaña **Learning** del panel, con un selector de agente. El reparto de trabajo es simple: el generador (la reflexión) produce, y TimeLearn se limita a mostrarlo.

## Consolidación

La revisión por conversación mantiene la memoria ligera sobre la marcha, pero cada pasada solo ve su propia sesión. Con muchas conversaciones acumuladas, la memoria de un agente todavía puede terminar con solapamientos.

La **consolidación** es una pasada de mantenimiento aparte. El agente relee *toda* su memoria permanente y sus habilidades, sin ninguna conversación delante, y pone orden: fusiona duplicados, descarta líneas obsoletas o contradichas, y combina habilidades que se solapan, sin perder ningún dato duradero en el camino. Usa el mismo revisor restringido y limitado a archivos.

```bash
pepe learn consolidate assistant              # ejecuta una pasada ahora
pepe learn auto assistant                     # la programa cada noche (por defecto 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # o con un horario a tu medida
pepe learn auto assistant --off               # detiene la programación
pepe learn status                             # qué agentes consolidan de forma programada
```

En el panel, la pestaña **Learning** tiene un botón **Consolidate now** y un interruptor **Nightly**. La programación nocturna es una entrada gestionada más en la página de [Tareas programadas](../scheduled/) (un job `consolidate`), y cada pasada queda registrada como cualquier otra ejecución, así que puedes reproducirla en los Traces del panel. Consulta [Panel](../dashboard/).
