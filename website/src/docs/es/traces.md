---
title: Traces
description: Un registro duradero y reproducible de lo que hizo realmente cada ejecución del agente.
---

Cada ejecución de un agente deja un **trace**: un registro duradero y reproducible
de lo que el agente hizo realmente, sea cual sea la superficie que la disparó (la
CLI, la API HTTP, un WebSocket, un mensaje de Telegram o de WhatsApp, o una tarea
programada). Un trace responde a "¿por qué el agente hizo eso?" mucho después de
que la ejecución haya terminado.

## Qué guarda un trace

- El prompt que disparó la ejecución y cómo terminó (`ok`, o un error con su motivo).
- Cuánto tardó y el consumo de tokens del modelo.
- El flujo ordenado de pasos: cada llamada a herramienta **con sus argumentos**, cada resultado de herramienta, cada denegación de permiso y cada cambio de modelo por failover.
- La respuesta final.

Las ejecuciones anidadas de subagentes (un agente que llama a otro mediante
`send_to_agent`) se pliegan en el mismo trace, así que un solo registro muestra
todo el árbol de trabajo.

## En el panel

Abre **Traces** en la barra lateral. La lista muestra las ejecuciones más
recientes del proyecto del workspace actual, con su desenlace, su duración y las
herramientas que usó cada una. Pulsa **Replay** en cualquier ejecución para
recorrerla paso a paso: el prompt arriba y, después, una línea de tiempo con cada
llamada a herramienta, resultado, failover, recuento de tokens y la respuesta
final.

## Desde la CLI

```bash
pepe traces                       # ejecuciones recientes de todos los proyectos
pepe traces --project acme        # solo las ejecuciones de un proyecto
pepe traces --limit 10            # limita el tamaño de la lista
pepe traces 1720000000123456      # reproduce una ejecución por id, paso a paso
```

## Dónde viven los traces

Los traces se escriben como un archivo JSON por ejecución, en
`<PEPE_HOME>/data/traces/<slug>/<id>.json`, donde `<slug>` es el slug del proyecto
(el proyecto por defecto vive bajo `default/`). El directorio tiene un tope por
proyecto, así que los traces más antiguos se van recortando y se mantiene acotado. Los argumentos y los resultados de
herramienta muy largos se recortan en el registro guardado.

<div class="note"><strong>Diagnóstico, no registro de facturación.</strong> Los traces existen para explicar una ejecución, y se recortan para mantenerse acotados. La contabilidad de tokens para facturar vive en el <a href="../billing/">libro de uso</a>, separado y de solo adición.</div>
