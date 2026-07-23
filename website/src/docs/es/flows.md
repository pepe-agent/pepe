---
title: Flows
description: Promociona una secuencia de llamadas a herramientas comprobada y repetida a un script que se reproduce sin llamar al modelo.
---

## Por qué existe esto

Un agente decide todo desde cero, cada turno, incluso en una tarea que ya hizo exactamente de la misma forma tres veces seguidas. Vale la pena pagar por eso las primeras veces, mientras el agente está averiguando qué hacer. Deja de valer la pena en cuanto la secuencia ya es fiable: la llamada al modelo se vuelve puro costo en ese punto, y es un lugar más donde una ejecución puede salir distinta a la anterior sin motivo.

Un **flow** es un [trace](../traces/) comprobado (o varios) promocionado a un script fijo: las llamadas a herramientas exactas, en orden, con los mismos argumentos, reproducidas sin ninguna llamada al modelo. Solo repite lo que ya pasó, argumento por argumento - no genera código nuevo, ni intenta adivinar qué partes de una llamada son "lo mismo" y cuáles varían.

## Promocionar un flow

Mira algunas ejecuciones recientes que hicieron lo mismo de la misma forma:

```bash
pepe traces --project acme
```

Elige dos o más que hicieron las llamadas a herramientas idénticas, en el mismo orden, con los mismos argumentos, y promociónalas:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

Pepe comprueba que cada trace que indicaste realmente hizo la misma secuencia exacta antes de guardar nada. Si no coinciden - un argumento distinto, un orden distinto, un paso de más en una de ellas - la promoción se rechaza, con un mensaje que explica por qué, en vez de intentar adivinar qué quisiste decir:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

Ese rechazo es intencional. Inferir automáticamente "esta parte varía, esta no" a partir de un puñado de ejemplos es la única parte de esta idea que es realmente arriesgada - si se falla ahí, un flow pasa a hacer, en silencio, algo que ninguno de los traces de origen hizo jamás. Un flow sigue siendo réplica exacta y nada más; elegir traces que de verdad son idénticos es responsabilidad tuya, la misma revisión que haría una persona antes de confiar un script para que corra sin supervisión.

La promoción también rechaza un trace que no sea genuinamente "comprobado", aunque la secuencia coincida: uno que contenga una llamada que la propia barrera de permisos del agente denegó, un paso que de hecho falló, o argumentos demasiado largos como para haberse registrado completos (`Pepe.Trace` recorta los muy largos para almacenarlos) - nada de eso es una llamada que de verdad viste tener éxito. También rechaza traces que no fueron hechos todos por el agente para el que estás promocionando, ya que las rutas relativas de un paso reproducido se resuelven dentro del propio workspace de *ese* agente.

## Gestionar flows

```bash
pepe flow list --agent assistant                 # todos los flows de ese agente
pepe flow show assistant weekly-digest            # los pasos exactos que reproduce
pepe flow run assistant weekly-digest             # lo ejecuta ahora
pepe flow remove assistant weekly-digest
```

Promocionar de nuevo con el mismo nombre se rechaza a menos que pases `--overwrite`, así que una promoción nueva nunca reemplaza un flow existente en silencio.

## Ejecutar con una programación

Un flow se convierte en una tarea recurrente de la misma forma que un prompt - mediante cron, solo que sin prompt y sin llamada al modelo:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Esto crea una tarea programada (ver [Tareas programadas](../scheduled/)) de tipo `"flow"` en vez de `"prompt"`. Todo sobre cómo se dispara, qué pasa si la ejecución anterior sigue en curso, y dónde vive su historial de ejecuciones es igual que para cualquier otra tarea programada.

<div class="note"><strong>Nadie está observando la ejecución de un flow.</strong> Un flow se dispara desde un temporizador, no desde una conversación, así que no hay nadie ahí para aprobar un paso arriesgado en el momento. Un flow solo ejecuta un paso cuya herramienta ya está en el <code>auto_approve</code> del propio agente - la misma regla que ya rige cualquier otra superficie sin supervisión (un webhook, un token de API). Un paso que no está preaprobado, o un paso que de hecho falla al reproducirse (un archivo faltante, un tropiezo de red, argumentos incorrectos), detiene todo el flow ahí mismo en vez de saltarlo o seguir adelante - el historial de la ejecución dice exactamente qué paso y por qué.</div>

Cada ejecución de un flow sigue registrando un [trace](../traces/) normal, así que el historial de un flow programado se puede inspeccionar igual que el de cualquier otra ejecución.
