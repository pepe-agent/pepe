---
title: Canales
description: Lleva tus agentes a Telegram, WhatsApp, Slack y otras plataformas. Cómo funcionan los canales, quién puede escribirles y cómo llegan los archivos y los traspasos.
---

Un canal pone a uno de tus agentes en un lugar donde la gente ya está
conversando. En cuanto alguien manda un mensaje, Pepe corre el agente
vinculado (que llama a sus herramientas y arma la respuesta), y esa respuesta
vuelve por el mismo canal. No hace falta escribir ni una línea de código
pegamento: agregas una conexión, la apuntas a un agente, y ya funciona.

Todo lo de esta página da por hecho que ya tienes definido al menos un
agente. Si todavía no, primero conviene pasar por la guía de agentes.

## Tres formas de configurarlo

Igual que el resto de Pepe, los canales se manejan de tres formas, y esta
página muestra cada una en el lugar que le corresponde:

1. La línea de comandos `pepe`.
2. El panel (la sección "Channels" lista tus bots y conexiones, y te va
   guiando para sumar uno nuevo).
3. Por chat. Un agente que tenga la herramienta de gestión adecuada puede
   crear y revincular bots de Telegram, entregar archivos y cerrar una
   conversación, todo con lenguaje corriente. Como esas acciones están
   protegidas, más abajo cada nota "Hazlo por chat" explica el paso de
   confirmación exacto que corresponde.

¿Vienes de otro runtime de agentes? `pepe migrate` importa los canales que ya
tenías ahí, así no das de alta cada uno a mano.

## Dos tipos de canal

La única diferencia real entre los canales está en cómo le llega un mensaje a
Pepe:

- **Telegram** funciona como un bot del que el propio Pepe va a buscar los
  mensajes, así que de tu lado no necesitas nada accesible desde internet.
  Agregas un token, lo vinculas a un agente, y corres la pasarela.
- Los **canales por webhook** (WhatsApp, Slack, Discord, Microsoft Teams,
  Google Chat, y una ruta entrante genérica) reciben lo que la plataforma les
  manda a una dirección de tu propio servidor, así que en este caso Pepe sí
  tiene que estar accesible desde internet. Por cada conexión, Pepe expone
  una URL, que registras con el proveedor una única vez.

Todo canal por webhook, sea cual sea la plataforma, se sirve desde el mismo
endpoint de entrada:

```
/webhooks/:project/:provider/:slug
```

`:project` es el proyecto dueño de la conexión, y vale `default` mientras no
estés usando proyectos adicionales. `:provider` es el nombre de la
plataforma, y `:slug`, el nombre que le pusiste tú a la conexión. Sumar un
proveedor nuevo nunca agrega un endpoint distinto.

Estos son los canales por webhook que trae Pepe de fábrica, junto con lo que
pide cada uno:

| Canal | Cómo se conecta | Configuración que necesita |
|---|---|---|
| **WhatsApp** | Webhook de la Meta Cloud API | `phone_number_id`, `access_token`, `app_secret`, `verify_token` |
| **Slack** | Webhook de la Events API | `bot_token` (`xoxb-`), `signing_secret` |
| **Discord** | Endpoint de Interactions (comandos de barra) | `public_key`, `application_id` |
| **Microsoft Teams** | Webhook del Bot Framework | `app_id`, `app_password`, `tenant_id` |
| **Google Chat** | Webhook de la Chat API | `access_token` (OAuth de la Chat API) |

Chatwoot también está disponible, pero como [plugin](../plugins/) de canal en
lugar de venir integrado de fábrica. Da la cara por WhatsApp, el widget web y
otros canales más, y trae de serie el traspaso a un humano. Estos plugins de
canal se configuran desde la pestaña **Integrations** del panel, no desde
**Channels**.

## Notas de configuración por canal

- **Slack.** Crea una app, dale un scope de bot token, activa las Event
  Subscriptions, y apunta la request URL a la URL de tu conexión. El desafío
  `url_verification` lo responde Pepe solo. Suma los eventos
  `message.channels` y `app_mention`. Cada petición queda verificada con el
  signing secret. Ver [Slack](../slack/).
- **Discord.** Aquí se usa el endpoint de Interactions en vez de un bot de
  gateway, por lo que lo que responde son **comandos de barra**. Agrega un
  comando con una opción de texto, y después pon la "Interactions Endpoint
  URL" de la app apuntando a la URL de tu conexión. La public key de la app
  verifica la firma Ed25519. El comando se confirma al instante, y la
  respuesta llega después como follow-up. Ver [Discord](../discord/).
- **Microsoft Teams.** Registra un bot en Azure y configura su messaging
  endpoint con la URL de tu conexión. Pepe contesta al `serviceUrl` de la
  activity con un token generado a partir de las credenciales de la app. Como
  se valida el JWT entrante del Bot Framework, el endpoint puede aceptar los
  POST que llegan directo de Microsoft. Ver [Microsoft Teams](../msteams/).
- **Google Chat.** Configura el endpoint de webhook (HTTP) de la app con la
  URL de tu conexión, y provee un `access_token` OAuth para la Chat API. Las
  respuestas se publican de vuelta en el espacio correspondiente. Conviene
  dejar el endpoint detrás de un proxy. Ver [Google Chat](../googlechat/).

## Vinculación, sesiones y los dos modos

Cada conexión, y cada bot de Telegram, apunta a un `agent`. Ahí está toda la
vinculación. Cada remitente distinto termina con su propia conversación, y el
contexto se conserva por persona sin que tengas que gestionar nada de eso.

Una conexión por webhook, además, tiene un `mode` que cambia cómo se comporta
el runtime:

