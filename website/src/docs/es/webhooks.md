---
title: Webhooks
description: Configura Slack, Discord, Microsoft Teams, Google Chat y canales webhook genéricos.
---

## Cómo funciona un canal por webhook

Sea cual sea la plataforma, todo canal por webhook queda expuesto en una única ruta:

```
https://YOUR_HOST/webhooks/<project>/<provider>/<slug>
```

- `<project>` es el proyecto al que pertenece la conexión. Usa `default` para el proyecto por defecto, o el slug de otro proyecto para dejar esa conexión aislada dentro de él.
- `<provider>` es el nombre de la plataforma: `whatsapp`, `slack`, `discord`, `msteams` o `googlechat`.
- `<slug>` es el nombre único que le pusiste a la conexión.

Un `GET` a esa URL responde al handshake de verificación del proveedor (Pepe simplemente devuelve el desafío que la plataforma manda la primera vez que registras la URL). Un `POST` es un evento entrante: ahí Pepe resuelve la conexión, verifica la firma de la petición contra el secreto que configuraste, extrae el mensaje, corre el agente vinculado y entrega la respuesta a través de la propia API del proveedor. El trabajo del agente corre en segundo plano para que la plataforma reciba su acuse de inmediato, ya que proveedores como Meta reintentan un webhook que tarda demasiado.

Hay una sola ruta genérica para todo esto. Agregar un proveedor nuevo nunca implica agregar un endpoint nuevo.

<div class="note"><strong>Host público.</strong> Los canales por webhook necesitan una URL a la que la plataforma pueda llegar. Expón tu instancia de Pepe detrás de un proxy inverso o un túnel. Si <code>PHX_HOST</code> ya está definido (ver <a href="../deploy/">Desplegar en un servidor</a>), las URL de retorno ya salen bien; define <code>PEPE_PUBLIC_URL</code> para sobrescribir eso o completarlo cuando no lo esté. Si solo necesitas un túnel rápido para probar, corre <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estos proveedores se configuran a través del asistente guiado (o desde el panel), que pide exactamente los campos que necesita cada uno e imprime la URL de retorno que hay que registrar:

```bash
pepe setup
```

Elige la opción de canal, escoge el proveedor y el agente, y carga las credenciales (cualquier secreto acepta una referencia `${ENV_VAR}`). Cada proveedor tiene su propia página con los campos y pasos que le son específicos: [Slack](../slack/), [Discord](../discord/), [Microsoft Teams](../msteams/), [Google Chat](../googlechat/). Esta página cubre lo que todos ellos tienen en común (y que comparten también con WhatsApp).

## @Menciones en grupo

Slack, Discord (en su modo conectado por gateway, ver [Discord](../discord/)), Microsoft Teams y Google Chat admiten conversaciones de grupo y de canal. Allí el bot solo contesta cuando lo @mencionan (un mensaje directo siempre le llega al agente). Un canal que debe contestar a todo, como el que recibe tickets de otro sistema, se configura desde dentro:

```text
/mention off          # contesta sin mención, hasta /new
/mention on           # vuelve a exigir mención, hasta /new
/mention off always   # contesta sin mención, se mantiene tras /new y al reiniciar
/mention on always    # vuelve a exigir mención para siempre (el valor por defecto)
/mention              # muestra lo que rige aquí
```

Un `/mention off` o `/mention on` simple vale para esta conversación y se olvida con `/new`. Con `always`, queda guardado para el canal, sea cual sea el agente que conteste en él. Lo dicho en la conversación gana a lo guardado para el canal, y `/new` devuelve la decisión al canal. Un ajuste nunca llega a otro canal.

La regla tiene dos niveles, como todo ajuste de canal. La **conexión** guarda el valor por defecto para todos sus canales: *Responder sin que lo mencionen* en el formulario de la conexión del panel (`mention_optional` en la configuración, `pepe gateway mention SLUG --set optional|required` en la línea de comandos), apagado hasta que lo enciendas. Un **canal** puede tener su propia respuesta, en cualquier sentido, y esa gana solo en ese canal: `/mention off always` abre un canal de una conexión que exige mención, `/mention on always` cierra un canal de una conexión que contesta a todo. Cuando la respuesta del canal solo repetiría el valor por defecto de la conexión, `/mention on always` se limita a quitar el ajuste propio del canal. Lo que rige, de más fuerte a más débil: esta conversación (hasta `/new`), el ajuste propio del canal, el valor por defecto de la conexión y, por último, mención obligatoria. `/mention` a secas dice cuál de ellos está en vigor. La fila de cada canal en la página Channels muestra lo mismo, con la etiqueta *propio* o *de la conexión* y un camino de vuelta al de la conexión; `pepe gateway mention SLUG --channel C --set optional|required` y `--default` lo hacen desde la línea de comandos. El modelo no puede cambiar nada de esto.

