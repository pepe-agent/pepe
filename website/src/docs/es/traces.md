---
title: Traces
description: Cada ejecución del agente deja un registro que puedes reproducir después para ver exactamente qué hizo.
---

Cada ejecución de un agente deja un **trace**: un registro duradero de lo que el
agente hizo realmente, que puedes reproducir paso a paso, venga de donde venga la
ejecución (la CLI, la API HTTP, un WebSocket, un mensaje de Telegram o de
WhatsApp, o una tarea programada). Un trace responde a "¿por qué el agente hizo
eso?" mucho después de que la ejecución haya terminado.

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

Los traces se guardan en el mismo pequeño archivo SQLite embebido que los compromisos y
las vigilancias, agrupados por proyecto (el proyecto por defecto usa `default`). Cada
proyecto guarda solo un número limitado de traces: a medida que llegan nuevos, los más
antiguos se borran, así que el archivo nunca crece sin límite. Los argumentos y los
resultados de herramienta muy largos se acortan antes de guardarse.

## Enviar traces a una herramienta de observabilidad

Define `OTEL_EXPORTER_OTLP_ENDPOINT` y cada ejecución terminada también se
envía como un trace OTLP, a [Langfuse](../langfuse/) o cualquier otro
backend que hable ese protocolo, desactivado hasta que lo definas, y un
fallo en el envío nunca afecta a la ejecución que describe.

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de pk-lf-...:sk-lf-...>"
```

`OTEL_EXPORTER_OTLP_HEADERS` es una lista `clave=valor` separada por comas,
enviada como cabeceras literales de la petición. Tanto los atributos
genéricos de OpenTelemetry (`gen_ai.*`) como los propios de Langfuse
(`langfuse.*`) se definen en cada span, así que un endpoint Langfuse
renderiza todo completo y cualquier otro backend OTLP igual recibe un trace
completo. Dos variables más estándar de OTEL, si las necesitas:
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` apunta la señal de traces a otro lugar
además de `<endpoint>/v1/traces`, y `OTEL_SERVICE_NAME` renombra el servicio
exportado (por defecto `pepe`). Guía completa: [Langfuse](../langfuse/).

<div class="note"><strong>Diagnóstico, no registro de facturación.</strong> Los traces existen para explicar una ejecución, y los antiguos o demasiado grandes se van recortando. Para recuentos de tokens que puedas facturar, usa el <a href="../billing/">libro de uso</a>, separado, que nunca pierde una entrada.</div>
