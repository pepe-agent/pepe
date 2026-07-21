---
title: Agentes
description: Define un agente a partir de un prompt, un modelo y un conjunto de herramientas, y deja que el runtime llame al modelo, ejecute herramientas y repita el ciclo hasta tener una respuesta.
---

## Qué es un agente

Un agente es una definición pequeña y declarativa. Tiene un nombre, un system
prompt que le da una personalidad, una conexión de modelo con la que razonar y una
lista de herramientas que se le permite llamar. Un puñado de ajustes extra (un
límite de iteraciones, una temperatura, con quién puede hablar, a quién puede
administrar) lo completan. Eso es todo. El agente no contiene lógica propia. El
runtime de Pepe hace el trabajo: llama al modelo, ejecuta las herramientas que el
modelo pide, devuelve los resultados y repite hasta que hay una respuesta final.

Cada agente vive como una entrada dentro de un único archivo JSON en
`~/.pepe/config.json`. No hay base de datos. Puedes crear y editar agentes de tres
formas, y todas escriben en el mismo archivo:

1. La herramienta de línea de comandos `pepe`.
2. El panel web.
3. Una conversación normal, hablando con un agente que tenga la herramienta de
   gestión correspondiente.

Así se ve un agente completo tal como queda en disco:

```json
{
  "agents": {
    "assistant": {
      "description": "General-purpose helper",
      "model": "openrouter",
      "system_prompt": "Eres un asistente útil y directo.",
      "tools": ["bash", "read_file", "write_file", "web_search"],
      "auto_approve": [],
      "can_message": [],
      "can_manage": null,
      "hooks": [],
      "max_iterations": 12,
      "temperature": null
    }
  }
}
```

## Tu primer agente

Un agente necesita una conexión de modelo antes de poder razonar. Si aún no has
creado ninguna, la configuración guiada te acompaña para elegir un proveedor,
iniciar sesión y escoger un modelo:

```bash
pepe setup
```

Después define un agente con un prompt y algunas herramientas:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "Eres un asistente útil y directo." \
  --tools bash,read_file,write_file,web_search
