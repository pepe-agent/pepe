---
title: Flows
description: Cuando un agente ya repitió el mismo trabajo de la misma forma varias veces, convierte esa secuencia en un script que la reproduce paso a paso, sin ninguna llamada al modelo.
---

## Por qué existe esto

Cada turno, el agente vuelve a decidirlo todo desde cero, incluso en una tarea idéntica a otras tres que ya resolvió exactamente igual antes. Pagar ese costo tiene sentido las primeras veces, mientras todavía está descubriendo qué hacer. Deja de tenerlo en cuanto la secuencia ya es confiable: a partir de ahí, la llamada al modelo es puro gasto extra, y encima abre una posibilidad más de que la ejecución salga distinta a la anterior sin ningún motivo real.

Un **flow** convierte uno o varios [trace](../traces/) ya comprobados en un script fijo: las mismas llamadas a herramientas, en el mismo orden, con idénticos argumentos, que se reproducen sin pasar por el modelo. Nunca hace otra cosa que repetir lo ya ocurrido, argumento por argumento; no genera código nuevo ni adivina qué partes de una llamada se mantienen iguales y cuáles cambian.

## Promocionar un flow

Revisa unas cuantas ejecuciones recientes que hayan hecho lo mismo, de la misma forma:

```bash
pepe traces --project acme
```

Elige dos o más que llamaron a las mismas herramientas, en el mismo orden y con los mismos argumentos, y promuévelas:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

Antes de guardar nada, Pepe comprueba que todos los traces que nombraste hicieron realmente la misma secuencia exacta. Si algo no cuadra (un argumento distinto, un orden distinto, un paso de más en uno de ellos), rechaza la promoción y te dice por qué, en lugar de intentar adivinar qué querías decir:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

Ese rechazo es a propósito. Inferir automáticamente qué parte "varía" y cuál "no" a partir de un puñado de ejemplos es lo único genuinamente arriesgado de toda esta idea: si se equivoca, el flow termina haciendo, en silencio, algo que ninguno de sus traces de origen hizo jamás. Por eso un flow se limita a reproducir exactamente lo mismo; elegir traces que de verdad sean idénticos queda de tu lado, la misma revisión que haría cualquiera antes de dejar un script corriendo sin supervisión.

La promoción también rechaza un trace que no esté genuinamente "comprobado", aunque la secuencia coincida: por ejemplo, uno con una llamada que la propia barrera de permisos del agente denegó, un paso que de hecho falló, o argumentos tan largos que no se guardaron completos (`Pepe.Trace` recorta los que son demasiado extensos). En ninguno de esos casos viste tú mismo que la llamada funcionara. Tampoco acepta traces que no hayan sido hechos todos por el agente para el que estás promocionando, porque las rutas relativas de un paso reproducido se resuelven dentro del workspace de *ese* agente en concreto.

## Gestionar flows

```bash
pepe flow list --agent assistant                 # todos los flows de ese agente
pepe flow show assistant weekly-digest            # los pasos exactos que reproduce
pepe flow run assistant weekly-digest             # lo ejecuta ahora
pepe flow remove assistant weekly-digest
```

Volver a promocionar con el mismo nombre se rechaza a menos que agregues `--overwrite`; así, una promoción nueva jamás reemplaza en silencio un flow ya existente.

## Ejecutar con una programación

Un flow se vuelve una tarea recurrente igual que un prompt, mediante cron, solo que sin prompt y sin ninguna llamada al modelo:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Esto crea una tarea programada (mira [Tareas programadas](../scheduled/)) de tipo `"flow"` en lugar de `"prompt"`. En todo lo demás, cómo se dispara, qué pasa si la ejecución anterior sigue corriendo y dónde queda su historial, funciona igual que cualquier otra tarea programada.

<div class="note"><strong>Nadie supervisa la ejecución de un flow en vivo.</strong> Un flow se dispara desde un temporizador, no desde una conversación, así que no hay nadie disponible para aprobar un paso arriesgado en el momento. Por eso solo ejecuta un paso cuya herramienta ya figure en el propio <code>auto_approve</code> del agente, la misma regla que gobierna cualquier otra superficie sin supervisión (un webhook, un token de API). Si un paso no está preaprobado, o si falla de verdad al reproducirse (falta un archivo, hay un problema de red, los argumentos son incorrectos), todo el flow se detiene ahí mismo en lugar de saltárselo o seguir adelante a ciegas; el historial deja constancia exacta de qué paso fue y por qué.</div>

Cada ejecución de un flow sigue generando un [trace](../traces/) normal, así que el historial de un flow programado se puede revisar exactamente igual que el de cualquier otra ejecución.
