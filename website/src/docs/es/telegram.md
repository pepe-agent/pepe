---
title: Telegram
description: Crea y gestiona bots de Telegram conectados a agentes de Pepe.
---

## Telegram

Telegram es el canal más rápido de poner en marcha porque no necesita ninguna
URL pública. Crea un bot con @BotFather, copia su token y regístralo. Pepe
consulta a Telegram en busca de mensajes nuevos, así que no hay ningún webhook
que exponer.

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
- `--trainers`: de quién puede aprender este bot hacia su memoria, y quién puede
  ejecutar sus comandos de operador. Omítelo para todos, `none` para nadie, o una
  lista separada por comas de ids de usuario para solo esos.
- `--heartbeat-minutes` y `--heartbeat-hours`: una ventana periódica opcional de
  activación (para agentes que revisan cosas según un horario). Las horas son
  una ventana local como `8-22`. Ver "Heartbeat" más abajo.
- `--progress`: cómo señala el bot que está trabajando mientras una ejecución
  está en curso. Uno de `reaction`, `ambient`, `off` o `verbose`. Ver "Mostrar
  que está trabajando" más abajo.

Listar y eliminar bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Ejecuta el poller en primer plano (un poller por bot):

```bash
pepe gateway telegram
```

Cada bot tiene su propio poller, su propio token, su propio agente vinculado, sus
propias listas de autorizados y su propio espacio de nombres de sesión. Dos bots
que resuelven al mismo token se deduplican, porque dos pollers sobre un solo token
entrarían en conflicto entre sí.

Normalmente no necesitas ejecutar eso por separado. `pepe serve` arranca los
bots de Telegram configurados junto con la API HTTP, así que un único servidor
en ejecución cubre todos los canales a la vez.

Dentro de un solo bot todavía puedes cambiar de agente por chat con
`/agent <nombre>` (ver [Enrutamiento](../routing/)). Un bot dedicado es para
cuando un canal entero debe *ser* un agente.

<div class="note"><strong>Panel.</strong> La sección Channels del panel lista
tus bots con una insignia en vivo de activo/inactivo, te permite añadir un bot,
editar con qué agente habla y eliminarlo. Escribe la misma configuración que la
línea de comandos, y los pollers en ejecución se reconcilian sin reiniciar.</div>

### Dónde vive la configuración

El bot predeterminado vive bajo `"telegram"` en `~/.pepe/config.json`. Los bots
con nombre adicionales viven bajo `"telegrams"`, un mapa de nombre a
configuración, y cada uno acepta las mismas claves que el predeterminado:

- `bot_token`: el token, literal o `${ENV_VAR}`.
- `enabled`: si arranca el poller de este bot.
- `agent`: qué agente responde.
- `allowed_chats` y `allowed_users`: las listas de ids autorizados. Déjalas fuera
  y el bot habla con cualquiera.
- `require_mention`: en un grupo, responder solo cuando se @menciona al bot.
- `reactions`: qué 👍/👎 en un mensaje llegan al agente como feedback — `own`
  (por defecto, solo reacciones en los propios mensajes del bot), `all` u
  `off`.
- `quick_reactions`: desactivado por defecto. Activado, un mensaje que es solo
  un agradecimiento o un emoji suelto ("¡gracias!", un ❤️ solo) recibe una
  reacción nativa en vez de una respuesta completa, sin gastar una llamada al
  modelo. Todo lo que tenga contenido real sigue recibiendo respuesta normal.
- `trainers`: de quién aprende el bot, y quién puede ejecutar sus comandos de
  operador.

`/whoami` en un chat es la manera fácil de encontrar los ids para esas listas.
Imprime tu id de usuario y el id del chat.

Las sesiones tienen espacio de nombres por bot. El bot predeterminado indexa sus
conversaciones como `telegram:<chat_id>`, mientras que un bot con nombre usa
`telegram:<name>:<chat_id>`. Dos bots, por tanto, nunca chocan, ni en sus
conversaciones ni en la entrega de tareas programadas.

### Comandos de barra

