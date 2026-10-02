---
title: Slack
description: Suma un agente de Pepe a tu espacio de Slack para que la gente pueda hablarle desde canales y mensajes directos.
---

## Slack

Al conectar Slack, cualquiera dentro de tu espacio de trabajo puede hablar directamente
con el agente. Slack le entrega los mensajes a Pepe a través de su Events API.

### Paso a paso

1. **Crear la app.** En [api.slack.com/apps](https://api.slack.com/apps) → "Create New
   App" → elige **"Blank app"** (las otras opciones, como "AI agent", traen su propio
   armazón de agente de Slack, que acá no hace falta - el agente es Pepe). Elige tu
   espacio de trabajo.
2. **Dar permisos al bot.** En **OAuth & Permissions → Scopes → Bot Token Scopes**,
   agrega `chat:write`, `app_mentions:read`, `channels:history` e `im:history`. Agrega también `files:read` si la gente va a enviar imágenes o archivos (sin él el bot no puede abrirlos), `files:write` para que el bot pueda enviar archivos de vuelta, `reactions:write` para marcar con un 👀 el mensaje en el que está trabajando, y `reactions:read` para que un 👍 o ❤️ en uno de sus mensajes cuente como feedback. Para esto último suscríbete también al evento de bot `reaction_added`.
3. **Instalar la app.** Sigue en OAuth & Permissions, hace clic en "Install to
   Workspace" y copia el **Bot User OAuth Token** (`xoxb-...`).
4. **Conseguir el signing secret.** En **Basic Information → App Credentials**, copia
   el **Signing Secret**.
5. **Registrar la conexión en Pepe:**

   ```bash
   pepe setup
   ```

   Elige la opción de canal, selecciona Slack y el agente, e ingresa las credenciales
   (cualquier secreto acepta una referencia `${ENV_VAR}`). Pepe imprime la URL de
   callback que hay que registrar:

   ```
   https://YOUR_HOST/webhooks/root/slack/<slug>
   ```

   Cambia `YOUR_HOST` por el dominio donde tu servidor realmente responde (el dominio
   real en producción; `mix pepe serve --tunnel` si solo estás probando en local).
6. **Activar los eventos en Slack.** En la app → **Event Subscriptions** → Enable
   Events → pega la URL del paso anterior (Slack dispara un handshake de
   `url_verification` al instante, y Pepe lo responde solo, sin ningún paso manual). En
   "Subscribe to bot events", agrega `message.channels`, `app_mention` y `message.im`
   (este último es el que hace que un mensaje directo funcione).
7. **Apagar el Socket Mode.** Las apps nuevas de Slack suelen venir con esto activado
   por defecto: barra lateral → **Socket Mode**. Mientras esté activo, Slack envía los
   eventos por WebSocket en vez de golpear tu Request URL - y Pepe solo entiende el
   webhook HTTP clásico, así que nada llega, en silencio, aunque todo lo demás esté bien
   configurado. Déjalo apagado.
8. **Guardar.** En la página de Event Subscriptions, hace clic en "Save Changes" al pie
   antes de salir - pegar la URL y salir sin guardar descarta todo.
9. Si Slack lo pide, **reinstala la app** en el espacio de trabajo (los scopes y
   eventos nuevos lo exigen).
10. **Probarlo:** invita al bot a un canal (`/invite @tu-bot`) y menciónalo, o mándale
    un mensaje directo.

### Campos de la conexión

El `config` de una conexión guarda:

- `bot_token`: el token OAuth del usuario bot (`xoxb-...`), que se usa como bearer al
  responder.
- `signing_secret`: sirve para verificar el `X-Slack-Signature` de las solicitudes
  entrantes.

Las respuestas se publican mediante `chat.postMessage`.

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
