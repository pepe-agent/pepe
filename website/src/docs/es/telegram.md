---
title: Telegram
description: Crea y gestiona bots de Telegram conectados a agentes de Pepe.
---

## Telegram

De todos los canales, Telegram es el que menos esfuerzo pide para arrancar: no hace falta ninguna URL pública. Basta con crear un bot con @BotFather, copiar su token y registrarlo. Es Pepe quien va a buscar los mensajes nuevos a Telegram, así que no necesitas exponer nada de tu máquina a internet.

Configura el bot predeterminado de forma interactiva:

```bash
pepe gateway telegram setup
```

El asistente pide el token (puedes pegarlo literal o como referencia `${ENV_VAR}`), un agente opcional al que vincularlo, y una lista opcional de ids de chat con permiso para hablarle.

También puedes tener varios bots corriendo a la vez, cada uno atado a un agente distinto:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Opciones de `telegram add`:

- `--token` (obligatorio): el token del bot, literal o `${ENV_VAR}`.
- `--agent`: el agente que responde. Si lo omites, se usa tu agente predeterminado.
- `--trainers`: quién puede alimentar la memoria de este bot y ejecutar sus comandos de operador. Omítelo para que sea cualquiera, pon `none` para que no sea nadie, o dale una lista de ids de usuario separados por comas.
- `--heartbeat-minutes` y `--heartbeat-hours`: activan una ventana periódica de despertar, pensada para agentes que revisan algo con cierta cadencia. Las horas se dan como una ventana local, tipo `8-22`. Más sobre esto en "Heartbeat" más abajo.
- `--progress`: cómo le hace saber el bot al usuario que está trabajando mientras corre una ejecución. Acepta `reaction`, `ambient`, `off` o `verbose`; ver "Mostrar que está trabajando" más abajo.

Listar y quitar bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Ejecutar el poller en primer plano (un poller por bot):

```bash
pepe gateway telegram
```

Cada bot corre con su propio poller, su propio token, su propio agente, sus propias listas de acceso y su propio espacio de sesiones. Si dos bots terminan apuntando al mismo token se deduplican automáticamente, porque dos pollers sobre un único token chocarían entre sí.

En la práctica casi nunca hace falta correr ese comando aparte: `pepe serve` ya arranca los bots de Telegram configurados junto con la API HTTP, así que con un solo servidor en marcha cubres todos los canales de una vez.

Dentro de un mismo bot todavía puedes cambiar de agente chat por chat con `/agent <nombre>` (ver [Enrutamiento](../routing/)). Un bot dedicado tiene sentido cuando quieres que un canal entero *sea* un único agente.

<div class="note"><strong>Panel.</strong> La sección Channels del panel lista tus bots con una insignia en vivo de activo o inactivo, te deja añadir un bot, cambiar con qué agente habla y eliminarlo. Escribe la misma configuración que la línea de comandos, y los pollers en ejecución se ajustan solos, sin reiniciar nada.</div>

### Dónde vive la configuración

El bot predeterminado se guarda bajo `"telegram"` en `~/.pepe/config.json`. Los bots con nombre propio van bajo `"telegrams"`, un mapa de nombre a configuración, y cada uno admite las mismas claves que el predeterminado:

- `bot_token`: el token, literal o `${ENV_VAR}`.
- `enabled`: si el poller de este bot arranca o no.
- `agent`: el agente que responde.
- `allowed_chats` y `allowed_users`: las listas de ids con acceso. Si las dejas vacías, el bot le habla a cualquiera.
- `require_mention`: en un grupo, responder solo cuando se @menciona al bot.
- `reactions`: qué 👍/👎 sobre un mensaje llegan al agente como feedback: `own` (por defecto, solo reacciones sobre los propios mensajes del bot), `all`, u `off`. Todo agente ya sabe qué hacer con esto: con un 👍 anota en su memoria qué funcionó, con un 👎 qué evitar la próxima vez, y nunca responde a la reacción como tal. Pasa por la misma revisión que cualquier otra escritura de memoria, en la página Learning del panel, antes de quedar guardado.
- `quick_reactions`: apagado por defecto. Si lo enciendes, un mensaje que sea solo un agradecimiento o un emoji suelto ("¡gracias!", un ❤️ solo) recibe una reacción nativa en lugar de una respuesta completa, sin gastar ninguna llamada al modelo. Cualquier cosa con contenido real sigue recibiendo respuesta normal.
- `trainers`: de quién aprende el bot y quién puede correr sus comandos de operador.

