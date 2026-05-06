---
title: Slack
description: Conecta una app de Slack a un agente de Pepe mediante la Events API.
---

## Slack

Slack usa la Events API. Configúralo mediante la configuración guiada (o el
panel), que pide exactamente los campos que necesita e imprime la URL de
retorno para registrar:

```bash
pepe setup
```

Elige la opción de canal, escoge Slack y el agente, e ingresa las credenciales
(se acepta una referencia `${ENV_VAR}` para cualquier secreto). El `config` de
una conexión contiene:

- `bot_token`: el token OAuth del usuario bot (`xoxb-...`), usado como bearer
  para las respuestas.
- `signing_secret`: verifica el `X-Slack-Signature` en las peticiones entrantes.

En la app de Slack, define la URL de petición de Event Subscriptions con la URL
de la conexión y suscríbete a `message.channels` y `app_mention`. El primer
guardado dispara un handshake `url_verification`, que Pepe responde de inmediato.
Las respuestas se publican con `chat.postMessage`. Forma de la URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

Ver [Webhooks](../webhooks/) para los campos que comparte toda conexión
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y
cómo funciona la ruta genérica por dentro.

### Cambiar de modelo

`/model` y `/models` solo se activan en una conexión en modo `admin` con
`commands` habilitado; en `support`, son texto plano. `/models` lista los
modelos disponibles para la empresa de esta conexión; `/model` muestra el
actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquiera en una conversación permitida puede cambiar su propia sesión;
cambiarlo **globalmente** está reservado para **entrenadores**, la misma
lista que rige la memoria. Pon `model_switch_locked: true` en la conexión para
desactivar el cambio de modelo por completo para quien no sea entrenador.
