---
title: Canales
description: Entiende tipos de canal, vinculación, sesiones, envío de archivos y enrutamiento.
---

Un canal conecta uno de tus agentes con un lugar donde la gente ya conversa.
Alguien envía un mensaje, Pepe ejecuta el agente vinculado (llamando a
herramientas y leyendo la respuesta), y la respuesta se entrega por ese mismo
canal. No escribes nada de código de conexión. Añades una conexión, la apuntas
a un agente y funciona.

Todo en esta página da por sentado que ya tienes al menos un agente definido. Si
no lo tienes, consulta primero la guía de agentes.

## Tres maneras de configurarlo

Como el resto de Pepe, los canales se gestionan de tres maneras, y esta página
muestra cada una donde corresponde:

1. La línea de comandos `pepe`.
2. El panel web (su sección "Channels" lista tus bots y conexiones, y te guía
   para añadir uno).
3. Por chat. Un agente que dispone de la herramienta de gestión adecuada puede
   crear y revincular bots de Telegram, entregar archivos y cerrar una
   conversación, todo en lenguaje corriente. Esas acciones están protegidas, así
   que lee las notas "Hazlo por chat" más abajo para conocer el paso exacto de
   confirmación.

Si vienes de otro motor de agentes, `pepe migrate` importa los canales que ya
existen allí, en lugar de que añadas cada uno a mano.

## Dos formas de canal

Los canales solo se diferencian en cómo llega un mensaje hasta Pepe:

- **Telegram** es un bot que Pepe consulta. Nada tiene que ser accesible
  públicamente. Añade un token, vincúlalo a un agente y ejecuta la pasarela.
- **Canales por webhook** (WhatsApp, Slack, Discord, Microsoft Teams, Google
  Chat y una ruta entrante genérica) reciben mensajes que la plataforma envía a
  una URL de retorno. Pepe expone una URL por conexión. La registras una sola
  vez con el proveedor.

Todo canal por webhook, sea cual sea la plataforma, se sirve desde el mismo
endpoint de entrada:

```
/webhooks/:company/:provider/:slug
```

`:company` es el ámbito del inquilino, y es `root` cuando no usas empresas.
`:provider` es el nombre de la plataforma, y `:slug` es el nombre que le diste a
la conexión. Añadir un proveedor nunca añade un endpoint nuevo.

Estos son los canales por webhook que vienen con Pepe, y lo que necesita cada
uno:

| Canal | Cómo se conecta | Configuración que necesita |
|---|---|---|
| **WhatsApp** | Webhook de la Meta Cloud API | `phone_number_id`, `access_token`, `app_secret`, `verify_token` |
| **Slack** | Webhook de la Events API | `bot_token` (`xoxb-`), `signing_secret` |
| **Discord** | Endpoint de Interactions (comandos de barra) | `public_key`, `application_id` |
| **Microsoft Teams** | Webhook del Bot Framework | `app_id`, `app_password`, `tenant_id` |
| **Google Chat** | Webhook de la Chat API | `access_token` (OAuth para la Chat API) |

Chatwoot también está disponible, como un [plugin](../plugins/) de canal en vez
de una conexión nativa. Hace de frente para WhatsApp, el widget web y más, y trae
traspaso nativo a un humano. Los plugins de canal se configuran en la pestaña
**Integrations** del panel, no en **Channels**.

## Notas de configuración por canal

- **Slack.** Crea una app, añade un scope de bot token, activa las Event
  Subscriptions y apunta la request URL a la URL de la conexión. Pepe responde
  por su cuenta al desafío `url_verification`. Añade los eventos
  `message.channels` y `app_mention`. El signing secret verifica cada petición.
  Ver [Slack](../slack/).
- **Discord.** Esto usa el endpoint de Interactions, no un bot de gateway, así
  que responde a **comandos de barra**. Añade un comando con una opción de texto
  y luego apunta la "Interactions Endpoint URL" de la app a la URL de la
  conexión. La public key de la app verifica la firma Ed25519. El comando se
  confirma de inmediato y la respuesta llega como follow-up. Ver
  [Discord](../discord/).
- **Microsoft Teams.** Registra un bot en Azure y apunta su messaging endpoint a
  la URL de la conexión. Pepe responde al `serviceUrl` de la activity con un
  token emitido a partir de las credenciales de la app. Mantén el endpoint detrás
  de un proxy o de un secreto: el JWT entrante no se valida aquí. Ver
  [Microsoft Teams](../msteams/).
- **Google Chat.** Configura el endpoint de webhook (HTTP) de la app hacia la URL
  de la conexión y proporciona un `access_token` OAuth para la Chat API. Las
  respuestas se publican de vuelta en el espacio. Mantén el endpoint detrás de un
  proxy. Ver [Google Chat](../googlechat/).

## Vinculación, sesiones y los dos modos

Cada conexión (y cada bot de Telegram) nombra un `agent`. Esa es la vinculación.
Cada remitente distinto recibe su propia conversación, así que el contexto se
conserva por persona sin que gestiones nada.

Una conexión por webhook también tiene un `mode` que cambia cómo se comporta el
motor:

