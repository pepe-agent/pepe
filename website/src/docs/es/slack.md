---
title: Slack
description: Suma un agente de Pepe a tu espacio de Slack para que la gente pueda hablarle desde canales y mensajes directos.
---

## Slack

Al conectar Slack, cualquiera dentro de tu espacio de trabajo puede hablar directamente
con el agente. Slack le entrega los mensajes a Pepe a través de su Events API; configura
la conexión desde el asistente guiado (o desde el panel), que pide exactamente los
campos necesarios e imprime la URL de callback que hay que registrar:

```bash
pepe setup
```

Elige la opción de canal, selecciona Slack y el agente correspondiente, e ingresa las
credenciales (cualquier secreto acepta una referencia `${ENV_VAR}`). El `config` de una
conexión guarda:

- `bot_token`: el token OAuth del usuario bot (`xoxb-...`), que se usa como bearer al
  responder.
- `signing_secret`: sirve para verificar el `X-Slack-Signature` de las solicitudes
  entrantes.

Dentro de la app de Slack, configura la URL de solicitud de Event Subscriptions con la
URL de esta conexión, y suscríbete a `message.channels` y `app_mention`. Al guardar por
primera vez se dispara un handshake de `url_verification`, que Pepe responde al
instante. Las respuestas se publican mediante `chat.postMessage`. La URL de callback
tiene esta forma:

```
https://YOUR_HOST/webhooks/default/slack/<slug>
```

Revisa [Webhooks](../webhooks/) para conocer los campos que comparte toda conexión
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y cómo
funciona por dentro la ruta genérica.

### Cambiar de modelo

Con los comandos `/model` y `/models`, cualquiera puede consultar o cambiar qué modelo de
IA le está respondiendo. Ambos solo funcionan en una conexión con modo `admin` y
`commands` habilitado; en modo `support` se tratan como texto normal, sin más. `/models`
lista los modelos disponibles para el proyecto de esa conexión; `/model` muestra el
actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia el modelo solo para esta conversación
/model openrouter global        # cambia el modelo para todos los que hablan por esta conexión
```

Cualquier persona dentro de una conversación permitida puede cambiar el modelo de su
propia conversación. Cambiarlo de forma **global**, para todos los que hablan a través de
esa conexión, queda reservado a los **entrenadores**, la misma lista de confianza que
controla la memoria. Define `model_switch_locked: true` en la conexión si quieres
desactivar por completo el cambio de modelo para quien no sea entrenador.