```

Ejecuta un prompt de una sola vez contra él. La respuesta se transmite a tu
terminal a medida que se produce:

```bash
pepe run assistant "¿Qué archivos hay en el directorio actual?"
```

Ese único comando dispara el ciclo completo. El agente decide que necesita mirar
el sistema de archivos, llama a la herramienta `list_dir` o `bash`, lee el
resultado y te responde en lenguaje natural.

<div class="note"><strong>Desde el panel.</strong> La sección de Agentes del panel
web hace lo mismo con un formulario: nombre, personalidad, modelo, una lista de
verificación de herramientas y el alcance de administración. Escribe la misma
entrada en <code>~/.pepe/config.json</code>, así que puedes combinar libremente la
CLI, el panel y la edición manual.</div>

### Hazlo por chat

Cualquier agente que tenga la herramienta `manage_agent` puede crear y configurar
otros agentes por conversación. Así es como el primerísimo agente (mira "El agente
propietario" más abajo) te deja construir el resto de tu flota sin tocar la CLI. Un
mensaje como:

```text
Crea un agente llamado researcher. Dale una persona enfocada en investigación
web cuidadosa, apúntalo al modelo openrouter y activa web_search y
fetch_url.
```

El agente llama a `manage_agent` con `action: "create"`, y luego a `set_persona`,
`set_model` y `add_tool` para cada capacidad. `manage_agent` es una herramienta de
riesgo: pasa por la barrera de permisos, así que en una superficie que puede
preguntar (la consola, un canal de chat) el runtime te pide autorizar el cambio
antes de escribirlo, y la propia herramienta tiene la instrucción de confirmar el
plan contigo primero. Un agente solo puede gestionar los agentes dentro de su
alcance `can_manage` (que se trata en [Administrar agentes](#administrar-agentes) más abajo); pedirle que
toque uno fuera de ese alcance se rechaza con cortesía.

## Los campos, uno por uno

| Campo | Qué hace | Predeterminado |
|-------|--------------|---------|
| `name` | La etiqueta direccionable del agente. Dentro de un proyecto se convierte en un handle como `acme/assistant` (mira más abajo). El agente lleva además un id interno estable, así que este nombre se puede cambiar sin romper ningún vínculo. | obligatorio |
| `description` | Una nota breve para humanos. Nunca se envía al modelo. | ninguno |
| `model` | El nombre de una conexión de modelo. Déjalo sin definir para usar el modelo predeterminado del proyecto. | predeterminado del proyecto |
| `system_prompt` | La personalidad y las instrucciones con las que se ejecuta el agente. | `Eres Pepe, un agente de IA útil.` (un prompt inicial) |
| `tools` | La lista de nombres de herramientas que este agente puede llamar. Solo estas se ofrecen al modelo. | todas las herramientas cuando se omite `--tools` al crear |
| `auto_approve` | Herramientas que este agente puede ejecutar sin pedir permiso. `["*"]` significa todas. | `[]` |
| `can_message` | Otros agentes a los que este puede enviar mensajes (una ruta dirigida). | `[]` |
| `can_manage` | Qué agentes puede administrar este. Mira [Administrar agentes](#administrar-agentes). | `null` (solo a sí mismo) |
| `hooks` | Transformaciones del flujo de mensajes a aplicar, como la censura de datos personales. | `[]` |
| `max_iterations` | El tope máximo de rondas de modelo más herramienta que puede tener un turno. | `12` |
| `temperature` | Temperatura de muestreo pasada al modelo. Sin definir usa el valor predeterminado del proveedor. | predeterminado del proveedor |
| `triage_model` | Una conexión de modelo que juzga la complejidad antes del primer turno de una sesión. Mira [Enrutamiento de modelo por complejidad](#enrutamiento-de-modelo-por-complejidad). | ninguno (desactivado) |
| `simple_model` | La conexión de modelo a la que bajar cuando `triage_model` juzga una conversación simple. | ninguno |

## Cómo se ejecuta el ciclo de llamadas a herramientas

Cuando envías un turno a un agente, el runtime hace esto:

1. Llama al modelo con la conversación hasta el momento y las especificaciones JSON
   de cada herramienta de la lista permitida del agente.
2. Si el modelo responde con una respuesta final, esa respuesta se devuelve y el
   ciclo termina.
3. Si en cambio el modelo pide llamar a una o más herramientas, el runtime ejecuta
   cada una, añade los resultados a la conversación y vuelve al paso 1.
4. Esto se repite hasta que el modelo produce una respuesta final o el ciclo alcanza
   `max_iterations`. Si se llega al tope, el turno termina con la nota
   `(stopped: max iterations reached)`.

Como los resultados se devuelven al modelo, este puede encadenar pasos. Puede leer
un archivo, decidir que necesita otro, leerlo también y luego escribir un resumen,
todo dentro de un mismo turno. El límite de iteraciones es la salvaguarda que evita
que un agente confundido dé vueltas para siempre.

Otras dos barreras se sitúan delante de la llamada al modelo. Un agente cuyo modelo
exige censura se niega a ejecutarse salvo que tenga un hook de censura activado, y
un proyecto que ha alcanzado su tope de gasto mensual (o su tope de mensajes de
clientes al mes, un límite independiente) se detiene aquí sin nuevas llamadas al
modelo ni respuestas. Ambas fallan el turno de forma limpia en lugar de seguir en
silencio; consulta Facturación y límites para ver cómo configurar esos topes.

<div class="note"><strong>Transmisión y eventos.</strong> A medida que el ciclo se
ejecuta emite eventos de ciclo de vida: un fragmento de texto transmitido
(<code>assistant_delta</code>), un mensaje completo del asistente
(<code>assistant</code>), una llamada de herramienta (<code>tool_call</code>), una
herramienta rechazada (<code>tool_denied</code>), un resultado de herramienta
(<code>tool_result</code>), un cambio a un modelo de respaldo
(<code>failover</code>), un registro de uso de tokens (<code>usage</code>), una
respuesta final (<code>done</code>) o un error (<code>error</code>). La CLI, el
WebSocket y los canales de mensajería los muestran en vivo, y por eso ves la
escritura y la actividad de herramientas a medida que ocurre en lugar de un solo
bloque al final.</div>

## Herramientas y la barrera de permisos

Una herramienta es una capacidad. Un agente solo puede hacer lo que su lista
`tools` permite. Dale a un agente `read_file` pero no `write_file` y podrá mirar
pero no tocar.

Lista todas las herramientas disponibles en tu instalación:

```bash
pepe tools
```

El conjunto integrado cubre lo esencial:

| Herramienta | Qué hace |
|------|--------------|
| `bash` | Ejecuta un comando de shell. |
| `run_script` | Escribe y ejecuta un programa corto en Python, Node, Ruby o Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Trabaja con archivos en el espacio de trabajo del agente. |
| `fetch_url`, `web_search` | Lee una página web o busca en la web. |
| `send_file` | Entrega un archivo que el agente produjo en el canal actual. |
| `send_to_agent` | Envía un mensaje a otro agente (sujeto a `can_message`). |
| `ask_user` | Te pide que elijas una entre varias opciones, con botones/menú reales donde el canal lo permite. |
| `schedule_task`, `watch` | Crea trabajos recurrentes y vigilancias de una sola vez del tipo "avísame cuando pase X". |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Gestiona agentes, herramientas y enrutamiento desde el chat. |
| `manage_channel`, `end_session` | Conecta y cierra canales de mensajería desde el chat. |
| `manage_mcp`, `scan_skill`, `skill` | Añade servidores de herramientas externas y habilidades. |
| `manage_plugin` | Instala, escanea, lista y elimina plugins de la comunidad (herramientas, canales) desde el chat. |
| `config_get`, `config_set`, `doctor` | Inspecciona y cambia la configuración bajo salvaguardas, ejecuta diagnósticos. |

Algunas herramientas son de solo lectura y se ejecutan sin restricciones: `read_file`,
`list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`,
`scan_skill` y `send_to_agent` (que se rige por la lista de rutas permitidas
`can_message` en su lugar). Todo lo demás, incluida cualquier herramienta de plugin,
se trata como de riesgo y pasa por una barrera de permisos antes de ejecutarse.

Cuando una herramienta de riesgo no ha sido aprobada de antemano y la superficie
puede preguntar a una persona (la consola, un canal de chat), el runtime te pide
autorizar la llamada. Puedes responder:

- Permitir una vez. Vuelve a preguntar la próxima vez.
- Permitir durante el resto de esta sesión. Se guarda en memoria y se olvida al
  reiniciar.
- Permitir siempre. Se persiste en el agente añadiendo la herramienta a su lista
  `auto_approve`.
- Denegar. Nunca se recuerda, así que se vuelve a preguntar.

Pon tú mismo una herramienta en `auto_approve` para saltarte el aviso desde el
principio. En superficies sin una persona a quien preguntar (por ejemplo la API HTTP,
un webhook, una tarea cron) una herramienta sujeta a la barrera se rechaza en lugar de
ejecutarse sin vigilancia: solo corre lo que ya está en `auto_approve`.

### Pedirte que elijas

Algunas preguntas se responden mejor con un toque que con una respuesta escrita.
`ask_user` permite a un agente presentar una pregunta de opción múltiple genuina y
recibir la elección de vuelta dentro del mismo turno, en lugar de adivinar o terminar
su turno esperando que el siguiente mensaje responda justo lo que preguntó. Telegram lo
muestra como botones en línea reales; la consola, como un menú numerado; el chat del
panel, como opciones pulsables. Se ejecuta libremente (preguntar no conlleva ningún
riesgo propio, así que nunca pasa por la barrera), pero solo funciona donde hay una
persona interactiva a quien preguntar: la API HTTP, un webhook o una ejecución
desatendida de cron/watch rechazan la llamada directamente en vez de quedarse esperando
un botón que nadie puede pulsar.

### Hazlo por chat

Un agente que acaba de instalar un plugin, o que quiere una capacidad que todavía no
tiene, puede activar una herramienta en sí mismo con `enable_tool`:

```text
Enable the web_search tool for yourself.
```

El agente llama a `enable_tool` con el nombre de la herramienta. La herramienta ya
debe existir como integrada o como plugin instalado, y el cambio surte efecto en el
siguiente mensaje del agente. `enable_tool` también pasa por la barrera de permisos,
así que autorizas la concesión antes de que se escriba.

## La conexión de modelo

`model` nombra una conexión que definiste con `pepe model add`. Dejarlo sin definir
significa que el agente usa el modelo predeterminado de su alcance, así que puedes
apuntar todo un conjunto de agentes a un proveedor y cambiarlos todos modificando un
solo predeterminado.

Una conexión de modelo puede llevar una cadena de respaldo. Cuando el modelo
primario del agente falla con un error transitorio (un límite de tasa, un tiempo de
espera agotado, un corte de red o un 5xx), el runtime baja por la cadena y reintenta
con el siguiente modelo, emitiendo un evento `failover` mientras lo hace. Un error
grave como una clave de API incorrecta o una petición mal formada falla de inmediato,
ya que otro endpoint no lo arreglaría.

Pepe habla con los proveedores mediante el protocolo Chat Completions de OpenAI, así
que cualquier endpoint compatible con OpenAI funciona sin cambiar código.

### Hazlo por chat

Un agente con la herramienta `manage_agent` puede reapuntar un modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

El agente llama a `manage_agent` con `action: "set_model"`. El modelo destino debe
ser una conexión configurada, y el cambio pasa por la barrera de permisos como
cualquier otra edición de configuración.

## Enrutamiento de modelo por complejidad

El propio `model` de un agente se trata como el buen valor por defecto.
Opcionalmente, una llamada de clasificación barata y directa puede juzgar si una
conversación es lo bastante simple como para *bajar* a algo más barato, antes de
que empiece el turno de verdad. Sin agente adicional que configurar, solo dos
campos:

- `triage_model`: una conexión de modelo que clasifica el mensaje entrante con un
  prompt fijo e integrado (no una persona que escribas tú). Pepe solo busca la
  palabra "SIMPLE" en su respuesta.
- `simple_model`: la conexión de modelo a la que bajar (y mantener, durante el
  resto de la sesión) en cuanto el veredicto de triaje sea simple.

```bash
pepe agent add assistant \
  --model modelo-fuerte-y-caro \
  --triage-model modelo-barato-y-rapido \
  --simple-model modelo-de-uso-diario \
  --prompt "..." \
  --tools bash,read_file,web_search