| | Soporte | Admin |
|--|---------|-------|
| Audiencia | De cara al público, abierto a cualquiera | Tú, limitado a los remitentes que autorizaste |
| Historial | Efímero, cada chat queda aislado | Se mantiene entre mensajes |
| Memoria | Nunca aprende nada | Las conversaciones pueden pasar a memoria |
| Comandos de barra | Se tratan como texto plano | Están habilitados (por ejemplo, `/new` reinicia y `/model` cambia de modelo) |

Para todo lo que llega desde el público, support es la opción segura por
defecto. Combínalo con un agente bien acotado (solo herramientas inofensivas,
porque del otro lado no hay ningún humano que apruebe una acción riesgosa), y
si quieres, con un tiempo de espera por inactividad. Admin, en cambio, es
para un canal de uso exclusivamente tuyo, donde los comandos de barra y la
memoria sí tienen sentido.

Hay unos cuantos campos para afinar esto conexión por conexión:

- `agent`: a qué agente está vinculada la conexión.
- `mode`: `support` o `admin`.
- `trainers`: quién puede convertir una conversación en memoria. `["*"]`
  significa todos, `[]` significa nadie, una lista limita a esos remitentes,
  y si no lo defines el valor por defecto es todos.
- `session_ttl_min`: minutos de inactividad antes de descartar la
  conversación.
- `ephemeral`: en verdadero, el historial no pasa de un mensaje al siguiente.
- `commands`: si se respetan los comandos de barra (viene activado por
  defecto en modo admin).

## Cómo se ve una conexión en la configuración

Aquí no hay base de datos de por medio: las conexiones viven en
`~/.pepe/config.json`, bajo `webhooks`, indexadas por slug. Los secretos se
guardan como `${ENV_VAR}` y se resuelven recién en tiempo de ejecución, nunca
quedan expandidos en el disco. Así luce una conexión de soporte para Slack:

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

Puedes editar este archivo a mano si quieres, pero tanto la CLI como el panel
se encargan de mantenerlo válido por ti.

## Enviar archivos

Un agente puede entregarle un archivo a la persona con la que está hablando.
Genera el archivo como le convenga (por ejemplo, con un paso de `bash` que
consulta una base de datos y escribe un `.xlsx`), y después llama a la
herramienta `send_file` pasándole la ruta:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Te dejo el informe de esta semana."
}
```

Pepe se encarga de averiguar en qué canal está esa conversación y entrega el
archivo justo ahí, sin que el agente necesite manejar ids de chat ni tokens.
Telegram lo manda como documento; WhatsApp, Slack y Discord lo suben como
contenido multimedia por sus propias APIs. Y si el canal actual no admite
adjuntos (Microsoft Teams y Google Chat solo mandan texto), la herramienta se
lo informa al agente en vez de fallar calladamente.

### Hazlo por chat

Entregar archivos ya es, en sí misma, una capacidad de chat. Cualquier agente
que tenga la herramienta `send_file` lo hace apenas se lo pides. Bastaría con
decir:

> Trae los registros de altas de la semana pasada y mándame la planilla.

El agente corre el paso que arma el archivo, y luego llama a `send_file` con
la ruta resultante. No existe una puerta de confirmación aparte para
`send_file`: solo entrega al canal propio de la conversación en curso, que
resuelve a partir de la sesión, así que no hay forma de que termine
filtrando un archivo a otra persona.

## Terminar una conversación

Un agente de soporte puede cerrar su propia conversación en cuanto un
intercambio queda resuelto, para que el próximo mensaje de esa persona
arranque de cero. Con la herramienta `end_session`, esto pasa directamente
por chat:

> Gracias, con eso alcanza.

Primero el agente manda su respuesta final, y solo después llama a
`end_session`, que borra el contexto de ese hilo en vivo, sin tocar para nada
lo que ya aprendió. Lo único que se reinicia es la conversación puntual.
Resulta útil en un canal en modo `support`, donde cada intercambio debería
quedar aislado del siguiente.

## Enrutar entre agentes

Más allá de vincular un canal a un agente, uno que tenga la herramienta
`set_route` puede, desde el chat, cambiar qué agentes tienen permiso para
escribirle a cuáles. El enrutamiento tiene dirección: dejar que el agente A
le escriba al B no implica que B pueda escribirle a A. Como esto modifica la
configuración, pasa por la barrera de permisos, y confirmas el cambio antes
de que quede activo. Podrías decir:

> Deja que el agente de triaje derive al de facturación.

El agente llama a `set_route` con `to: "billing"` (y `from` toma por defecto
al agente con el que estás hablando en ese momento), o con `action: "deny"`
para quitar una ruta. Desde la línea de comandos, esto mismo es
`pepe agent route triage billing`.

## Lo que no viene incluido

Signal, IRC e iMessage necesitan una conexión persistente o un puente
específico de la plataforma que no encaja en el modelo de webhook, así que
por ahora quedan fuera del alcance. Nada impide, eso sí, sumar un canal nuevo
como [plugin](../plugins/) de canal.

## Levantar todo junto

Con un solo comando levantas la API HTTP compatible con OpenAI, el WebSocket,
el panel, la ruta de webhooks y todos los bots de Telegram que tengas
configurados:

```bash
pepe serve --port 4000
```

El puerto también se puede fijar con la variable de entorno `PORT`. Suma
`--tunnel` para abrir un túnel público y probar canales por webhook sin
necesitar tu propio proxy inverso. Y define `PEPE_PUBLIC_URL` para que las
URL de retorno que registras con cada proveedor apunten a tu host real.
