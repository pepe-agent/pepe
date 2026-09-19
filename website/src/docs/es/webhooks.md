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

<div class="note"><strong>Host público.</strong> Los canales por webhook necesitan una URL a la que la plataforma pueda llegar. Expón tu instancia de Pepe detrás de un proxy inverso o un túnel, y define <code>PEPE_PUBLIC_URL</code> para que las URL de retorno que imprime la línea de comandos queden completas. Si solo necesitas un túnel rápido para probar, corre <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estos proveedores se configuran a través del asistente guiado (o desde el panel), que pide exactamente los campos que necesita cada uno e imprime la URL de retorno que hay que registrar:

```bash
pepe setup
```

Elige la opción de canal, escoge el proveedor y el agente, y carga las credenciales (cualquier secreto acepta una referencia `${ENV_VAR}`). Cada proveedor tiene su propia página con los campos y pasos que le son específicos: [Slack](../slack/), [Discord](../discord/), [Microsoft Teams](../msteams/), [Google Chat](../googlechat/). Esta página cubre lo que todos ellos tienen en común (y que comparten también con WhatsApp).

## @Menciones en grupo

Slack, Microsoft Teams y Google Chat admiten conversaciones de grupo o canal, donde por defecto la conexión solo contesta si la @mencionan (un mensaje directo, en cambio, siempre le llega al agente sin importar este ajuste). Pon `require_mention: false` en la conexión si quieres que responda a todos los mensajes en todos los canales donde participa. O, sin tocar ese ajuste general de la conexión, haz la excepción para un solo canal, desde dentro de ese mismo canal:

```text
/mention off   # solo en este canal, hasta /new - no hace falta @mencionarlo para que responda
/mention on    # vuelve a exigir una @mención
/mention       # muestra el ajuste actual
```

Como un comando de canal igual necesita estar dirigido al bot para poder ejecutarse, el *primer* `/mention off` sí necesita una @mención de verdad (`@bot /mention off`); después de eso, ese canal deja de necesitarla hasta el próximo `/new`. La excepción queda guardada en la conversación de ese canal puntual, no en la conexión, así que nunca se cuela en ningún otro canal. WhatsApp y Discord, por ahora, no filtran por menciones (siempre contestan), así que ahí `/mention` no hace nada.

## Cambiar de modelo

Los comandos `/model` y `/models` dejan que cualquiera consulte o cambie qué modelo de IA le responde. Solo funcionan en una conexión con modo `admin` que tenga `commands` habilitado (revisa la comparación de modos en [Channels](../channels/)); en modo `support` se tratan como texto normal. `/models` lista los modelos disponibles para el proyecto de esa conexión; `/model` muestra el actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo esta conversación
/model openrouter global        # cambia para todas las conversaciones de esta conexión
```

Cambiarlo **globalmente**, para todo lo que atiende esa conexión, queda reservado a los **entrenadores** (la misma lista de confianza que controla la memoria); cualquier otra persona en una conversación permitida solo puede cambiar su propia conversación. Pon `model_switch_locked: true` en la conexión si quieres apagar esto por completo para quien no sea entrenador. Es el mismo mecanismo que usa WhatsApp; la versión de Telegram añade, además, un selector con botones en vez de comandos escritos.

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
- `fetch_media` (opcional): bajar un adjunto entrante que `parse` solo describió, y devolver sus bytes. Todo lo que viene después de la descarga (transcribir, leer un documento, pasarle una imagen a un modelo con visión) es compartido. Un provider sin este callback le avisa al remitente que el canal no recibe adjuntos, en vez de descartar el archivo en silencio.

Si escribes un plugin que implemente este contrato, queda registrado como un proveedor nuevo bajo su propio `name`, accesible en esa misma ruta `/webhooks/...`, sin necesidad de cablear nada extra.
