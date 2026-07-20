---
title: Compromisos
description: Seguimientos detectados automáticamente en la conversación - un recordatorio que pidió el usuario, o una promesa que hizo tu agente.
---

## Compromisos

Un compromiso es distinto de cualquier otra automatización de Pepe: no es algo que configuras. Se detecta solo, después de un turno, a partir de lo que realmente se dijo: el usuario pidiendo que le recuerden algo, o el propio agente prometiendo verificar algo y volver con la respuesta. Actívalo por agente (`commitments`, apagado por defecto) y dale a ese agente un `utility_model` - sin ambos, no se extrae nada, y una promesa se queda solo en palabras.

### Dos tipos de seguimiento, entregados de dos formas distintas

Este es el detalle que vale la pena entender antes de activarlo, porque los dos casos no se tratan igual:

- **El recordatorio del propio usuario** ("recuérdame enviar el informe el viernes") se resuelve con un mensaje en el momento adecuado - lo mismo que ya hace un [watch](../watches/). Si tu agente tiene la tool `watch`, sigue valiendo la pena que la use directamente en ese momento; los compromisos existen como red de seguridad para cuando no lo hace.
- **La promesa del propio agente** ("déjame revisar el deploy y te aviso mañana") *no* se resuelve con un recordatorio que diga que se hizo la promesa. Cuando llega la hora, Pepe vuelve a ejecutar esa sesión con una instrucción: hacer de verdad lo que se prometió, y solo entonces responder con lo que encontró. El mensaje que se envía es una respuesta real, no una plantilla fija - así una promesa nunca se convierte silenciosamente en un "recordatorio: dije que iba a revisar eso".

### Confianza, y qué pasa cuando no está claro

Una llamada barata a un modelo lee el último intercambio y decide si hay un compromiso genuino, con una puntuación de confianza. Si es lo bastante alta, y el plazo se resolvió, el compromiso queda programado directamente - sin paso extra, en línea con "detectarlo sin que se lo pidan dos veces". Por debajo de eso, o cuando el plazo no se pudo resolver a partir de lo dicho (un vago "en algún momento" no es una fecha), queda **esperando tu confirmación**: se te pregunta directamente, una vez, en vez de rastrear en silencio algo que nadie pidió de verdad.

### Gestionarlos desde el chat

La tool `commitment` del agente tiene tres acciones: `list` (lo que se está siguiendo ahora), `confirm id: <id>` (promueve uno que está esperando - pasa también `due_when` si la fecha nunca se resolvió), y `cancel id: <id>`.

### Hacerlo desde el panel

Abre la página **Compromisos** en `pepe serve` para ver todo lo que se está siguiendo, agrupado en esperando confirmación, programados y entregados. Confirma o cancela directamente desde ahí.

<div class="note"><strong>Sin base de datos, sin almacenamiento aparte.</strong> Los compromisos son registros simples en <code>~/.pepe/config.json</code> (en la sección <code>"commitments"</code>), disparados por el mismo tipo de temporizador interno que ya mueve los watches y las tareas programadas - solo funciona mientras una superficie de larga duración (<code>pepe serve</code>, un gateway, o una sesión interactiva) esté activa.</div>
