---
title: Discord
description: Contesta comandos de barra, o mensajes normales de canal, en tu servidor de Discord usando un agente de Pepe.
---

## Discord

Discord le da a Pepe dos formas distintas de recibir un mensaje, y una
conexión puede usar una, la otra, o ambas:

- Un **comando de barra** (por ejemplo `/ask`), que llega por el endpoint de
  Interactions de Discord. Esto calza con la pasarela de webhooks de Pepe
  igual que cualquier otro proveedor: ningún proceso que mantener corriendo,
  es Discord quien llama a tu servidor.
- Un **mensaje normal** escrito en un canal, en un DM, o en una respuesta,
  que llega por la pasarela de Discord: un WebSocket que el bot mantiene
  abierto. Esto necesita su propio opt-in y un token de bot (más abajo),
  porque es una conexión persistente y no una llamada de webhook.

Empieza desde el asistente guiado o desde el panel:

```bash
pepe setup
```

El `config` de cada conexión guarda dos cosas:

- `public_key`: la clave pública de la app, en hex, que Discord exige para
  verificar la firma Ed25519.
- `application_id`: con esto se publica la respuesta de seguimiento.

Dentro de la app de Discord, apunta "Interactions Endpoint URL" a la URL de
tu conexión y crea un comando de barra con una opción de texto, por ejemplo
`/ask prompt:...`. Como Discord exige una confirmación dentro de tres
segundos, Pepe responde de inmediato con un acuse diferido y, cuando el
agente termina, publica la respuesta real como mensaje de seguimiento. La
URL de retorno tiene esta forma:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Los campos que comparten todas las conexiones (`agent`, `mode`, `trainers`,
`session_ttl_min`, `ephemeral`, `commands`) y el funcionamiento interno de la
ruta genérica están en [Webhooks](../webhooks/).

### Archivos en un comando

Dale a tu comando de barra una **opción de adjunto** y la gente puede mandarle un archivo: `/ask prompt:¿qué dice? file:<clip>`. Un clip de voz se transcribe antes de que el agente corra, un documento llega con su texto ya leído, y una imagen llega como imagen a un modelo con visión. El adjunto alcanza por sí solo, así que `/ask file:<clip>` sin nada escrito también funciona.

Es el único camino que tiene un archivo por el endpoint de Interactions: ve comandos de barra y nada más, así que una nota de voz o un adjunto publicado directo en el canal no le llega a Pepe por ahí. Sí le llega por el otro camino, por la pasarela: ver **Mensajes normales de canal** más abajo. Pepe acepta archivos de hasta 20 MB por defecto (`max_attachment_mb` en la conexión sube o baja ese límite), y gana el menor entre el límite de Pepe y el límite de subida de Discord: 10 MB en una cuenta normal o servidor sin boost, más con Nitro o un servidor con boost. Ver [Mensajes de voz](../voice/) y [Documentos](../documents/).

### Mensajes normales de canal

Una conexión también puede contestar un mensaje escrito directo en un canal, una foto
soltada ahí, una nota de voz grabada en el momento, o un DM al bot, no solo un comando de
barra. Esto necesita su propio opt-in, porque significa que Pepe mantiene una conexión
persistente con la pasarela de Discord, en vez de solo contestar llamadas de webhook:

```bash
pepe gateway discord add support --agent soporte --gateway --bot-token '${DISCORD_BOT_TOKEN}'
```

o los campos equivalentes en el panel (una conexión puede tener `--application-id`/`--public-key`
para comandos de barra y `--gateway`/`--bot-token` para mensajes de canal a la vez).
`mix pepe serve` corre la conexión de las dos formas. Flags:

- `--gateway`: activa este modo.
- `--bot-token '${ENV}'`: el token del bot, sacado del Discord Developer Portal, guardado
  como `${ENV_VAR}`. Activa también el intent **Message Content** en la página del Bot de
  la app, o Discord no entrega el texto de un mensaje que no mencione al bot.
- `--no-require-mention`: en un servidor, por defecto el bot solo contesta un mensaje que
  lo @mencione o responda a algo que dijo. Pasa esta flag para que conteste cualquier
  mensaje en un canal que pueda ver. En un DM, el bot siempre contesta, sin importar esta
  flag.
- `--max-attachment-mb N`: sube o baja el límite por defecto de 20 MB para esa conexión.

Los adjuntos del mensaje mismo, del mensaje al que responde (así se puede contestar "¿qué
dice esto?" después de que ya llegó la nota de voz), y de un mensaje reenviado al bot
cuentan todos, y pasan por el mismo trato de voz-a-transcripción, documento-a-texto,
imagen-a-visión que un adjunto de comando de barra. Los mensajes de una conexión se
contestan en el orden en que Discord los entregó. Si la conexión se cae, se reconecta y
retoma sola, sin perder nada de lo que se dijo en el intervalo.

### Cambiar de modelo

Con los comandos `/model` y `/models` cualquiera puede consultar o cambiar
el modelo de IA que le responde. En Discord estos llegan a Pepe a través del
comando que ya registraste (el `/ask` de arriba): todo lo que se escriba en
su opción `prompt:` es lo que Pepe termina leyendo. Solo funcionan si la
conexión está en modo `admin` con `commands` habilitado; en modo `support`
se procesan como texto normal, sin efecto especial. `/models` lista los
modelos disponibles para el proyecto de esa conexión, y `/model` muestra
cuál está activo o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquier persona autorizada a conversar puede cambiar el modelo de su
propia charla, pero hacerlo **de forma global**, para todos con quienes
habla esa conexión, queda reservado a los **entrenadores**: la misma lista
de confianza que controla la memoria. Si quieres bloquear por completo el
cambio de modelo para quien no sea entrenador, activa
`model_switch_locked: true` en la conexión.