```

El triaje se ejecuta una sola vez, en el primer turno de una sesión, nunca de nuevo
para esa misma sesión. En cuanto una conversación se juzga simple, se queda en
el modelo más barato durante el resto de la conversación (el mismo mecanismo que
usa el comando `/model` para cambiar el modelo de una sesión, solo que activado
automáticamente en vez de a mano). Un veredicto complejo no cambia nada: la
sesión se ejecuta con el modelo propio del agente exactamente igual que si
`triage_model` no estuviera definido.

El triaje es una optimización de mejor esfuerzo, nunca una dependencia. Si el
modelo de triaje no existe, no es alcanzable, o simplemente tarda demasiado (con
un tope de pocos segundos), el turno sigue adelante con el modelo propio del
agente, en silencio. Una caída del triaje nunca bloquea ni rompe una
conversación. `simple_model` también tiene que estar definido para que el
triaje se ejecute; si no, no habría a dónde bajar.

Cada veredicto aparece como su propio paso en el Trace de ese turno (el replay
de cada ejecución en el panel), junto a cualquier hook de privacidad que se
haya ejecutado sobre el mensaje, así puedes ver exactamente por qué una
sesión terminó en un modelo y no en otro.

## El agente predeterminado

Un agente por alcance puede ser el predeterminado. El predeterminado es el que se
ejecuta cuando no nombras a un agente:

```bash
pepe run "resume este repositorio"
```

El primer agente que creas en el proyecto por defecto se convierte
automáticamente en el predeterminado. Cámbialo cuando quieras:

```bash
pepe agent default assistant
```

## El agente propietario

El primerísimo agente creado durante la configuración es el agente propio del
propietario, y nace plenamente capaz. Recibe todas las herramientas, es
superadministrador sobre todos los demás agentes (`can_manage` es `["*"]`) y todas
sus llamadas de herramientas están aprobadas de antemano (`auto_approve` es `["*"]`)
para que nunca se detenga a preguntar. Esto es lo que te permite hacer trabajo real
por chat desde el primer minuto, incluida la creación y configuración de todos los
agentes posteriores. Los agentes que añades después son más restringidos por
defecto: tú eliges sus herramientas, solo se administran a sí mismos y sus llamadas
de riesgo pasan por la barrera de permisos.

## Dejar que los agentes se hablen entre sí

`can_message` es una lista de rutas permitidas dirigida. Si el agente A incluye al
agente B, entonces A puede enviar a B un mensaje con la herramienta `send_to_agent`.
Lo contrario no se da por hecho. Añade una ruta desde la CLI:

```bash
pepe agent route triage assistant
```

Ahora `triage` puede pasar trabajo a `assistant`. Elimina la ruta con `--remove`.
Las rutas nunca cruzan la frontera de un proyecto; la CLI rechaza `A -> B` cuando
los dos están en proyectos distintos.

### Hazlo por chat

Un agente con la herramienta `set_route` puede cambiar el enrutamiento por
conversación. `from` toma por defecto el agente que llama:

```text
Allow yourself to message the billing agent.
```

El agente llama a `set_route` con `action: "allow"` y `to: "billing"`. El
enrutamiento es dirigido, así que esto no permite que `billing` responda con
mensajes. Como edita la configuración, `set_route` pasa por la barrera de permisos y
tú autorizas el cambio.

## Administrar agentes

`can_manage` controla qué agentes puede administrar un agente (crear, editar,
reconfigurar, entrenar) mediante la herramienta `manage_agent`. Está cerrado por
defecto y su significado es preciso:

- Sin definir (`null`): el agente solo puede administrarse a sí mismo.
- Vacío (`[]`, definido con `--can-manage none`): no puede administrar a nadie, ni
  siquiera a sí mismo. Un hijo bloqueado, por ejemplo un agente de cara al cliente
  que no debe alterarse a sí mismo.
- Una lista de nombres: exactamente esos agentes, y ningún otro. Incluye su propio
  nombre para dejar que también se administre a sí mismo.
- `["*"]` (definido con `--can-manage "*"`): todos los agentes. Un superadministrador
  explícito.

Concede autoridad de gestión directamente:

```bash
pepe agent manage supervisor "*"
```

### Hazlo por chat

Un agente administrador usa `manage_agent` para dar forma a los agentes de su
alcance. Sus acciones son `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` y `remember` (añade un hecho duradero a la memoria del
destino). Por ejemplo:

```text
Dale al agente de soporte la herramienta send_file y registra en su memoria que
los reembolsos superiores a 200 necesitan una persona.
```

El agente llama a `manage_agent` con `action: "add_tool"` y luego con
`action: "remember"`. Cada una de estas acciones pasa por la barrera de permisos: el
agente propone el cambio, tú lo autorizas y solo entonces se aplica. Un agente
también puede renombrarse a sí mismo con la herramienta aparte `rename_agent` ("De
ahora en adelante, llámate scout"), que mueve su directorio de espacio de trabajo y
surte efecto en el siguiente mensaje.

## Agentes multi-cliente con proyectos

Cada agente vive en un proyecto. En una instalación nueva ese es el único **proyecto
por defecto**, al que recurre cada comando cuando omites `--project`, exactamente como
siempre ha funcionado una instalación de un solo cliente. Añade un segundo proyecto
para aislar a un cliente: sus agentes, espacios de trabajo, espacio compartido,
conexiones de modelo y enrutamiento quedan aislados de cualquier otro proyecto.

La identidad real de un agente es su handle. En el proyecto por defecto el handle es
solo el nombre a secas (`assistant`). Dentro de otro proyecto se cualifica como
`proyecto/nombre` (`acme/assistant`), así que el mismo nombre a secas se puede
reutilizar entre proyectos sin colisión.

Crea un proyecto y luego añade agentes dentro de él con `--project`:

```bash
pepe project add acme --description "Acme Corp"