`/whoami`, escrito en un chat, es la forma más rápida de conseguir los ids para esas listas: devuelve tu id de usuario y el id del chat.

Las sesiones tienen espacio de nombres por bot. El predeterminado guarda sus conversaciones como `telegram:<chat_id>`, mientras que un bot con nombre usa `telegram:<name>:<chat_id>`. Así, dos bots nunca se pisan, ni en sus conversaciones ni en la entrega de tareas programadas.

### Comandos de barra

Cada chat funciona como una sesión persistente que se maneja con comandos de barra. Estos también aparecen en el menú "/" de Telegram, en el idioma que hayas configurado.

| Comando | Qué hace |
|---|---|
| `/new` | Empieza una conversación nueva |
| `/undo` | Deshace tu último mensaje |
| `/rewind N` | Retrocede N intercambios y sigue la conversación desde ahí |
| `/retry` | Repite la última respuesta |
| `/compact` | Resume el historial para liberar contexto |
| `/stop` | Detiene la ejecución en curso |
| `/inline <texto>` | Mete un mensaje dentro de la ejecución que ya está en marcha |
| `/btw <pregunta>` | Hace una pregunta al margen, que no queda guardada en la conversación |
| `/mention on\|off` | En un grupo, exige o no una @mención |
| `/model [nombre] [session\|global]` | Muestra el modelo actual, o lo cambia |
| `/learn` | Guarda lo aprendido en memoria y skills |
| `/whoami` | Muestra tu id de usuario y el del chat en Telegram |
| `/help` | Lista los comandos disponibles para ti |

#### Retroceder unos cuantos intercambios

Cuando el agente coge un camino equivocado y las tres respuestas siguientes ya se
apoyan en él, `/rewind 3` quita esos tres intercambios de la conversación y
retoma desde antes. No cambia nada más: el mismo chat, el mismo agente, y todo lo
que ya sabía de antes sigue ahí. Cuenta intercambios tal como los ves en tu
propia pantalla, así que no hay ningún número de mensaje que ir a buscar.

Si pides más de lo que tiene la conversación, retrocede todo lo que puede y te
dice cuántos intercambios fueron, en vez de negarse y dejarte adivinar un número
más pequeño. Lo que sale no vuelve, así que, para probar otro camino sin perder
el actual, ramifica la conversación (el `/fork` del panel).

Si el historial ya se resumió para ahorrar contexto, el resumen se queda. Cubre
intercambios condensados mucho antes, que ningún rewind recupera, y nunca habla
de lo que el rewind acaba de quitar.

Y los comandos de operador, reservados a los entrenadores del bot:

| Comando | Qué hace |
|---|---|
| `/agent <nombre>` | Cambia el agente que responde en este chat |
| `/status` | Muestra información de la sesión |
| `/models` | Elige un modelo desde una lista de botones |
| `/tools` | Lista las herramientas disponibles en el runtime |
| `/skill [nombre]` | Lista las skills, o ejecuta una por su nombre |
| `/approve` | Administra los permisos de herramientas guardados |
| `/usage` | Muestra el gasto y la cantidad de mensajes del mes |

Cada skill instalada se convierte también en su propio comando de barra: una skill llamada `weather` responde tanto a `/weather` como a `/skill weather`, y aparece en el menú "/". Un comando de skill cuenta como comando de operador, porque una skill ejecuta instrucciones arbitrarias a través del agente.

