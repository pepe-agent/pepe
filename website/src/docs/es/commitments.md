---
title: Compromisos
description: Si alguien dice "recuérdamelo el viernes", o tu agente dice "lo reviso y te aviso", Pepe se da cuenta solo y cumple.
---

## Compromisos

A diferencia de cualquier otra automatización de Pepe, un compromiso no lo configuras tú: aparece solo, al terminar un turno, a partir de lo que de verdad se dijo, ya sea que el usuario pida que le recuerden algo o que el propio agente prometa revisar algo y volver con la respuesta. Hace falta activarlo por agente (la opción `commitments`, apagada por defecto) y asignarle un `utility_model` a ese agente; si falta cualquiera de los dos, no se extrae nada y la promesa se queda en pura palabrería.

### Dos formas de dar seguimiento, dos maneras distintas de resolverlas

Conviene entender esto antes de activar la función, porque Pepe no trata ambos casos de la misma manera:

- **Cuando el usuario pide que le recuerden algo** ("recuérdame mandar el informe el viernes"), basta un mensaje en el momento justo, exactamente lo que ya resuelve un [watch](../watches/). Si el agente cuenta con la tool `watch`, sigue siendo mejor que la use ahí mismo; los compromisos funcionan como la red que atrapa los casos en que no lo hizo.
- **Cuando es el agente el que promete algo** ("déjame revisar el deploy y mañana te cuento"), un simple recordatorio de que hizo esa promesa no sirve. Al llegar la hora, Pepe retoma esa misma sesión con una única instrucción: cumplir de verdad lo prometido y recién ahí contestar con el resultado. Lo que llega es una respuesta hecha y derecha, no una plantilla, para que ninguna promesa termine disolviéndose en un silencioso "recordatorio: dije que iba a revisar eso".

### Confianza, y qué pasa cuando no está claro

Un modelo económico lee el último intercambio y, con un puntaje de confianza, decide si hay ahí un compromiso real. Cuando ese puntaje es alto y además la fecha quedó clara, el compromiso se programa de una vez, sin pasos intermedios, tal como corresponde a algo que se detecta sin que nadie tenga que pedirlo dos veces. Si la confianza no alcanza, o si el plazo no se pudo deducir de lo dicho (un "en algún momento" no cuenta como fecha), el compromiso queda **esperando tu confirmación**: se te pregunta una sola vez, en vez de hacerle seguimiento en silencio a algo que en realidad nadie pidió.

### Gestionarlos desde el chat

El agente cuenta con la tool `commitment`, con tres acciones: `list` muestra lo que hay en seguimiento ahora mismo, `confirm id: <id>` confirma uno que está esperando (agrega también `due_when` si la fecha nunca se resolvió sola), y `cancel id: <id>` lo da de baja.

### Hacerlo desde el panel

En `pepe serve`, la página **Compromisos** agrupa todo lo que hay en seguimiento en tres columnas (esperando confirmación, programados y entregados), y desde ahí mismo puedes confirmar o cancelar cualquiera.

<div class="note"><strong>No hay servidor que levantar, es solo un archivo local.</strong> Los compromisos se guardan en un pequeño SQLite embebido al lado de <code>config.json</code>, nada que tengas que instalar ni administrar aparte. Se disparan con el mismo temporizador interno que ya usan los watches y las tareas programadas, y ese temporizador solo corre mientras hay alguna superficie de larga duración activa (<code>pepe serve</code>, un gateway o una sesión interactiva).</div>
