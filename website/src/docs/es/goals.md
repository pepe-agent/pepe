---
title: Objetivos
description: Lleva a un agente hacia un resultado concreto, verificado por un revisor independiente, hasta que el trabajo esté realmente terminado.
---

## Dar un prompt vs. perseguir un objetivo

Un prompt suelto solo te da **un turno**: el agente responde y después eres *tú* quien decide si está bien, pide un ajuste y vuelve a intentarlo. Con eso terminas haciendo doble papel, apruebas y controlas la calidad a la vez, y el trabajo avanza solo mientras sigues frente al teclado.

Un **objetivo**, en cambio, te da un **resultado**: defines qué significa "terminado" y Pepe sigue trabajando hasta que un revisor independiente confirma que se llegó ahí, o hasta agotar los intentos disponibles.

La diferencia real está en *quién juzga*. En un turno normal, el propio agente decide cuándo terminó, y esa es justo la evaluación en la que no puedes confiar. Con un objetivo, en cambio, una **llamada al modelo completamente aparte** califica el resultado contra tu criterio, el patrón de criterios más pasos de evaluación, en la variante conocida como LLM-as-a-Judge.

## Ejecutar uno

```bash
pepe goal "OBJETIVO" --criteria "cómo sabemos que está hecho" \
  [--max-attempts 3] [--judge MODELO] [--agent NOMBRE]
```

Un ejemplo real:

```bash
pepe goal "limpiar la lista de clientes en ~/datos/clientes.csv" \
  --criteria "sin correos duplicados, y cada fila con un teléfono válido" \
  --max-attempts 4
```

A medida que avanza, Pepe va mostrando cada intento junto con el veredicto del revisor:

```
── attempt 1/4 ──
[-> read_file clientes.csv]
[✓ read_file]
...
↻ reviewer: 3 filas siguen con la columna de teléfono vacía

── attempt 2/4 ──
...
✅ reviewer: ya no hay correos duplicados y todas las filas tienen teléfono

✅ Goal met after 2 attempt(s).
```

Desde el panel, puedes lanzarlo desde cualquier chat:

```
/goal limpiar la lista de clientes | sin correos duplicados, cada fila con un teléfono válido
```

Mientras trabaja, el panel que aparece sobre la conversación muestra el criterio, cuántos intentos lleva y el último veredicto del revisor.

## Cómo se mantiene independiente el revisor

El revisor parte de una llamada nueva, con **contexto limpio**: no ve en ningún momento la conversación de trabajo, solo tu criterio y el resultado final. Por eso evalúa el producto terminado, no el razonamiento que lo generó, y ningún agente convencido de tener razón, aunque esté equivocado, puede convencerlo a él.

Por defecto, el revisor usa la misma conexión de modelo que el agente. Si le pasas `--judge`, puedes darle un modelo **distinto**, lo cual es la opción más sólida: un revisor es más independiente de verdad cuando no es el mismo modelo el que corrige su propia tarea.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

Si la respuesta del revisor llega en un formato ilegible, Pepe la trata directamente como **no cumplida**. Dejar pasar un veredicto que no se puede interpretar equivaldría a dejar colar un mal resultado, y evitar justamente eso es la razón de ser de este bucle.

## El límite de intentos

Este límite es **obligatorio** (3 intentos por defecto, 10 como máximo). Si el agente jamás va a lograr cumplir un criterio, eso debe costar una cantidad acotada de intentos, no una ejecución infinita. Al llegar al límite, Pepe se detiene, marca el objetivo como `blocked` y te explica qué faltaba:

```
🛑 Gave up at the attempt cap. Still missing: 3 filas siguen con la columna de teléfono vacía
```

Ese mensaje ya aporta valor por sí solo: casi siempre revela un criterio imposible de cumplir, o un obstáculo real que merece que le eches un vistazo tú mismo.

## Escribir un criterio que funcione

El criterio es, en el fondo, toda la funcionalidad. Uno vago convierte al revisor en una moneda al aire, y el bucle nunca llega a converger.

- **Bueno:** "sin correos duplicados, y cada fila con un teléfono con formato `+NN NNN NNN NNN`"
- **Malo:** "la lista está limpia"

Hazte esta pregunta: *si un desconocido solo tuviera mi criterio y el resultado delante, ¿podría decidir sí o no sin tener que preguntarme nada más?* Si la respuesta es no, el revisor tampoco va a poder. Elige siempre criterios que apunten a una propiedad verificable (una cantidad, un formato, un archivo que debe existir, una prueba que debe pasar) en vez de criterios que solo describen una sensación de calidad.