#### Los comandos de operador son solo para entrenadores

Los comandos de la segunda tabla dejan ver la parte de operador: tu configuración, tus permisos, tu gasto y el inventario interno de modelos, herramientas y skills. Están restringidos a la lista `trainers` del bot, y ese control vive en el único punto por donde se despachan todos los comandos, así que ni siquiera un comando accesible por dos nombres distintos puede esquivarlo.

- Un bot **sin lista `trainers`** confía en cualquiera con quien hable. Es el caso del bot personal, y para él no cambia nada: tienes todos los comandos disponibles, skills incluidas.
- Un bot **con lista `trainers`** está pensado de cara al cliente. Alguien que le hable sin ser entrenador no puede llegar a `/approve`, `/agent`, `/status`, `/models`, `/tools`, `/skill` ni `/usage`, ni a ningún comando de skill. Tampoco se los muestra: `/help` lista solo lo que quien pregunta puede ejecutar de verdad, y el menú "/" del bot se arma pensando en la persona menos confiable que pueda verlo, así que los comandos de operador quedan fuera del todo. Si alguien sin ese rol escribe uno igual, se le avisa que el comando no está disponible ahí, sin dejar ver nada del funcionamiento interno.

`/model` está, a propósito, partido en dos. Leerlo (`/model` sin argumentos) revela qué modelo hay detrás del bot, y eso es información de infraestructura, así que esa lectura es solo para entrenadores. Cambiarlo es otra historia: cualquier cliente puede elegir un modelo para su propia conversación, a menos que lo bloquees tú. Ver "Cambiar de modelo en plena conversación" más abajo.

### En grupos

En un chat 1 a 1 el bot siempre contesta. Metido en un grupo, por defecto solo responde si lo @mencionan o si recibe un `/comando`, porque de otro modo terminaría contestando cada mensaje de un grupo activo. Puedes quitar ese requisito por completo para un bot (en todos los grupos donde participe) con `require_mention: false` durante `pepe gateway telegram setup`.

Para un grupo puntual, sin tocar el ajuste general del bot, corre esto dentro de ese grupo:

```text
/mention off   # solo en este grupo, hasta /new - no hace falta @mencionarlo para que responda
/mention on    # vuelve a exigir una @mención
/mention       # muestra el ajuste actual
```

Esa excepción queda guardada en la conversación de ese grupo puntual, no en el bot, así que jamás se cuela en otro grupo donde esté el mismo bot, y una conversación nueva (`/new`) la olvida.

Una conversación de grupo es una única sesión compartida por todos los que participan en ella. Cada mensaje entrante lleva el nombre de quien lo escribió (`Alice: ¿cómo va?`), de modo que el modelo sabe a quién le responde en cada turno, en vez de asumir que quien escribió al final es la misma persona de la que se hablaba antes; una conversación privada nunca lleva esa etiqueta, porque ahí no hay nadie más a quien pudiera referirse. El bot también es ciego a lo que no se le dirige: un mensaje que no lo @menciona (y que no está exceptuado con `/mention off`) jamás llega al agente, ni siquiera como contexto silencioso, así que no hay forma de que "se ponga al día" con algo que se habló antes de que lo trajeran a la conversación.

### Temas de foro

En un grupo con **temas** activados, cada tema funciona como su propia conversación, y la respuesta vuelve al tema de donde salió. Puedes asignarle a un tema **su propio agente**: corre `/agent <nombre>` dentro del tema (o directamente **pídele** al agente que conecte ese tema con otro y lo hace por ti), y queda vinculado a ese agente de forma persistente, incluso a través de `/new` y de reinicios. Los nombres se comparan sin distinguir mayúsculas, así que `/agent engenheiro` encuentra igual a un agente llamado `Engenheiro`. De esta manera, un mismo grupo puede tener un tema de "soporte" atendido por el agente de soporte y uno de "ingeniería" por el de ingeniería, cada uno funcionando por su cuenta. El agente que responde un mensaje es el que está vinculado al tema si lo hay; si no, el `agent` del bot; y si tampoco, el predeterminado global. Un tema vinculado sigue respetando la regla de mención del grupo: pon `require_mention: false` (o `/mention off` dentro de ese tema) si quieres que conteste sin necesidad de @mención.