| | Soporte | Admin |
|--|---------|-------|
| Público | De cara al cliente, abierto a cualquiera | Tú, restringido a remitentes autorizados |
| Historial | Efímero, cada chat aislado | Se conserva entre mensajes |
| Memoria | Nunca aprende | Las conversaciones pueden volverse memoria |
| Comandos de barra | Tratados como texto plano | Habilitados (por ejemplo `/new` reinicia, `/model` cambia de modelo) |

Soporte es el valor predeterminado seguro para cualquier cosa a la que el
público pueda llegar. Combínalo con un agente restringido (solo herramientas
seguras, ya que no hay una persona de tu lado para aprobar una acción arriesgada)
y, si quieres, un tiempo de espera por sesión inactiva. Admin es para un canal
que solo usas tú, donde los comandos de barra y la memoria son útiles.

Unos cuantos campos ajustan esto por conexión:

- `agent`: el agente al que está vinculada esta conexión.
- `mode`: `support` o `admin`.
- `trainers`: quién puede convertir una conversación en memoria. `["*"]` es
  todos, `[]` es nadie, una lista son solo esos remitentes, ausente es el
  predeterminado (todos).
- `session_ttl_min`: minutos de inactividad antes de que se descarte la
  conversación.
- `ephemeral`: cuando es verdadero, el historial no se arrastra entre mensajes.
- `commands`: si se atienden los comandos de barra (activados por defecto en
  admin).

## Cómo se ve una conexión en la configuración

No hay base de datos. Las conexiones viven en `~/.pepe/config.json` bajo
`webhooks`, indexadas por slug. Los secretos se escriben como `${ENV_VAR}` y se
leen en tiempo de ejecución, nunca expandidos en disco. Una conexión de soporte
de Slack se ve así:

```json
{
  "webhooks": {
    "support": {
      "provider": "slack",
      "agent": "helpdesk",
      "mode": "support",
      "config": {
        "bot_token": "${SLACK_BOT_TOKEN}",
        "signing_secret": "${SLACK_SIGNING_SECRET}"
      }
    }
  }
}
```

Puedes editar este archivo a mano, pero la línea de comandos y el panel lo
mantienen válido por ti.

## Enviar archivos

Un agente puede entregar un archivo a quien está conversando. Produce el archivo
como prefiera (por ejemplo un paso `bash` que consulta una base de datos y
escribe un `.xlsx`), luego llama a la herramienta `send_file` con la ruta:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Aquí está el informe de esta semana."
}
```

Pepe averigua en qué canal está la conversación y entrega el archivo allí. El
agente nunca necesita ids de chat ni tokens. Telegram lo envía como documento.
WhatsApp, Slack y Discord lo suben como medio en sus APIs. Si el canal actual no
puede recibir adjuntos (Microsoft Teams y Google Chat envían solo texto), la
herramienta lo informa de vuelta al agente en lugar de fallar en silencio.

### Hazlo por chat

La entrega de archivos es en sí misma una capacidad por chat. Cualquier agente
con la herramienta `send_file` lo hace en cuanto se lo pides. Dirías:

> Trae los registros de la semana pasada y envíame la planilla.

El agente ejecuta el paso que construye el archivo, luego llama a `send_file` con
la ruta resultante. No hay una verja de confirmación aparte en `send_file`; solo
entrega al propio canal de la conversación actual, resuelto desde la sesión, así
que no puede filtrar un archivo a nadie más.

## Terminar una conversación

Un agente de soporte puede cerrar su propia conversación una vez que termina un
intercambio, para que el siguiente mensaje de esa persona empiece desde cero. Un
agente con la herramienta `end_session` lo hace por chat:

> Gracias, eso es todo.

El agente envía primero su respuesta final, luego llama a `end_session`, que
limpia el contexto del hilo en vivo. Su conocimiento aprendido queda intacto.
Solo se reinicia la conversación actual. Esto es útil en un canal en modo
`support` donde cada intercambio debería ser independiente.

## Enrutar entre agentes

Más allá de vincular un canal a un agente, un agente que dispone de la
herramienta `set_route` puede cambiar qué agentes pueden escribir a cuáles, desde
el chat. El enrutamiento es dirigido, así que permitir que el agente A escriba al
agente B no permite que B escriba a A. Como edita la configuración, pasa por la
barrera de permisos: confirmas el cambio antes de que surta efecto. Dirías:

> Deja que el agente de triaje derive al agente de facturación.

El agente llama a `set_route` con `to: "billing"` (y `from` toma por defecto
aquel con el que estás hablando), o `action: "deny"` para quitar una ruta. En la
línea de comandos lo mismo es `pepe agent route triage billing`.

## Lo que no viene incluido

Signal, IRC e iMessage necesitan una conexión persistente o un puente propio de
la plataforma, que no encaja en el modelo de webhook, así que por ahora quedan
fuera de alcance. Un canal nuevo siempre se puede añadir como un
[plugin](../plugins/) de canal.

## Servirlo todo

Un solo comando sirve la API HTTP compatible con OpenAI, el WebSocket, el panel,
la ruta de webhook y cada bot de Telegram configurado:

```bash
pepe serve --port 4000
```

El puerto también se lee de la variable de entorno `PORT`. Añade `--tunnel`
para abrir un túnel público y probar canales por webhook sin tu propio proxy
inverso. Define `PEPE_PUBLIC_URL` para que las URL de retorno que registras con
cada proveedor apunten a tu host real.