Un canal que contesta sin mención igualmente se mantiene al margen de un mensaje escrito para otra persona. En Slack, Discord, Microsoft Teams y Google Chat, un mensaje que menciona a una persona, a un grupo de usuarios o a todo el canal (`@here`, `@channel`) y no menciona al bot es para ellos, así que el bot lo omite; mencionar al bot, solo o junto a otros, lo hace volver. Un mensaje de otra aplicación queda exento, porque la tarjeta de un ticket puede nombrar a personas y seguir siendo trabajo del agente.

Como un comando de canal igual necesita estar dirigido al bot para poder ejecutarse, el *primer* `/mention off` necesita una @mención de verdad (`@bot /mention off`). Después, el canal ya no la necesita. WhatsApp no filtra por menciones (contesta a todo), así que ahí `/mention` no hace nada.

Cambiarlo queda reservado a los **trainers** del canal (la misma lista de confianza que usa `/agent`), porque cambia el comportamiento del canal para todos los que están en él. Cualquiera puede seguir enviando `/mention` para ver la configuración actual.

<div class="note"><strong>Escribir un comando en Slack.</strong> El propio cliente de Slack trata cualquier cosa que empiece con <code>/</code> como un intento de ejecutar uno de sus propios comandos de barra, y directamente se niega a enviarla como mensaje si no hay ninguno registrado con ese nombre - así que <code>/mention off</code> escrito tal cual llega a ser rechazado por el propio Slack antes de que le llegue a Pepe. Escribe un espacio antes de la barra (<code> /mention off</code>) para mandarlo como texto normal; Pepe quita ese espacio antes de comparar con el comando, tal como siempre hizo.</div>

## Quién puede entrenar un canal

`trainers` en la conexión indica quién puede convertir una conversación en memoria, y también quién puede cambiar `/agent`, `/model ... global`, `/mention` y este mismo ajuste. Vale para todos los canales de la conexión. Cuando un canal necesita otra regla, dale su propia lista desde dentro:

```text
/trainers                  # muestra quién puede entrenar aquí y de dónde viene
/trainers *                # todos en este canal
/trainers none             # nadie
/trainers @ana @bruno      # solo estas personas (una mención de Slack o un id)
/trainers default          # vuelve a la lista de la conexión
```

La lista propia de un canal manda: **reemplaza** a la de la conexión solo en ese canal, no se suma a ella. Solo quien ya puede entrenar el canal puede cambiarla, así que nadie se asciende a sí mismo. Se mantiene tras `/new` y al reiniciar. El modelo no puede cambiarla: es una decisión de una persona, escrita en el chat, en el panel (la lista de canales de cada conexión, ver más abajo) o con `pepe gateway trainers SLUG --channel C --set ...`.

En Slack los trainers son las personas (sus ids de usuario), porque cada mensaje ahora indica quién lo escribió. Una lista que nombraba el id del canal sigue funcionando.

## Dónde vive cada conexión

En la página Channels del panel, la tarjeta de cada conexión dice de cuántos canales, grupos y mensajes directos ya recibió mensajes ("12 canales"). Ábrela para verlos: el nombre, cuando la plataforma lo dio (si no, el id), si es un grupo o un mensaje directo, y cuándo llegó el último mensaje. Un canal entra en la lista desde el primer mensaje que llega por él, haya respondido el bot o no, así que un canal donde el bot solo escucha también aparece.

Cada fila trae los ajustes propios de ese canal, que cambias ahí mismo:

