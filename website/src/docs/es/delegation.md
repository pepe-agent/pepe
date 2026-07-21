---
title: Delegación (fan-out)
description: La herramienta delegate divide un trabajo amplio en workers paralelos desechables, cada uno con su propia ventana de contexto nueva, así que el conjunto tarda lo que tarda la parte más lenta, no la suma.
---

"Compara estos ocho competidores" no es una tarea, son ocho, y hacerlo en una sola conversación te cuesta el doble. Tarda ocho veces más. Y cada página que se descargó para el competidor uno sigue ocupando la ventana de contexto mientras el modelo lee sobre el competidor ocho, así que la ventana se llena de material que nadie va a volver a mirar, y la respuesta final empeora con ello.

La herramienta `delegate` entrega las partes a workers desechables, todas a la vez:

```
tú › compara las páginas de precios de stripe, adyen y mollie

agente › delegate(tasks: [
           "Lee stripe.com/pricing e informa de la comisión por tarjeta y de cualquier mínimo mensual.",
           "Lee adyen.com/pricing e informa de la comisión por tarjeta y de cualquier mínimo mensual.",
           "Lee mollie.com/pricing e informa de la comisión por tarjeta y de cualquier mínimo mensual."
         ])
```

Cada worker es una ejecución nueva, con su propia ventana de contexto y su propio trace. Lee lo que necesita, responde a la pregunta que le dieron y desaparece. El padre recibe tres respuestas y nunca ve las tres transcripciones, así que el trabajo cabe en una ventana en la que antes no habría cabido. Y como los workers esperan a la red al mismo tiempo, el conjunto tarda lo que tarda el más lento, no la suma.

## Darle la herramienta a un agente

Concedes `delegate` como siempre, en la lista de herramientas:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## Un worker puede leer; no puede actuar

Un worker hereda solo las herramientas que no piden permiso: `read_file`, `list_dir`, `fetch_url`, `web_search` y similares. Todo lo que escribe, ejecuta, instala o borra se le retira antes de que el worker arranque, y un worker no puede volver a delegar.

Esto no es una limitación a la espera de levantarse. Tres workers corriendo a la vez son tres workers que querrían hacerte tres preguntas a la vez, y *¿puedo ejecutar esto?* no es una pregunta para hacerse por triplicado. Y más al grano: el fan-out sirve para **averiguar**, y averiguar es seguro de hacer en paralelo. **Actuar** no lo es, y se queda donde le corresponde, en la única conversación que de verdad estás mirando. Un worker que descubre que hay algo que hacer lo dice, y el padre lo hace, en la barrera de permisos, delante de ti.

La otra protección es aritmética. Sin el "un worker no puede delegar", una tarea se convierte en ocho, en sesenta y cuatro, y la factura llega antes que la respuesta.

<div class="note"><strong>Un tope duro de ocho tareas por llamada.</strong> Al modelo se le avisa del tope, así que reparte el trabajo en vez de que este lo pille por sorpresa.</div>

## Delegar como otro agente

```
delegate(tasks: [...], agent: "researcher")
```

Esto ejecuta los workers como un agente distinto, con la persona y las herramientas de ese agente, igualmente despojadas de todo lo que actúa. Obedece a la misma lista de permisos dirigida que `send_to_agent`: un agente solo puede tomar prestada la identidad de otro si ya tenía permiso para escribirle. Una autoridad para el acto, no una segunda y más débil. Las rutas se explican en la página [Agentes](../agents/).

## Sin esperar la respuesta

```
delegate(tasks: [...], background: true)
```

El mismo reparto de tareas, pero sin esperar: la llamada vuelve enseguida con un acuse de recibo, así el agente puede seguir trabajando o avisarte de que ya se está ocupando, y los resultados llegan después como un mensaje de seguimiento normal en la misma conversación en cuanto todos los workers terminan. Vale la pena usarlo cuando el reparto es genuinamente lento (varias páginas por leer, un worker con verdadero trabajo de razonamiento por delante); esperar unos segundos sigue siendo más simple y no necesita explicación para el usuario. Solo funciona dentro de una conversación real: una ejecución de un solo turno no tiene sesión a la que entregarle los resultados.

## Lo que cuesta

Cada worker es una llamada de modelo real, medida y facturada como cualquier otra, al mismo proyecto. Ocho workers son ocho turnos. Ese es el trato: estás recomprando tiempo de reloj y sitio en la ventana de contexto, y lo pagas en tokens. Para una tarea que no habría cabido en una sola ventana, ni siquiera llega a ser un trato.

Cada worker tiene su propio trace, así que **Traces** en el [panel](../dashboard/) muestra lo que hizo realmente cada uno, no solo lo que el padre dijo de ello.
