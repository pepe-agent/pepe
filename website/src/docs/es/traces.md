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

Enviar a [Langfuse](../langfuse/) no necesita nada más que las credenciales
que la mayoría de las instalaciones ya tienen definidas para él
(`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`): cada ejecución terminada se
convierte en un trace OTLP en cuanto están presentes, desactivado en caso
contrario, y un fallo en el envío nunca afecta a la ejecución que describe.

Para cualquier otro backend que hable OTLP, define
`OTEL_EXPORTER_OTLP_ENDPOINT` en su lugar, y este toma el control por
completo:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://tu-colector.ejemplo.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 de usuario:contraseña>"
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

Además de la pregunta/respuesta de la ejecución y la entrada/salida de cada
llamada a herramienta, cada trace exportado también lleva: el canal del que
vino (Telegram, la API...) como metadato del trace; la clave de sesión como
`session.id`; el `user.id`, ajustado al nombre visible de quien realmente
envió el mensaje siempre que el canal pueda darlo (Telegram, incluida una
conversación privada, no solo su marca de grupo; WhatsApp, a partir del
perfil del contacto; Google Chat; Microsoft Teams; Discord), volviendo a la
clave de sesión en una superficie sin ese nombre disponible, de modo que una
ejecución en una sesión compartida (un grupo de Telegram o de un webhook)
queda atribuida a quien realmente la envió, en vez de un único id
compartido para toda la conversación; la versión de Pepe en ejecución
(`langfuse.release`); un nivel (`DEFAULT`/`WARNING`/`ERROR`) derivado de
cómo terminó realmente la ejecución; y, en cada span de llamada a modelo, el
coste de esa llamada en tu moneda configurada, calculado de la misma forma
que lo calcula el libro de uso, y omitido por completo en vez de enviado
como un cero engañoso cuando el modelo no tiene un precio conocido. El
tiempo de cada paso en una vista en cascada (una llamada a herramienta, una
generación de modelo) refleja cuándo ocurrió realmente, no una estimación.

<div class="note"><strong>Diagnóstico, no registro de facturación.</strong> Los traces existen para explicar una ejecución, y los antiguos o demasiado grandes se van recortando. Para recuentos de tokens y coste que puedas facturar, usa el <a href="../billing/">libro de uso</a>, separado, que nunca pierde una entrada.</div>