pepe agent add support \
  --project acme \
  --model openrouter \
  --prompt "Eres el agente de soporte de Acme." \
  --tools read_file,web_search
```

Añade `--project acme` a cualquier comando de agente para actuar dentro de ese
alcance. Los nombres de pares a secas en `--can-message` y `--can-manage` se
resuelven dentro del propio proyecto del agente, así que las rutas nunca cruzan por
accidente la frontera de un cliente. Cada proyecto puede fijar su propio modelo
predeterminado y su agente predeterminado, o compartir el proveedor global del
operador. Un agente de un proyecto que no es el por defecto nunca se promueve a
predeterminado global solo por ser el primero creado dentro de su proyecto.

Tanto los proyectos como los agentes llevan un id interno estable, y cada vínculo
(enrutamiento, autoridad de gestión, agente predeterminado, cron, bots, tokens) se
registra contra ese id, no contra el nombre. Renombrar un proyecto o un agente cambia
su etiqueta y mueve su directorio; nada queda colgando.

## Gestionar agentes desde la CLI

```bash
# Crea un agente. Omite --tools para conceder todas las herramientas; pasa --tools "" para ninguna.
pepe agent add NAME \
  --model MODEL \
  --prompt "..." \
  --tools t1,t2 \
  [--description "..."] \
  [--can-message b,c] \
  [--can-manage x,y | "*" | none] \
  [--hooks pii_redact] \
  [--max-iterations 12] \
  [--temperature 0.7] \
  [--triage-model MODEL] \
  [--simple-model MODEL] \
  [--default] \
  [--project PROJECT]

