---
title: Webhooks
description: Configura Slack, Discord, Microsoft Teams, Google Chat y canales webhook genéricos.
---

## Cómo funciona un canal por webhook

Todo canal por webhook, sea cual sea la plataforma, es accesible en una sola
ruta:

```
https://YOUR_HOST/webhooks/<project>/<provider>/<slug>
```

- `<project>` es el ámbito de cliente. Usa `default` para el proyecto por
  defecto, o el slug de otro proyecto para aislar una conexión a ese cliente.
- `<provider>` es el nombre de la plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` o `googlechat`.
- `<slug>` es el nombre único que le diste a la conexión.

Un `GET` a esa URL responde al handshake de verificación del proveedor (Pepe
devuelve el desafío que la plataforma envía cuando registras la URL por primera
vez). Un `POST` es un evento entrante. En un `POST`, Pepe resuelve la conexión,
verifica la firma de la petición contra el secreto que configuraste, extrae el
mensaje, ejecuta el agente vinculado y entrega la respuesta a través de la
propia API del proveedor. El trabajo del agente se ejecuta en segundo plano para que
la plataforma reciba su acuse de inmediato (proveedores como Meta reintentan un
webhook lento).

Hay una única ruta genérica. Añadir un nuevo proveedor nunca añade un nuevo
punto de acceso.

<div class="note"><strong>Host público.</strong> Los canales por webhook
necesitan una URL que la plataforma pueda alcanzar. Expón tu instancia de Pepe
detrás de un proxy inverso o un túnel, y define <code>PEPE_PUBLIC_URL</code> para
que las URL de retorno que imprime la línea de comandos estén completas. Para un
túnel rápido durante las pruebas, ejecuta <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estos proveedores se configuran a través de la configuración guiada (o el
panel), que pide exactamente los campos que cada uno necesita e imprime la URL de
retorno para registrar:

```bash
pepe setup
```

Elige la opción de canal, escoge el proveedor y el agente, e ingresa las
credenciales (se acepta una referencia `${ENV_VAR}` para cualquier secreto).
Cada uno tiene su propia página con sus campos y pasos de configuración
específicos: [Slack](../slack/), [Discord](../discord/),
[Microsoft Teams](../msteams/), [Google Chat](../googlechat/). Esta página
cubre lo que comparten todos ellos (y WhatsApp).

## @Menciones en grupos

Slack, Microsoft Teams y Google Chat admiten conversaciones en grupo/canal,
donde por defecto la conexión solo responde cuando la @mencionan (un mensaje
directo siempre llega al agente, sin importar el ajuste). Pon
`require_mention: false` en la conexión para que responda a todos los
mensajes en todos los canales en los que está, o, sin tocar ese ajuste de
toda la conexión, dispénsalo para un solo canal desde dentro de ese canal:

```text
/mention off   # solo este canal, hasta /new - no hace falta @mencionarlo para que responda
/mention on    # vuelve a exigir una @mención
/mention       # muestra el ajuste actual
```

Como un comando de canal igual tiene que estar dirigido al bot para
ejecutarse, el *primer* `/mention off` necesita una @mención real
(`@bot /mention off`); después de eso, el canal ya no necesita una hasta
`/new`. La dispensa vive en la conversación de ese canal, no en la conexión,
así que nunca se filtra a ningún otro canal. WhatsApp y Discord no filtran
por menciones hoy (siempre responden), así que `/mention` no hace nada ahí.

## Cambiar de modelo

`/model` y `/models` solo se activan en una conexión en modo `admin` con
`commands` habilitado (ver la comparación de modos en [Channels](../channels/))
- en `support`, son texto plano. `/models` lista los modelos disponibles para
el proyecto de la conexión; `/model` muestra el actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cambiarlo **globalmente** está reservado para **entrenadores** (la misma
lista que rige la memoria); cualquier otra persona en una conversación
permitida solo puede cambiar su propia sesión. Pon `model_switch_locked: true`
en la conexión para desactivarlo por completo para quien no sea entrenador.
Es el mismo mecanismo que usa WhatsApp; la versión de Telegram añade un
selector con botones en vez de comandos escritos.

## Por dentro: el contrato del proveedor

Cada canal por webhook es un pequeño módulo que implementa el mismo contrato,
así que todos se comportan de forma coherente y una nueva plataforma es un nuevo
módulo en lugar de una nueva ruta. Las funciones de retorno son:

- `name` y `label`: el segmento de URL del proveedor y su nombre para personas.
- `config_schema`: los campos que el panel muestra para configurar una conexión.
- `verify`: responder al handshake de verificación del `GET`.
- `authenticate`: verificar la firma en un `POST` entrante contra el secreto de
  la conexión y el cuerpo crudo de la petición. Una petición que falla se
  descarta.
- `parse`: normalizar la carga de la plataforma en cero o más mensajes planos.
  Las actualizaciones de estado y los acuses de entrega se ignoran.
- `respond` (opcional): producir una respuesta síncrona cuando el protocolo
  exige una antes de cualquier trabajo del agente, como el desafío
  `url_verification` de Slack o el ping y el acuse diferido de Discord.
- `deliver`: enviar una respuesta de texto de vuelta al remitente.
- `deliver_file` (opcional): enviar un archivo como adjunto.

Si escribes un complemento que implementa este contrato, se registra como un
nuevo proveedor bajo su propio `name`, accesible en la misma ruta
`/webhooks/...` sin cableado extra.
