---
title: Canales
description: Vincula un agente a Telegram, WhatsApp, Slack, Discord, Microsoft Teams, Google Chat o un webhook entrante genérico, y la gente simplemente conversa con él.
---

Un canal conecta uno de tus agentes con un lugar donde la gente ya conversa.
Alguien envía un mensaje, Pepe ejecuta el agente vinculado (llamando a
herramientas y leyendo la respuesta), y la respuesta se entrega por ese mismo
canal. No escribes nada de código de conexión. Agregas una conexión, la apuntas
a un agente y funciona.

Todo en esta página da por sentado que ya tienes al menos un agente definido. Si
no lo tienes, consulta primero la guía de agentes.

## Tres maneras de configurarlo

Como el resto de Pepe, los canales se gestionan de tres maneras, y esta página
muestra cada una donde corresponde:

1. La línea de comandos `pepe`.
2. El panel web (su sección "Channels" lista tus bots y conexiones, y te guía
   para agregar uno).
3. Por chat. Un agente que dispone de la herramienta de gestión adecuada puede
   crear y revincular bots de Telegram, entregar archivos y cerrar una
   conversación, todo en lenguaje corriente. Esas acciones están protegidas, así
   que lee las notas "Hazlo por chat" más abajo para conocer el paso exacto de
   confirmación.

## Dos formas de canal

Los canales solo se diferencian en cómo llega un mensaje hasta Pepe:

- **Telegram** es un bot que Pepe consulta. Nada tiene que ser accesible
  públicamente. Agrega un token, vincúlalo a un agente y ejecuta la pasarela.
- **Canales por webhook** (WhatsApp, Slack, Discord, Microsoft Teams, Google
  Chat y una ruta entrante genérica) reciben mensajes que la plataforma envía a
  una URL de retorno. Pepe expone una URL por conexión. La registras una sola
  vez con el proveedor.

## Telegram

Telegram es el canal más rápido de poner en marcha porque no necesita ninguna
URL pública. Crea un bot con @BotFather, copia su token y regístralo.

Configura el bot predeterminado de forma interactiva:

```bash
pepe gateway telegram setup
```

Esto pide el token (puedes pegar un token literal o una referencia
`${ENV_VAR}`), un agente opcional para vincular y una lista opcional de ids de
chat autorizados a hablar con él.

Puedes ejecutar más de un bot, cada uno vinculado a un agente distinto:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Las opciones de `telegram add`:

- `--token` (obligatorio): el token del bot, literal o `${ENV_VAR}`.
- `--agent`: qué agente responde. Omítelo para usar tu agente predeterminado.
- `--trainers`: de quién puede aprender este bot hacia su memoria. Omítelo para
  todos, `none` para nadie, o una lista separada por comas de ids de usuario
  para solo esos.
- `--heartbeat-minutes` y `--heartbeat-hours`: una ventana periódica opcional de
  activación (para agentes que revisan cosas según un horario). Las horas son
  una ventana local como `8-22`.
- `--progress`: cómo señala el bot que está trabajando mientras una ejecución
  está en curso. Uno de `reaction` (una reacción en tu mensaje), `ambient` (una
  línea de actividad), `off` (solo el indicador de escritura) o `verbose` (un
  desglose por herramienta).

Listar y eliminar bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Ejecuta el consultador en primer plano (un consultador por bot):

```bash
pepe gateway telegram
```

Normalmente no necesitas ejecutar eso por separado. `pepe serve` arranca los
bots de Telegram configurados junto con la API HTTP, así que un único servidor
en ejecución cubre todos los canales a la vez.

<div class="note"><strong>Panel.</strong> La sección Channels del panel lista
tus bots con una insignia en vivo de activo/inactivo, te permite agregar un bot,
editar con qué agente habla y eliminarlo. Escribe la misma configuración que la
línea de comandos.</div>

### Hazlo por chat

Un agente que tenga la herramienta `manage_channel` puede crear y revincular
bots de Telegram desde una conversación. Como edita la configuración, cada
llamada pasa por la verja de permisos: el agente propone el cambio y tú
confirmas antes de que se aplique.

Dirías:

> Agrega un bot de Telegram llamado sales que hable con el agente de ventas. El
> token está en la variable de entorno SALES_BOT_TOKEN.

El agente llama a `manage_channel` con `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` y `agent: "sales"`. Aquí importan dos
salvaguardas:

