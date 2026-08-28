---
title: Grafos
description: Nodos, aristas y un estado compartido que aguanta entre llamadas al modelo separadas, con un verificador capaz de devolver el flujo a un paso anterior para armar un ciclo de revisión de verdad.
---

## Por qué existe esto

Una conversación normal es un solo agente en un solo bucle, decidiendo qué
hacer llamada tras llamada, y eso cubre casi cualquier caso. Deja de alcanzar
en cuanto el trabajo tiene una *estructura* real: un borrador que una segunda
revisión debería poder rechazar de verdad y devolver, no solo reintentar a
ciegas; un paso que necesita esperar a que una persona responda antes de
seguir; o varias cosas que conviene comprobar a la vez antes de decidir el
siguiente movimiento.

Un **grafo** es un flujo de trabajo con nombre, armado de nodos y aristas,
cuyo estado aguanta entre llamadas al modelo separadas, algo que ninguna otra
automatización de Pepe ofrece. Para comparar: un [flow](../flows/) repite,
sin llamar nunca al modelo, una secuencia exacta de llamadas a herramientas
ya comprobada, y sirve para un trabajo que ya repetiste tantas veces de la
misma forma que ya no hace falta decidir nada. La [delegación](../delegation/),
en cambio, reparte una tarea entre trabajadores de solo lectura que ni
comparten estado entre sí ni pueden actuar. El grafo cubre el terreno
intermedio: trabajo genuinamente de varios pasos, con ramificaciones que
dependen de lo que arroje una revisión real, y que sigue llamando al modelo
en cada paso.

## Tipos de nodo

No hay ningún lenguaje nuevo que aprender, salvo una simple sustitución
`{{key}}` dentro del texto de un nodo. Un grafo admite cinco tipos de nodo:

- **agent**: llama a un modelo con un prompt ya renderizado, y su respuesta queda disponible para cualquier nodo posterior como `{{id}}`. `next` indica cuál es el siguiente nodo; si lo omites, el grafo termina justo ahí.
- **verifier**: hace el mismo tipo de llamada, solo que su respuesta debe terminar en una línea con exactamente una palabra de un conjunto fijo de veredictos (por ejemplo, `{"pass": "publish", "fail": "draft"}`). Esa palabra decide hacia dónde sigue el flujo, y el destino puede ser un nodo *anterior*: ahí está el verdadero ciclo de revisión para el que existe este nodo, porque ese nodo anterior verá la crítica del verificador la próxima vez que se ejecute, a través de `{{ese_verifier_id}}`.
- **human**: no involucra ninguna llamada al modelo. La ejecución se detiene y espera; en cuanto alguien responda, esa respuesta pasa a ser el valor de ese nodo para todo lo que viene después.
- **parallel**: reparte una lista de tareas entre trabajadores de solo lectura, con las mismas restricciones que la [delegación](../delegation/): pueden buscar información, no actuar. La respuesta combinada de todos pasa a ser el valor del nodo.
- **tool**: llama directamente a una herramienta puntual, sujeta a la misma barrera de permisos que cualquier llamada a herramienta, y únicamente a una que el agente del grafo ya tenga entre las suyas.

### Plantillas

`{{input}}` es lo que se pasó al arrancar el grafo. `{{node_id}}` recupera la
salida anterior de ese nodo, y hace fallar la ejecución si todavía no generó
ninguna, algo que casi siempre conviene detectar en vez de dejar pasar un
prompt a medio llenar. `{{node_id?}}` lee lo mismo, pero en lugar de fallar
cae en un texto de reserva, justo lo que necesita un nodo al que se vuelve en
un ciclo: la primera vez que corre, todavía no existe ninguna crítica que
mostrar. Y `{{node_id|default:"algún texto"}}` te deja definir tu propio
texto de reserva en vez del que trae por defecto.

## Un ejemplo

Un borrador que un revisor puede rechazar de verdad, la aprobación de una
persona antes de publicarlo, y un último pase de formato:

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

Si `verify` devuelve "fail", el flujo regresa a `draft`, que esta vez sí ve
la crítica gracias a `{{verify?}}`, en lugar de reintentar a ciegas. Si
devuelve "pass", una persona da el visto bueno antes de que `publish` llegue
siquiera a correr.

## Definir, ejecutar e inspeccionar

Un agente puede definir y correr sus propios grafos por conversación
(`manage_graph`, `run_graph`, `inspect_graph_run`), o puedes hacerlo tú
directamente:

```bash
pepe graph import research.json                      # el archivo indica su propio agente
pepe graph list --agent assistant                     # todos los grafos de ese agente
pepe graph run assistant research-and-verify --input "los números del Q3"
pepe graph runs --agent assistant                     # todas las ejecuciones, incluidas las pausadas
pepe graph inspect grun_a1b2c3d4                       # el historial completo de una ejecución
```

Al importar, se revisa toda la estructura de una sola vez (destinos que no
existen, un nodo sin permiso para apuntar a determinado agente, una
herramienta que un nodo pide pero que el agente no tiene) y se reportan
todos los problemas encontrados, no solo el primero.

Una ejecución que llega a un nodo `human` queda como `waiting_human`, con
exactamente lo que preguntó. Resuélvela en cuanto tengas la respuesta:

```bash
pepe graph resume grun_a1b2c3d4 "sí, publícalo"
```

Nada de la ejecución se pierde mientras espera: se queda estacionada justo
donde se detuvo, el tiempo que sea necesario.

## Ejecutar con una programación

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Usa el mismo mecanismo que un prompt o un flow [programado](../scheduled/),
solo que con otro tipo de trabajo por dentro. Un grafo programado que se
detiene en un nodo `human` sigue esperando a una persona igual: que un
temporizador dispare la ejecución no hace que haya alguien disponible para
responder antes.

<div class="note"><strong>Un verificador que nunca da el visto bueno no puede girar eternamente.</strong> Todo grafo tiene un presupuesto de pasos, 25 por defecto, ampliable hasta 100, así que un ciclo de revisión que nunca converge falla de forma ordenada en cuanto se agota ese presupuesto, en lugar de correr sin fin. Y la confianza no se contamina en toda la ejecución: un nodo solo arranca sin confianza si de verdad lee algo proveniente de contenido externo (una página descargada, un documento subido), y solo esa llamada pierde sus herramientas preaprobadas. Un nodo que únicamente lee estado limpio corre con total confianza, incluso dentro de una ejecución donde otra rama sí tocó algo externo.</div>
