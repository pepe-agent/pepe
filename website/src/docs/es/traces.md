---
title: Traces
description: Cada ejecución de un agente deja un registro que puedes reproducir después para ver exactamente qué hizo.
---

Cada ejecución de un agente deja un **trace**: un registro duradero de lo que el agente hizo de verdad, que se puede recorrer paso a paso sin importar de dónde vino la ejecución (la CLI, la API HTTP, un WebSocket, un mensaje de Telegram o de WhatsApp, o una tarea programada). Un trace es lo que te permite responder "¿por qué el agente hizo eso?" mucho después de que la ejecución ya terminó.

## Qué guarda un trace

- El prompt que disparó la ejecución y cómo terminó (`ok`, o un error con su motivo).
- Cuánto tardó y cuántos tokens de modelo consumió.
- La secuencia ordenada de pasos: cada llamada a herramienta **con sus argumentos**, cada resultado, cualquier permiso denegado y cada cambio de modelo por failover.
- La respuesta final.

Cuando un agente llama a otro con `send_to_agent`, la ejecución del subagente se pliega dentro del mismo trace, así que un solo registro deja ver todo el árbol de trabajo.

## En el panel

Abre **Traces** en la barra lateral. Ahí aparecen las ejecuciones más recientes del proyecto actual, con su resultado, su duración y qué herramientas usó cada una. Haz clic en **Replay** sobre cualquier ejecución para recorrerla paso a paso: arriba el prompt, y debajo una línea de tiempo con cada llamada a herramienta, su resultado, cada failover, el conteo de tokens y la respuesta final.

## Desde la CLI

```bash
pepe traces                       # ejecuciones recientes de todos los proyectos
pepe traces --project acme        # solo las de un proyecto
pepe traces --limit 10            # limita cuántas se muestran
pepe traces 1720000000123456      # reproduce una ejecución por su id, paso a paso
```

## Dónde se guardan los traces

Los traces viven en el mismo archivo SQLite embebido donde también están los compromisos y las vigilancias, agrupados por proyecto (el proyecto por defecto usa `default`). Cada proyecto conserva solo un número limitado: a medida que entran traces nuevos, se van borrando los más viejos, así que el archivo no crece sin control. Los argumentos y resultados de herramienta muy largos se recortan antes de guardarse.

## Enviar traces a una herramienta de observabilidad

Enviarlos a [Langfuse](../langfuse/) no pide nada más que las credenciales que la mayoría de las instalaciones ya tiene configuradas (`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`): en cuanto esas variables están presentes, cada ejecución terminada se envía como un trace OTLP; si no están, simplemente no se envía nada, y un fallo en el envío nunca afecta la ejecución que describe.

Si quieres apuntar a cualquier otro backend que hable OTLP, define en su lugar `OTEL_EXPORTER_OTLP_ENDPOINT`, y este toma el control por completo:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://tu-colector.ejemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:contraseña>"
```

`OTEL_EXPORTER_OTLP_HEADERS` es una lista de pares `clave=valor` separados por coma, que se envían tal cual como cabeceras de la petición. Cada span lleva tanto los atributos genéricos de OpenTelemetry (`gen_ai.*`) como los propios de Langfuse (`langfuse.*`), así que un endpoint de Langfuse renderiza todo completo y cualquier otro backend OTLP también recibe un trace íntegro. Dos variables OTEL estándar más, por si las necesitas: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` redirige la señal de traces a otro lugar distinto de `<endpoint>/v1/traces`, y `OTEL_SERVICE_NAME` cambia el nombre del servicio exportado (por defecto, `pepe`). La guía completa está en [Langfuse](../langfuse/).

Más allá del prompt y la respuesta de la ejecución, y de la entrada/salida de cada llamada a herramienta, cada trace exportado también lleva: el canal de origen (Telegram, la API, etc.) como metadato del trace; la clave de sesión como `session.id`; un `user.id` que toma el nombre visible de quien mandó el mensaje siempre que el canal pueda darlo (en Telegram, incluida una conversación privada, no solo la etiqueta del grupo; en WhatsApp, del perfil del contacto; también en Google Chat, Microsoft Teams y Discord), y que cae de vuelta a la clave de sesión cuando el canal no tiene ese dato, de modo que una ejecución dentro de una sesión compartida (un grupo de Telegram o de un webhook) queda atribuida a quien realmente la mandó, y no a un id único para toda la conversación; la versión de Pepe que está corriendo (`langfuse.release`); un nivel (`DEFAULT`/`WARNING`/`ERROR`) que depende de cómo terminó realmente la ejecución; y, en cada span de llamada al modelo, el costo de esa llamada en tu moneda configurada, calculado igual que en el libro de uso, y que se omite por completo en vez de aparecer como un cero engañoso cuando el modelo no tiene un precio conocido. El tiempo de cada paso en una vista en cascada (una llamada a herramienta, una generación del modelo) refleja el momento en que realmente ocurrió, no una estimación.

<div class="note"><strong>Es diagnóstico, no un registro de facturación.</strong> Los traces existen para explicar una ejecución, y los más viejos o los más pesados se van recortando con el tiempo. Para conteos de tokens y costos que puedas facturar, usa el <a href="../billing/">libro de uso</a>, que es un registro aparte y nunca pierde una entrada.</div>