### Cambiar de modelo en plena conversación

`/model` muestra el modelo activo en ese chat, con un botón **Browse models** para elegir otro; `/models` va directo a ese selector. El selector está acotado a tu proyecto y marca con un check el modelo en uso, así que basta con tocar uno para cambiar. Ambas lecturas son solo para entrenadores, porque revelan qué modelos hay detrás del bot. Escrito a mano:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo esta conversación
/model openrouter global        # cambia para todas las conversaciones de este bot
```

Cualquiera en una conversación permitida puede cambiar su propia sesión; cambiarlo **globalmente** (para todas las conversaciones que atiende este bot) queda reservado a los **entrenadores**, la misma lista que controla `/learn` y la memoria, de modo que nadie del grupo puede reapuntar en silencio todo el bot hacia otro modelo. Al entrenador se le pregunta cuál de las dos opciones quiso decir; cualquier otra persona simplemente cambia su propia conversación, sin que se le pregunte nada más. Pon `model_switch_locked: true` en el bot si quieres apagar por completo el cambio de modelo para quien no sea entrenador. Un cambio hecho a nivel de sesión vive solo en memoria: se pierde con `/new` o con un reinicio del servidor, y vuelve a lo que diga la configuración propia del agente.

### Mostrar que está trabajando

Mientras una ejecución está en marcha, el bot deja ver que está ocupado. Es, a propósito, una señal ambiental y no un reporte que debas leer con atención. El indicador nativo de "escribiendo..." de Telegram sigue activo en todos los modos. Por encima de eso, `tool_progress` (la opción `--progress`) elige entre cuatro:

- `reaction`, el modo por defecto: una reacción 👀 sobre tu propio mensaje mientras el agente trabaja, que desaparece cuando llega la respuesta. No agrega ningún mensaje al chat, y es el más discreto de los cuatro.
- `ambient`: una única línea vaga ("buscando información...", "ejecutando algo...") que se edita en el sitio y se borra al llegar la respuesta. Sin nombres de herramientas, sin argumentos, sin bitácora.
- `off`: nada más que el indicador nativo de escritura.
- `verbose`: la bitácora completa, para quien quiera seguir la ejecución paso a paso. Cada llamada a herramienta a medida que ocurre, y arriba de ella la frase que el modelo pensó antes de recurrir a esa herramienta. La bitácora cuenta *qué* hizo; la frase cuenta *por qué*, y eso es justo lo que te permite notar que algo va mal antes de que termine de salir mal. Sigue siendo un solo mensaje, editado en el sitio, que se borra cuando llega la respuesta.

Puedes fijarlo de tres formas: desde la línea de comandos con `--progress`; desde un chat, con la herramienta `manage_channel` (`set_progress`); o en el **panel**, en Channels → tu bot → *Edit* → "While the agent works", donde cada modo aparece explicado.

### Heartbeat: avisos por iniciativa propia

Un bot puede darle periódicamente la palabra a su agente para que diga algo **por su cuenta** ("terminó el deploy", "me pediste que vigilara X") y, tan importante como eso, para que la mayoría de las veces decida **no decir nada**. Viene apagado, y lo activas bot por bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Un agente que tenga la herramienta `manage_channel` también puede configurar esto solo, desde el chat:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Cada pulso corre al agente sobre el contexto vivo de su sesión, con un prompt que le aclara que es una comprobación automática y que debe responder exactamente `HEARTBEAT_OK` si no hay nada digno de mencionar. Ese es el caso más común, y solo un mensaje genuino termina llegando al chat. Lo alimentas de dos maneras:

- Con un `HEARTBEAT.md` opcional en el workspace del agente, donde anotas qué hay que vigilar.
- Con **eventos de sistema**, que cualquier parte de Pepe puede encolar para una sesión (`Pepe.Heartbeat.Events.push/2`), y que el siguiente pulso recoge automáticamente.

Un bucle proactivo descontrolado es imposible por diseño: hay una barrera de enfriamiento que exige al menos 30 segundos entre pulsos, y un disyuntor que corta si se disparan 5 en 60 segundos. `heartbeat_hours` (una ventana local como `8-22`) mantiene al bot en silencio fuera de las horas en que puede molestar.

### Los chats muertos se recuperan solos

Cuando un envío vuelve con un fallo permanente, porque el bot fue bloqueado o el chat o el usuario ya no existen, ese chat queda excluido de los siguientes envíos. No se desperdician llamadas a la API ni se llena el log de ruido. En cuanto un envío a ese chat vuelve a funcionar, por ejemplo porque desbloquearon al bot, la marca se retira sola. No hay nada que reiniciar a mano.

### Una respuesta sobrevive a un reinicio a mitad de envío

Si Pepe se reinicia (un deploy, una caída) justo cuando estaba enviando la respuesta de un turno, esa respuesta no se pierde: se reenvía apenas el bot vuelve a estar en línea, antes de ocuparse de cualquier cosa nueva. Cuando el reinicio ocurrió mientras el envío estaba realmente en curso (así que no hay certeza de si el mensaje llegó o no), la copia reenviada lleva el prefijo "♻️ Recovered reply", para que un posible duplicado quede siempre marcado en lugar de repetirse en silencio. Una respuesta que nunca alcanzó a enviarse sale limpia, sin prefijo. No requiere ninguna configuración y no hay nada que reiniciar a mano.

### Idioma y errores

Los mensajes fijos del propio Pepe (respuestas de comandos, botones, negativas) siguen el `locale` que configuraste. Las respuestas del agente siguen el idioma en el que te escriban, sea cual sea. Los errores internos nunca se filtran al chat en crudo.

### Hazlo por chat

Un agente con la herramienta `manage_channel` puede crear y revincular bots de Telegram desde una conversación. Como esto modifica configuración, cada llamada pasa por la barrera de permisos: el agente propone el cambio y tú lo confirmas antes de que se aplique.

Podrías decir:

> Agrega un bot de Telegram llamado sales que hable con el agente de ventas. El token está en la variable de entorno SALES_BOT_TOKEN.

El agente llama a `manage_channel` con `action: "add"`, `name: "sales"`, `token_env: "SALES_BOT_TOKEN"` y `agent: "sales"`. Aquí importan dos resguardos:

- **Los secretos nunca pasan por el chat.** Le das el *nombre* de una variable de entorno que contiene el token, nunca el token en sí. Queda guardado como `${SALES_BOT_TOKEN}` y se resuelve al leerlo, así que el secreto en crudo jamás llega al modelo ni a los logs. Si pegas un token en crudo (que contiene dos puntos), se rechaza. Esa variable de entorno la defines tú mismo.
- **El bot predeterminado protegido queda fuera de alcance.** La herramienta solo toca bots con nombre propio, nunca el `default`, y no toca nada más de tu configuración.

Las demás acciones de `manage_channel` son `list`, `set_agent` (revincular un bot a otro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`, `disable` y `remove`. Después de cualquier cambio, ajusta los pollers en ejecución, así que un bot arranca o se detiene en vivo, sin reiniciar nada.

<div class="note"><strong>Solo Telegram.</strong> Esta herramienta de chat gestiona bots de Telegram. Las conexiones por webhook (WhatsApp, Slack y el resto) se crean desde la línea de comandos, el panel o <code>pepe setup</code>, no por chat.</div>
