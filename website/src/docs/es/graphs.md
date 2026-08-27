---
title: Grafos
description: Nodos, aristas y estado compartido que sobrevive a llamadas al modelo separadas, con un verificador que puede devolver el flujo a un paso anterior para una revisión de verdad.
---

## Por qué existe esto

Una conversación normal es un agente, un bucle, decidiendo qué hacer llamada a llamada. Eso cubre casi todo. Deja de bastar en cuanto un trabajo tiene una *estructura* real: un borrador que un segundo repaso debería poder rechazar de verdad y devolver, no solo reintentar a ciegas; un paso que tiene que esperar a una persona antes de seguir; varias cosas que vale la pena comprobar a la vez antes de decidir qué sigue.

Un **grafo** es un flujo de trabajo con nombre, hecho de nodos y aristas, con estado que sobrevive a llamadas al modelo separadas, algo que ninguna otra automatización de Pepe cubre. Un [flow](../flows/) repite una secuencia exacta y ya comprobada de llamadas a herramientas sin ninguna llamada al modelo: es para un trabajo que ya hiciste de la misma forma suficientes veces como para que ya no haga falta decidir. La [delegación](../delegation/) reparte una tarea entre trabajadores de solo lectura que no comparten estado entre sí y no pueden actuar. Un grafo es para el trabajo intermedio: genuinamente de varios pasos, con ramificación que depende de lo que encontró una revisión real, llamando al modelo en cada paso.

## Tipos de nodo

No hay ningún lenguaje nuevo que aprender más allá de una única sustitución `{{key}}` en el texto de un nodo. Un grafo tiene cinco tipos de nodo:

- **agent** - llama a un modelo con un prompt ya renderizado. Su respuesta queda disponible para cualquier nodo posterior como `{{id}}`. `next` nombra el siguiente nodo; si se omite, el grafo termina ahí.
- **verifier** - la misma llamada, pero su respuesta tiene que terminar en una línea que contenga exactamente una palabra de un conjunto fijo de veredictos (`{"pass": "publish", "fail": "draft"}`, por ejemplo). Esa palabra decide a dónde va el flujo después, y el destino puede ser un nodo *anterior*, que es la revisión de verdad para la que existe esto: el nodo anterior ve la crítica del verificador la próxima vez que se ejecute, vía `{{ese_verifier_id}}`.
- **human** - ninguna llamada al modelo. La ejecución se pausa y espera; la respuesta de alguien, cuando llegue, se convierte en el valor de ese nodo para todo lo que viene después.
- **parallel** - reparte una lista de tareas entre trabajadores de solo lectura, las mismas restricciones que la [delegación](../delegation/): pueden buscar información, no actuar. La respuesta combinada se convierte en el valor del nodo.
- **tool** - llama a una herramienta concreta directamente, con la misma barrera de permisos que cualquier llamada a herramienta, y solo a una herramienta que el propio agente del grafo ya tiene.

### Plantillas

`{{input}}` es lo que se pasó al iniciar el grafo. `{{node_id}}` lee la respuesta anterior de ese nodo, y falla la ejecución si todavía no ha producido ninguna - casi siempre es un error que vale la pena detectar en vez de enviar un prompt a medias. `{{node_id?}}` lee lo mismo pero cae en un texto de reserva en vez de fallar, que es justo lo que necesita un nodo de vuelta atrás: la primera vez que se ejecuta, todavía no hay ninguna crítica. `{{node_id|default:"algún texto"}}` cae en un literal propio en vez del texto de reserva incorporado.

## Un ejemplo

Un borrador que un revisor puede rechazar de verdad, una aprobación humana antes de publicarlo, y un último pase de formato:

```json
{
  "name": "research-and-verify",
  "agent": "assistant",
  "entry": "draft",
  "nodes": [
    { "id": "draft", "type": "agent",
      "prompt": "Escribe sobre {{input}}. Crítica anterior: {{verify?}}",
      "next": "verify" },
    { "id": "verify", "type": "verifier",
      "prompt": "Revisa si hay afirmaciones sin fuente:\n\n{{draft}}",
      "verdicts": { "pass": "review_human", "fail": "draft" } },
    { "id": "review_human", "type": "human",
      "ask": "¿Apruebas publicar esto?\n\n{{draft}}",
      "next": "publish" },
    { "id": "publish", "type": "agent",
      "prompt": "Formatea como salida final:\n\n{{draft}}\n\nDecisión humana: {{review_human}}" }
  ]
}
```

Si `verify` dice "fail", el flujo vuelve a `draft`, que ahora ve la crítica a través de `{{verify?}}`, en vez de simplemente reintentar a ciegas. Si dice "pass", una persona da el visto bueno antes de que `publish` llegue siquiera a ejecutarse.

## Definir, ejecutar e inspeccionar

Un agente define y ejecuta sus propios grafos por conversación (`manage_graph`, `run_graph`, `inspect_graph_run`), o puedes hacerlo directamente:

```bash
pepe graph import research.json                      # el archivo indica su propio agente
pepe graph list --agent assistant                     # todos los grafos de ese agente
pepe graph run assistant research-and-verify --input "los números del Q3"
pepe graph runs --agent assistant                     # todas las ejecuciones, incluidas las pausadas
pepe graph inspect grun_a1b2c3d4                       # el historial completo de una ejecución
```

Importar comprueba toda la estructura de una vez - destinos desconocidos, un nodo que no tiene permiso para nombrar a un agente dado, una herramienta a la que un nodo intenta llegar y que el agente en realidad no tiene - y reporta todos los problemas que encuentra, no solo el primero.

Una ejecución que llega a un nodo `human` vuelve como `waiting_human`, con exactamente lo que preguntó. Resuélvela cuando la respuesta esté lista:

```bash
pepe graph resume grun_a1b2c3d4 "sí, publícalo"
```

Nada de la ejecución se pierde mientras espera: se queda aparcada exactamente donde se detuvo, el tiempo que haga falta.

## Ejecutar con una programación

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

El mismo mecanismo que un prompt o un flow [programado](../scheduled/), solo que con otro tipo de trabajo por debajo. Un grafo programado que se pausa en un nodo `human` sigue esperando a una persona: que un temporizador dispare la ejecución no hace que haya nadie disponible para responder antes.

<div class="note"><strong>Un verificador que nunca está de acuerdo no puede girar para siempre.</strong> Todo grafo tiene un presupuesto de pasos - 25 por defecto, y se puede subir hasta 100 - así que un bucle de revisión que nunca converge falla de forma limpia en cuanto se agota, en vez de correr para siempre. Y la confianza no se difumina por toda la ejecución: un nodo solo empieza sin confianza si de verdad lee algo que vino de contenido externo (una página descargada, un documento subido), y solo esa llamada pierde sus herramientas preaprobadas - un nodo que solo lee estado limpio corre con total confianza incluso en una ejecución donde otra rama tocó algo externo.</div>