Cada chat es una sesión persistente, conducida con comandos de barra. También
aparecen en el menú "/" de Telegram, en el idioma que configuraste.

| Comando | Qué hace |
|---|---|
| `/new` | Empieza una conversación nueva |
| `/undo` | Deshace tu último mensaje |
| `/retry` | Rehace la última respuesta |
| `/compact` | Resume el historial para liberar contexto |
| `/stop` | Detiene la ejecución actual |
| `/inline <texto>` | Inyecta un mensaje en la ejecución ya en curso |
| `/btw <pregunta>` | Hace una pregunta aparte que no se guarda en la conversación |
| `/mention on\|off` | En un grupo, exigir o no una @mención |
| `/model [nombre] [session\|global]` | Muestra el modelo actual, o lo fija |
| `/learn` | Guarda lo que el agente aprendió en memoria y skills |
| `/whoami` | Muestra tus ids de usuario y de chat de Telegram |
| `/help` | Lista los comandos que puedes ejecutar |

Y los comandos de operador, que solo pueden ejecutar los entrenadores del bot:

| Comando | Qué hace |
|---|---|
| `/agent <nombre>` | Cambia el agente que responde en este chat |
| `/status` | Muestra información de la sesión |
| `/models` | Elige un modelo de una lista de botones |
| `/tools` | Lista las herramientas de runtime disponibles |
| `/skill [nombre]` | Lista las skills, o ejecuta una por su nombre |
| `/approve` | Gestiona los permisos de herramienta guardados |
| `/usage` | Muestra el gasto y el recuento de mensajes del mes |

Las skills instaladas se convierten también en comandos de barra propios, así que
una skill llamada `weather` responde a `/weather` además de a `/skill weather`, y
se descubre desde el menú "/". Un comando de skill cuenta como comando de
operador, porque una skill ejecuta instrucciones arbitrarias a través del agente.

#### Los comandos de operador son solo para entrenadores

Los comandos de la segunda tabla exponen la superficie de operador: tu
configuración, tus permisos, tu gasto y el inventario interno de modelos,
herramientas y skills. Están restringidos a la lista `trainers` del bot, y la
barrera está en el único punto donde se despacha cada comando, así que un comando
al que se puede llegar por dos nombres no puede esquivarla.

- Un bot **sin lista `trainers`** confía en todos aquellos con quienes habla. Es
  el bot personal, y para él no cambia nada: tienes todos los comandos, skills
  incluidas.
- Un bot **con lista `trainers`** es de cara al cliente. Un cliente que hable con
  él no puede alcanzar `/approve`, `/agent`, `/status`, `/models`, `/tools`,
  `/skill` ni `/usage`, ni ningún comando de skill. Tampoco se le anuncian:
  `/help` lista solo los comandos que quien llama puede ejecutar de verdad, y el
  menú "/" del bot se construye para la persona menos confiable que puede verlo,
  así que los comandos de operador quedan fuera del popup por completo. Quien no
  es entrenador y escribe uno de todos modos recibe un aviso de que el comando no
  está disponible ahí, y nunca ve las tripas de operador.

`/model` es, a propósito, mitad y mitad. Leerlo (`/model` sin argumentos) revela
qué modelo hay detrás del bot, que es infraestructura, así que ese camino es solo
para entrenadores. Cambiarlo no lo es: un cliente puede elegir un modelo para su
propia conversación, salvo que lo bloquees. Ver "Cambia de modelo en medio de una
conversación" abajo.

### En grupos

En un chat 1:1 el bot siempre responde. Añadido a un grupo, por defecto solo
responde cuando lo @mencionan o le das un `/comando`; si no, respondería a
cada mensaje en un grupo activo. Desactiva ese requisito por completo para un
bot (en todos los grupos en los que está) con `require_mention: false` durante
`pepe gateway telegram setup`.

Para un solo grupo, sin tocar el ajuste propio del bot, ejecuta:

```text
/mention off   # solo este grupo, hasta /new - no hace falta @mencionarlo para que responda
/mention on    # vuelve a exigir una @mención
/mention       # muestra el ajuste actual
```

