---
title: Telegram
description: Crea y gestiona bots de Telegram conectados a agentes de Pepe.
---

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
  todos, `none` para nadie, o una lista separada por comás de ids de usuario
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

### Cambia de modelo en medio de una conversación

`/model` muestra el modelo activo en este chat, con un botón **Browse
models** para elegir otro; `/models` va directo a ese selector. Uso escrito:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla este bot
```

Cualquiera en una conversación permitida puede cambiar su propia sesión;
cambiarlo **globalmente** (para todas las conversaciones de este bot) está
reservado para **entrenadores** - la misma lista que rige `/learn` y la
memoria - así que un miembro cualquiera del chat no puede reapuntar en
silencio todo el bot a otro modelo. Pon `model_switch_locked: true` en el bot
para desactivar el cambio de modelo por completo para quien no sea entrenador.
Un cambio de sesión vive solo en memoria - se reinicia con `/new` o al
reiniciar el servidor, volviendo a lo que diga la configuración propia del
agente.

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