## Objetivos y herramientas

Un objetivo no es un modo especial de funcionamiento, simplemente envuelve un turno normal. El agente conserva todas sus herramientas y puede seguir leyendo archivos, consultando una base de datos o llamando a una API mientras avanza hacia la meta. Lo único que llega al revisor es la **respuesta final** de cada intento.

## Estado de trabajo dentro de la conversación

`pepe goal` dirige toda una ejecución desde afuera. Hay, además, dos herramientas separadas que le dan al agente un estado de trabajo **desde dentro**, de modo que se mantenga coherente a lo largo de muchos turnos en vez de ir reaccionando mensaje por mensaje. Las dos viven a nivel de conversación: pertenecen a la sesión y desaparecen junto con ella, y cada llamada, con su resultado, queda registrada en el chat y en las [Trazas](/es/docs/traces/). Son herramientas normales, activas por defecto; si no quieres que un agente le dé seguimiento a un objetivo o un plan entre turnos, simplemente quita `goal` y `update_plan` de su lista de herramientas.

### `goal`: la estrella polar

Aquí, un objetivo es una meta persistente junto con un estado. El agente la fija al comenzar una tarea que no sea trivial, la vuelve a leer para no perder el rumbo, y la marca como terminada (o bloqueada) al final. La herramienta admite cuatro acciones:

- `set`: define el `objective` (qué está tratando de lograr), más un `budget_tokens` opcional, meramente orientativo, para mantener el esfuerzo dentro de lo razonable.
- `status`: marca el objetivo como `active`, `paused`, `blocked` o `complete`, con una `note` opcional. `blocked` es la forma en que el agente avisa que está atascado y necesita ayuda; `complete` indica que la meta se cumplió.
- `show`: devuelve el objetivo vigente.
- `clear`: lo elimina.

Tanto el objetivo como el estado sobreviven entre turnos e incluso a un reinicio, para que una ejecución larga o autónoma no termine desviándose de lo que se propuso originalmente.

<div class="note"><strong><code>budget_tokens</code> es una referencia orientativa, no un tope estricto.</strong> Se le informa al agente para que dosifique el esfuerzo, pero nada lo obliga a respetarlo. El límite duro de gasto es el tope mensual por proyecto que se explica en <a href="/es/docs/billing/">Uso y facturación</a>.</div>

### `update_plan`: la lista de tareas viva

`update_plan` mantiene una lista ordenada de pasos, cada uno en estado `pending`, `in_progress` o `done`. Cada llamada envía la lista **completa** y sustituye a la anterior, de forma que siempre existe un único plan coherente. Tras cada actualización, se devuelve la lista ya renderizada:

```
Plan (1/3 done):
[x] read the failing test
[~] find the root cause
[ ] write the fix
```

El agente mantiene un solo paso en `in_progress` a la vez, y va ajustando la lista según avanza el trabajo. Pasar una lista `steps` vacía borra el plan. Consérvalo para tareas de varios pasos donde el avance necesita quedar visible, y omítelo en una petición trivial de un solo paso.

### Cómo habilitarlas

```bash
pepe agent add worker --prompt "..." --tools bash,read_file,edit_file,goal,update_plan
```

También puedes agregarlas a la lista de herramientas de un agente ya existente desde el panel, en la pestaña Agents. Una vez habilitadas, ambas aparecen en `pepe tools`.

### Ver el objetivo y el plan actuales

En el panel, la pestaña Chat muestra un **panel de foco** delgado justo debajo del encabezado de la conversación seleccionada: ahí aparecen el objetivo (su meta más una insignia de estado) y la lista del plan, ambos actualizándose mientras el agente trabaja. También son visibles dentro del propio flujo de la conversación, porque cada llamada a `goal` y a `update_plan`, junto con su resultado, queda registrada en el chat y en las [Trazas](/es/docs/traces/).

## Lo que el bucle de objetivo no es

- **No** es un programador de tareas: para ejecutar algo de forma recurrente, mira [Tareas programadas](/es/docs/scheduled/).
- **No** es un vigilante: para que te avisen cuando se cumpla una condición, mira [Watches](/es/docs/watches/).

Un objetivo tiene un final: llega a la meta o se rinde, y en cualquiera de los dos casos, ahí termina.