La dispensa vive en la conversación de ese grupo, no en el bot, así que nunca
se filtra a ningún otro grupo en el que esté el mismo bot, y una conversación
nueva (`/new`) la olvida.

Una conversación de grupo es una sola sesión compartida entre todos los que
están en ella, sin etiquetar quién dijo qué. Si tu agente necesita
distinguir a las personas, indícaselo en su prompt. El bot también es ciego a
lo que no se le dirige: un mensaje que no lo @menciona (y no está dispensado
con `/mention off`) nunca llega al agente, ni siquiera como contexto
silencioso, así que no puede "ponerse al día" con lo que se habló antes de
que lo trajeran a la conversación.

### Temas de foro

En un grupo con **temas** activados, cada tema es su propia conversación, y la
respuesta vuelve al tema del que vino. Puedes darle a un tema **su propio
agente**: ejecuta `/agent <nombre>` dentro del tema — o simplemente **pídele** al
agente que conecte este tema a otro, y lo hace por ti — y queda vinculado a ese
agente, conservado a través de `/new` y de reinicios. Los nombres se emparejan sin
distinguir mayúsculas, así que `/agent engenheiro` encuentra un agente llamado
`Engenheiro`. Así un grupo puede tener un
tema de "soporte" atendido por el agente de soporte y uno de "ingeniería" por el
ingeniero, lado a lado. El agente de un mensaje es el agente vinculado al tema, si
lo hay; si no, el `agent` del bot; si no, el predeterminado global. Un tema
vinculado sigue la regla de mención del grupo — pon `require_mention: false` (o
`/mention off` en ese tema) si quieres que responda sin @mención.

### Cambia de modelo en medio de una conversación