- **Los secretos nunca pasan por el chat.** Das el *nombre* de una variable de
  entorno que contiene el token, nunca el token en sí. Se almacena como
  `${SALES_BOT_TOKEN}` y se resuelve al momento de leerlo, así que el secreto en
  crudo nunca llega al modelo ni a los registros. Un token en crudo (que
  contiene dos puntos) es rechazado.
- **El bot predeterminado protegido está vedado.** La herramienta solo toca bots
  con nombre, nunca el `default`.

Otras acciones de `manage_channel` son `list`, `set_agent` (revincular un bot a
otro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` y `remove`. Tras cualquier cambio reconcilia los consultadores en
ejecución, así que un bot arranca o se detiene en vivo sin reiniciar.

<div class="note"><strong>Solo Telegram.</strong> La herramienta de chat
gestiona bots de Telegram. Las conexiones por webhook (WhatsApp, Slack y las
demás) se crean desde la línea de comandos, el panel o <code>pepe setup</code>,
no por chat.</div>

## Cómo funciona un canal por webhook

Todo canal por webhook, sea cual sea la plataforma, es accesible en una sola
ruta:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` es el ámbito de inquilino. Usa `root` para el ámbito
  predeterminado (que aparece como "Principal" en el panel), o el identificador
  de una empresa para aislar una conexión a ese inquilino.
- `<provider>` es el nombre de la plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` o `googlechat`.
- `<slug>` es el nombre único que le diste a la conexión.

Un `GET` a esa URL responde al saludo de verificación del proveedor (Pepe
devuelve el desafío que la plataforma envía cuando registras la URL por primera
vez). Un `POST` es un evento entrante. En un `POST`, Pepe resuelve la conexión,
verifica la firma de la petición contra el secreto que configuraste, extrae el
mensaje, ejecuta el agente vinculado y entrega la respuesta a través de la
propia API del proveedor. El trabajo del agente corre en segundo plano para que
la plataforma reciba su acuse de inmediato (proveedores como Meta reintentan un
webhook lento).

Hay una única ruta genérica. Agregar un nuevo proveedor nunca agrega un nuevo
punto de acceso.

<div class="note"><strong>Host público.</strong> Los canales por webhook
necesitan una URL que la plataforma pueda alcanzar. Expón tu instancia de Pepe
detrás de un proxy inverso o un túnel, y define <code>PEPE_PUBLIC_URL</code> para
que las URL de retorno que imprime la línea de comandos estén completas. Para un
túnel rápido durante las pruebas, ejecuta <code>pepe serve --tunnel</code>.</div>

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
| Comandos de barra | Tratados como texto plano | Habilitados (por ejemplo `/new` reinicia) |

Soporte es el valor predeterminado seguro para cualquier cosa a la que el
público pueda llegar. Combínalo con un agente restringido (solo herramientas
seguras, ya que no hay una persona de tu lado para aprobar una acción riesgosa)
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

## WhatsApp

WhatsApp usa la Cloud API de Meta. Tiene una línea de comandos dedicada porque es
el canal por webhook más común. Agrega una conexión:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

Las credenciales de la conexión (guardadas bajo su `config`):

- `phone_number_id`: el id del punto de envío desde la app de Meta.
- `access_token`: el token bearer de la Graph API. Guárdalo como `${ENV_VAR}`.
- `app_secret`: verifica el `X-Hub-Signature-256` entrante. Guárdalo como
  `${ENV_VAR}`.
- `verify_token`: cualquier cadena que elijas. Meta la devuelve durante el saludo
  de suscripción. Si omites la opción, se usa el slug.

Si dejas fuera `--access-token` o `--app-secret`, la línea de comandos escribe
una referencia de marcador derivada del slug (por ejemplo `${WA_TOKEN_SUPPORT}`),
para que rellenes el valor real en tu entorno más tarde. El comando imprime la
URL de retorno y el token de verificación. Pega ambos en la configuración de
webhook de la app de Meta:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gestiona conexiones:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

Las demás opciones de `whatsapp add` son `--company`, `--trainers`, `--ttl-min`,
`--ephemeral` y `--commands`, que corresponden a los campos por conexión
descritos arriba. El panel agrega y edita conexiones de WhatsApp a través de la
misma sección Channels.

<div class="note"><strong>Regla de las 24 horas.</strong> Meta solo permite
respuestas de formato libre dentro de las 24 horas del último mensaje del
usuario. El soporte reactivo encaja con esto de forma natural. Los mensajes
proactivos fuera de la ventana necesitan plantillas preaprobadas, que este canal
no envía.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estos proveedores se configuran a través de la configuración guiada (o el
panel), que pide exactamente los campos que cada uno necesita e imprime la URL de
retorno para registrar:

```bash
pepe setup
```

Elige la opción de canal, escoge el proveedor y el agente, e ingresa las
credenciales (se acepta una referencia `${ENV_VAR}` para cualquier secreto). Los
campos obligatorios de cada proveedor están abajo.

### Slack

Slack usa la Events API. El `config` de una conexión contiene:

- `bot_token`: el token OAuth del usuario bot (`xoxb-...`), usado como bearer
  para las respuestas.
- `signing_secret`: verifica el `X-Slack-Signature` en las peticiones entrantes.

En la app de Slack, define la URL de petición de Event Subscriptions con la URL
de la conexión y suscríbete a `message.channels` y `app_mention`. El primer
guardado dispara un saludo `url_verification`, que Pepe responde de inmediato.
Las respuestas se publican con `chat.postMessage`. Forma de la URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

Discord se conecta a través del punto de acceso de Interactions (comandos de
barra), así que encaja en la pasarela de webhook y no en una conexión
persistente. El `config` de una conexión contiene:

- `public_key`: la clave pública de la app (hex), para la verificación de firma
  Ed25519 requerida.
- `application_id`: se usa para publicar la respuesta de seguimiento.

En la app de Discord, apunta "Interactions Endpoint URL" a la URL de la conexión
y agrega un comando de barra con una opción de texto (por ejemplo
`/ask prompt:...`). Discord exige un acuse en tres segundos, así que Pepe
responde con una respuesta diferida y publica la respuesta real como seguimiento
una vez que el agente termina.

### Microsoft Teams

Teams usa el Bot Framework. El `config` de una conexión contiene:

- `app_id`: el id de la app (cliente) de Microsoft del bot.
- `app_password`: el secreto de cliente. Guárdalo como `${ENV_VAR}`.
- `tenant_id`: el id de inquilino de Azure (o `botframework.com`).

Las actividades entrantes llegan como `POST`s. Las respuestas vuelven a la URL de
servicio de la actividad con un token de acceso de app acuñado a partir de las
credenciales de cliente. La mención al bot se quita del texto entrante antes de
que el agente lo vea.

### Google Chat

Google Chat publica eventos de espacio en la URL de retorno. El `config` de una
conexión contiene:

- `access_token`: un token OAuth para la Chat API, usado como bearer para las
  respuestas. Guárdalo como `${ENV_VAR}` y renuévalo por fuera.

Solo se atienden los eventos `MESSAGE` de una persona. Las respuestas se
publican de vuelta al espacio a través de la Chat REST API.

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
  "caption": "Here is this week's report."
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
verja de permisos: confirmas el cambio antes de que surta efecto. Dirías:

> Deja que el agente de triaje derive al agente de facturación.

El agente llama a `set_route` con `to: "billing"` (y `from` toma por defecto
aquel con el que estás hablando), o `action: "deny"` para quitar una ruta. En la
línea de comandos lo mismo es `pepe agent route triage billing`.

## Por dentro: el contrato del proveedor

Cada canal por webhook es un pequeño módulo que implementa el mismo contrato,
así que todos se comportan de forma coherente y una nueva plataforma es un nuevo
módulo en lugar de una nueva ruta. Las funciones de retorno son:

- `name` y `label`: el segmento de URL del proveedor y su nombre para personas.
- `config_schema`: los campos que el panel muestra para configurar una conexión.
- `verify`: responder al saludo de verificación del `GET`.
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

## Servirlo todo

Un solo comando sirve la API HTTP compatible con OpenAI, el WebSocket, el panel,
la ruta de webhook y cada bot de Telegram configurado:

```bash
pepe serve --port 4000
```

El puerto también se lee de la variable de entorno `PORT`. Agrega `--tunnel`
para abrir un túnel público y probar canales por webhook sin tu propio proxy
inverso. Define `PEPE_PUBLIC_URL` para que las URL de retorno que registras con
cada proveedor apunten a tu host real.
