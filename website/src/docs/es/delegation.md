---
title: Delegación (fan-out)
description: La herramienta delegate reparte un trabajo amplio entre workers paralelos y desechables, cada uno con su propia ventana de contexto, de modo que el conjunto tarda lo que tarda la parte más lenta y no la suma de todas.
---

"Compara estos ocho competidores" no es una tarea sino ocho, y resolverlas dentro de una sola conversación sale caro por partida doble: tarda ocho veces más, y cada página que leíste para el competidor uno se queda ocupando la ventana de contexto mientras el modelo todavía anda leyendo sobre el competidor ocho. La ventana termina llena de material que nadie va a volver a mirar, y la respuesta final sale peor por eso mismo.

`delegate` reparte esas partes entre workers desechables, todos a la vez:

```
tú › compara las páginas de precios de stripe, adyen y mollie

agente › delegate(tasks: [
           "Lee stripe.com/pricing e informa de la comisión por tarjeta y de cualquier mínimo mensual.",
           "Lee adyen.com/pricing e informa de la comisión por tarjeta y de cualquier mínimo mensual.",
           "Lee mollie.com/pricing e informa de la comisión por tarjeta y de cualquier mínimo mensual."
         ])
```

Cada worker arranca de cero, con su propia ventana de contexto y su propio trace: lee lo que necesita, contesta exactamente lo que le preguntaron y desaparece. Al agente que delegó le llegan las tres respuestas, nunca las tres transcripciones completas, de modo que el trabajo entra en una ventana donde antes no habría cabido. Y como los workers están esperando a la red al mismo tiempo, el conjunto entero tarda lo que tarda el más lento, no la suma de los tres.

## Darle la herramienta a un agente

Se concede `delegate` igual que cualquier otra herramienta, en la lista de tools:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## Un worker puede leer, no puede actuar

Un worker solo hereda las herramientas que no necesitan permiso: `read_file`, `list_dir`, `fetch_url`, `web_search` y afines. Todo lo que escribe, ejecuta, instala o borra queda fuera antes incluso de que el worker arranque, y ningún worker puede a su vez delegar en otros.

No es una restricción provisional pensada para levantarse más adelante. Si tres workers corrieran a la vez, serían tres workers pidiéndote permiso al mismo tiempo, y *¿puedo ejecutar esto?* no es una pregunta que tenga sentido triplicada. Yendo al fondo del asunto: el fan-out sirve para **investigar**, y investigar en paralelo es seguro. **Actuar** no lo es, así que se queda donde debe quedarse, en la única conversación que de verdad estás siguiendo. Si un worker descubre algo que hay que hacer, lo reporta, y es quien delegó el que lo ejecuta, pasando por la barrera de permisos, delante de ti.

La segunda salvaguarda es puramente aritmética: sin la regla de "un worker no puede delegar", una tarea se multiplica a ocho, luego a sesenta y cuatro, y la factura te llega antes que la respuesta.

<div class="note"><strong>Tope fijo de ocho tareas por llamada.</strong> El modelo conoce ese tope de antemano, así que reparte el trabajo en función de él en vez de chocar con el límite sin avisar.</div>

## Delegar con la identidad de otro agente

```
delegate(tasks: [...], agent: "researcher")
```

Así los workers corren como un agente distinto, con su persona y sus herramientas propias, igual de despojadas de todo lo que actúa. Rige la misma lista de rutas permitidas que usa `send_to_agent`: un agente solo puede tomar prestada la identidad de otro si ya tenía autorización para enviarle mensajes. Una sola autoridad gobierna quién puede actuar, no dos, una fuerte y otra más débil. Las rutas entre agentes se explican en [Agentes](../agents/).

## Sin quedarse esperando

```
delegate(tasks: [...], background: true)
```

El mismo reparto de tareas, pero disparado sin esperar respuesta: la llamada vuelve al instante con un acuse de recibo, el agente puede seguir trabajando o avisarte que ya se está ocupando del tema, y los resultados llegan más tarde como un mensaje de seguimiento normal en la misma conversación, en cuanto todos los workers terminen. Conviene recurrir a esto cuando el fan-out va a tardar de verdad (varias páginas por leer, un worker con trabajo de razonamiento real por delante); si son solo unos segundos de espera, es más simple dejarlo así, sin necesitar ninguna explicación para quien está del otro lado. Y solo funciona dentro de una conversación real: una ejecución de un solo turno no tiene sesión donde entregar los resultados después.

## Lo que cuesta

Cada worker es una llamada de modelo real, medida y facturada igual que cualquier otra, contra el mismo proyecto. Ocho workers son ocho turnos completos. Ese es el trato: compras tiempo de reloj y espacio en la ventana de contexto pagando en tokens. Para una tarea que de otro modo ni siquiera habría entrado en una sola ventana, en realidad no hay mucho que negociar.

Cada worker deja su propio trace, así que la sección **Traces** del [panel](../dashboard/) muestra lo que hizo cada uno de verdad, no solo lo que el agente delegante contó después.