# Lista agentes en un proyecto, o todos los agentes.
pepe agent list [--project PROJECT | --all]

# Directed messaging: let FROM message TO.
pepe agent route FROM TO [--remove] [--project PROJECT]

# Management authority: let ADMIN administer TARGET (or "*" for all).
pepe agent manage ADMIN TARGET [--remove] [--project PROJECT]

# Rename an agent and move its workspace directory.
pepe agent rename OLD NEW

# Delete an agent.
pepe agent remove NAME [--project PROJECT]

# Set the default agent for a project.
pepe agent default NAME [--project PROJECT]
```

## Ejecutar un agente

Al mismo agente se llega de cuatro formas.

**De una sola vez desde la CLI.** Sin sesión, transmite a stdout.

```bash
pepe run assistant "your prompt here"
```

**Consola interactiva.** Mantiene la conversación, así que el contexto se traslada
entre turnos. Reanuda o separa sesiones de consola con `--session KEY`.

```bash
pepe tui assistant
```

**Por HTTP y WebSocket.** Arranca el servidor y luego llama a la API compatible con
OpenAI o abre un WebSocket de transmisión. El campo `model` de la petición nombra al
agente.

```bash
pepe serve --port 4000
```

```http
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "assistant",
  "messages": [{ "role": "user", "content": "your prompt here" }]
}
```

El WebSocket se sirve en `ws://localhost:4000/socket/websocket`, y la comprobación
de estado en `GET /health`.

**Por un canal de mensajería.** Vincula un agente a una conexión de Telegram,
WhatsApp, Slack, Discord, Microsoft Teams o Google Chat, o a un webhook entrante
genérico, y responde allí con el mismo ciclo y las mismas herramientas.