`/model` muestra el modelo activo en este chat, con un botón **Browse
models** para elegir otro; `/models` va directo a ese selector. El selector está
acotado a tu proyecto y pone una marca en el modelo en uso, así que tocas uno para
cambiar. Esas dos lecturas son solo para entrenadores, ya que revelan qué modelos
hay detrás del bot. Uso escrito:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla este bot
```

Cualquiera en una conversación permitida puede cambiar su propia sesión;
cambiarlo **globalmente** (para todas las conversaciones de este bot) está
reservado para **entrenadores**, la misma lista que rige `/learn` y la
memoria, así que un miembro cualquiera del chat no puede reapuntar en
silencio todo el bot a otro modelo. Es al entrenador a quien se le pregunta cuál
de las dos opciones quiso decir; cualquier otra persona simplemente cambia su
propia conversación, sin nada que contestar. Pon `model_switch_locked: true` en el
bot para desactivar el cambio de modelo por completo para quien no sea entrenador.
Un cambio de sesión vive solo en memoria, se reinicia con `/new` o al reiniciar el
servidor, volviendo a lo que diga la configuración propia del agente.

### Mostrar que está trabajando

Mientras una ejecución está en curso, el bot muestra que está ocupado. Es a
propósito una señal ambiental, no un informe de estado que debas leer. El
indicador nativo de "escribiendo..." de Telegram sigue vivo en todos los modos.
Encima de él, `tool_progress` (la opción `--progress`) elige uno de cuatro:

- `reaction`, el predeterminado: una reacción 👀 en tu propio mensaje mientras el
  agente trabaja, retirada cuando llega la respuesta. No añade ningún mensaje al
  chat, y es el más silencioso de los cuatro.
- `ambient`: una única línea vaga ("buscando cosas...", "ejecutando algo...")
  editada en el sitio y borrada cuando llega la respuesta. Sin nombres de
  herramienta, sin argumentos, sin registro.
- `off`: nada más que el indicador nativo de escritura.
- `verbose`: el registro completo, para quien quiera seguir la ejecución. Cada
  llamada a una herramienta según ocurre y, encima de ella, la frase que el
  modelo dijo antes de recurrir a esa herramienta. El registro cuenta *qué* hizo;
  la frase cuenta *por qué*, que es lo que permite ver al agente yendo hacia el
  sitio equivocado antes de que llegue. Sigue siendo un solo mensaje, editado en
  el sitio, borrado cuando llega la respuesta.

Fíjalo de tres formas: desde la línea de comandos con `--progress`; desde un chat
con la herramienta `manage_channel` (`set_progress`); o en el **panel**, en
Canales → tu bot → *Editar* → "Mientras el agente trabaja", donde se explica cada modo.

### Heartbeat: avisos proactivos

Un bot puede darle periódicamente la palabra a su agente para que diga algo **por
iniciativa propia** ("el deploy terminó", "me pediste que vigilara X") y, tan
importante como eso, el derecho a **no decir nada** la mayor parte del tiempo.
Viene desactivado, y lo activas por bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Un agente que tenga la herramienta `manage_channel` también puede configurar esto
por su cuenta, desde un chat:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Cada pulso ejecuta el agente sobre el contexto vivo de su sesión, con un prompt
que dice que esta es una comprobación automática y que responda exactamente
`HEARTBEAT_OK` si no hay nada que valga la pena decir. Ese es el caso común, y
solo un mensaje genuino llega a enviarse al chat. Lo alimentas con dos cosas:

- Un `HEARTBEAT.md` opcional en el workspace del agente, que es donde escribes qué
  hay que vigilar.
- **Eventos de sistema**, que cualquier parte de Pepe puede encolar para una sesión
  (`Pepe.Heartbeat.Events.push/2`), y que el siguiente pulso recoge solo.

Un bucle proactivo desbocado es imposible por construcción. Una barrera de
enfriamiento impone un mínimo de 30 segundos entre pulsos, y un cortacircuitos de
avalancha salta a los 5 disparos en 60 segundos. `heartbeat_hours` (una ventana
local como `8-22`) mantiene al bot callado fuera de las horas en que estás
despierto.

### Los chats muertos se curan solos

Si un envío vuelve con fallo permanente, porque bloquearon al bot o porque el chat
o el usuario ya no existen, ese chat se salta en todos los envíos siguientes. No
hay llamadas de API desperdiciadas ni ruido en el registro. En el momento en que un
envío a ese chat vuelve a funcionar, por ejemplo porque la persona desbloqueó al
bot, la marca se retira automáticamente. No hay nada que reiniciar a mano.

### Idioma y errores

Los mensajes fijos del propio Pepe (respuestas de comando, botones, negativas)
siguen el `locale` que configuraste. Las respuestas del agente siguen el idioma en
que escribe la persona, sea cual sea. Los errores internos en crudo nunca se
filtran al chat.

### Hazlo por chat

Un agente que tenga la herramienta `manage_channel` puede crear y revincular
bots de Telegram desde una conversación. Como edita la configuración, cada
llamada pasa por la barrera de permisos: el agente propone el cambio y tú
confirmas antes de que se aplique.

Dirías:

> Añade un bot de Telegram llamado sales que hable con el agente de ventas. El
> token está en la variable de entorno SALES_BOT_TOKEN.

El agente llama a `manage_channel` con `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` y `agent: "sales"`. Aquí importan dos
salvaguardas:

- **Los secretos nunca pasan por el chat.** Das el *nombre* de una variable de
  entorno que contiene el token, nunca el token en sí. Se almacena como
  `${SALES_BOT_TOKEN}` y se resuelve al momento de leerlo, así que el secreto en
  crudo nunca llega al modelo ni a los registros. Un token en crudo (que
  contiene dos puntos) es rechazado. Esa variable de entorno la defines tú.
- **El bot predeterminado protegido está vedado.** La herramienta solo toca bots
  con nombre, nunca el `default`, y no toca nada más de tu configuración.

Otras acciones de `manage_channel` son `list`, `set_agent` (revincular un bot a
otro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` y `remove`. Tras cualquier cambio reconcilia los pollers en
ejecución, así que un bot arranca o se detiene en vivo sin reiniciar.

<div class="note"><strong>Solo Telegram.</strong> La herramienta de chat
gestiona bots de Telegram. Las conexiones por webhook (WhatsApp, Slack y las
demás) se crean desde la línea de comandos, el panel o <code>pepe setup</code>,
no por chat.</div>