- **Agente**: el agente al que está vinculado el canal, el mismo vínculo que `/agent` crea en el chat, o el de la conexión mientras no tenga uno.
- **Mención**: la respuesta propia del canal a "¿necesita @mención?", o el valor por defecto de la conexión mientras no tenga una (ver [@Menciones en grupo](#menciones-en-grupo)). Solo para proveedores que filtran por mención.
- **Quién puede entrenar**: los entrenadores propios del canal (ver arriba), o los de la conexión mientras no tenga lista propia.

Cada ajuste lleva la etiqueta *propio* cuando el canal tiene valor propio y *de la conexión* cuando hereda el valor por defecto; *Usar el de la conexión* quita solo el valor propio del canal. Un mensaje directo también es un canal, listado y configurable del mismo modo.

El nombre llega con el mensaje en Microsoft Teams, Google Chat, WhatsApp (el nombre del contacto) y Telegram (el título del grupo). En Slack se consulta una vez, con el primer mensaje que llega del canal, y necesita el permiso `channels:read` (`groups:read` para un canal privado); sin él se muestra el id. Los mensajes directos de Slack muestran su id.

La tarjeta de un bot de Telegram lista del mismo modo sus grupos, temas de foro y chats privados, solo con el vínculo de agente: en Telegram, la mención y los entrenadores se fijan por bot.

## Vincular un canal a un agente

`/agent NOMBRE` vincula esta conversación a un agente de forma permanente - un grupo puede enrutar su canal de "soporte" al agente de soporte y el de "ingeniería" al ingeniero, uno al lado del otro, igual que ya puede hacerlo un tema de foro de Telegram (ver [Telegram](../telegram/)). Se mantiene después de `/new` y de reinicios, y se reafirma en cada mensaje, así que siempre gana, sin importar a dónde haya ido la conversación mientras tanto:

```text
/agent ingeniero   # vincula este canal, desde ahora
/agent             # muestra el vínculo actual
/agent none        # desvincula, vuelve al agente predeterminado de la conexión
```

Es una decisión permanente, que afecta a todo el canal, no una elección puntual de enrutamiento - por eso está reservada a **entrenadores** (la misma lista de confianza que ya controla `/model ... global`); cualquier otra persona solo recibe un "no tienes permiso". Un agente con la herramienta `manage_channel` puede hacer lo mismo en lenguaje natural ("vincula este canal al ingeniero, de forma permanente") con sus acciones `bind_topic`/`unbind_topic` - ver [Enrutamiento entre agentes](../routing/) para la diferencia entre esto y `switch_agent`, que es temporal a propósito y que el `/new` sí deshace.

Para un canal donde nadie debería poder cambiar qué agente contesta - ni de forma temporal ni permanente - pon `agent_switch_locked: true` en la conexión. Rechaza directamente `/agent NOMBRE`, incluso para un entrenador, además de `switch_agent` y las acciones `bind_topic`/`unbind_topic` de `manage_channel`, en cualquier conversación de esa conexión. `/agent` sin argumento (estado), `/mention`, `/model` y `/new` siguen funcionando con normalidad. Se pone con `--agent-switch-locked` en `mix pepe gateway whatsapp add` / `discord add`, o directamente en el `config.json`.

## Cambiar de modelo

Los comandos `/model` y `/models` dejan que cualquiera consulte o cambie qué modelo de IA le responde. Solo funcionan en una conexión con modo `admin` que tenga `commands` habilitado (revisa la comparación de modos en [Channels](../channels/)); en modo `support` se tratan como texto normal. `/models` lista los modelos disponibles para el proyecto de esa conexión; `/model` muestra el actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo esta conversación
/model openrouter global        # cambia para todas las conversaciones de esta conexión
```

Cambiarlo **globalmente**, para todo lo que atiende esa conexión, queda reservado a los **entrenadores** (la misma lista de confianza que controla la memoria); cualquier otra persona en una conversación permitida solo puede cambiar su propia conversación. Pon `model_switch_locked: true` en la conexión si quieres apagar esto por completo para quien no sea entrenador. Es el mismo mecanismo que usa WhatsApp; la versión de Telegram añade, además, un selector con botones en vez de comandos escritos.

## Aprobar herramientas de riesgo en el chat

Por defecto, un canal por webhook no tiene a nadie a quien preguntar, así que una herramienta de riesgo que no está en el `auto_approve` del agente se rechaza y queda guardada para que un operador la apruebe desde la línea de comandos (`mix pepe approvals`). Para que las personas de la conversación lo decidan ahí mismo, indica los **trainers** en la conexión: una lista explícita, o `["*"]` para todos los de la conversación. Entonces, cuando el agente quiere hacer algo arriesgado, pregunta en el propio chat, muestra el comando real y espera una respuesta escrita:

```text
Reply with: allow / allow all / allow session / deny
```

Solo cuenta la respuesta exacta de un trainer, y no se le pasa al agente como mensaje. La respuesta de cualquier otra persona, o una frase más larga que contenga "allow", es solo un mensaje. Las dos respuestas más amplias ("permitir todo en la sesión" y "siempre") no se pueden escribir aquí; usa una superficie con botones para esas. Si nadie responde en cinco minutos, cuenta como un no, y al agente se le avisa de que nadie respondió, en lugar de que se rechazó.

Sin trainers indicados no cambia nada: solo corre lo que el agente ya tiene preaprobado.

## Por dentro: el contrato del proveedor

Cada canal por webhook es un módulo pequeño que implementa el mismo contrato, así que todos se comportan de manera consistente y agregar una plataforma nueva es agregar un módulo, no una ruta nueva. Las funciones de ese contrato son:

- `name` y `label`: el segmento de URL del proveedor y su nombre legible para personas.
- `config_schema`: los campos que el panel muestra para configurar una conexión.
- `verify`: responder al handshake de verificación del `GET`.
- `authenticate`: verificar la firma de un `POST` entrante contra el secreto de la conexión y el cuerpo crudo de la petición. Una petición que no pasa esta verificación se descarta.
- `parse`: normalizar la carga de la plataforma en cero o más mensajes simples. Las actualizaciones de estado y los acuses de entrega se ignoran.
- `respond` (opcional): producir una respuesta síncrona cuando el protocolo la exige antes de cualquier trabajo del agente, como el desafío `url_verification` de Slack o el ping con acuse diferido de Discord.
- `deliver`: mandar de vuelta una respuesta en texto al remitente.
- `deliver_file` (opcional): mandar un archivo como adjunto.

Si escribes un plugin que implemente este contrato, queda registrado como un proveedor nuevo bajo su propio `name`, accesible en esa misma ruta `/webhooks/...`, sin necesidad de cablear nada extra.
