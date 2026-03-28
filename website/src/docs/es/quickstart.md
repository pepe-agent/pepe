---
title: Inicio rápido
description: Instala Pepe, conecta un modelo, define un agente y habla con él, y luego expón ese mismo agente por HTTP, un WebSocket y un canal de chat, en pocos minutos.
---

Pepe es un runtime de agentes de IA autoalojado. Tú defines un agente (un nombre,
un prompt de sistema, un conjunto de herramientas y una conexión a un modelo) y
Pepe ejecuta por ti el bucle de llamadas a herramientas. Llama al modelo, ejecuta
las herramientas que el modelo pidió, le devuelve los resultados y repite hasta que
el modelo produce una respuesta final.

Pepe habla con cualquier proveedor compatible con OpenAI mediante el protocolo de
Chat Completions, así que OpenAI, OpenRouter, Together, Groq, DeepSeek, Mistral, un
Ollama local y cualquier otra cosa que hable la misma API funcionan sin cambiar una
línea de código. Pepe está construido en Elixir, pero no necesitas saber Elixir
para usarlo. Esta página te lleva de cero a un agente que conversa, y luego pone
ese mismo agente detrás de una API HTTP, un WebSocket y un canal de chat.

Hay tres formas de manejar Pepe, y casi todo lo que sigue se puede hacer con
cualquiera de ellas:

1. La herramienta de línea de comandos `pepe`.
2. El panel web que viene con el servidor.
3. Por chat, hablando en lenguaje natural con un agente que tiene la herramienta de
   gestión correspondiente.

Cuando un paso se puede hacer por chat, encontrarás una breve subsección "Hazlo por
chat" que muestra el mensaje que enviarías y lo que hace el agente.

## 1. Instalación

Un solo comando instala el binario `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Comprueba que quedó instalado:

```bash
pepe help
```

Todo lo que Pepe sabe vive en un único archivo JSON en `~/.pepe/config.json`. No
hay ninguna base de datos que ejecutar. Puedes editar ese archivo a mano más tarde,
pero los comandos de abajo lo escriben por ti.

## 2. Configuración guiada (el camino rápido)

`pepe setup` te acompaña en todo el proceso. Elige un proveedor, inicia sesión o
toma una clave de API, elige un modelo, crea tu primer agente y ofrece conectar un
canal de chat y el panel.

```bash
pepe setup
```

Si prefieres hacer cada paso de forma explícita, sáltate setup y sigue los pasos 3
al 6. Los dos caminos escriben la misma configuración, así que puedes mezclarlos
libremente.

<div class="note"><strong>Los secretos se quedan fuera del archivo.</strong> Cuando Pepe te pide una clave de API acepta una referencia <code>${ENV_VAR}</code>, por ejemplo <code>${OPENROUTER_API_KEY}</code>. Lo que se escribe en <code>~/.pepe/config.json</code> es la referencia. El valor real se lee de tu entorno en tiempo de ejecución y nunca se guarda expandido.</div>

## 3. Conectar un modelo

Apunta Pepe a cualquier endpoint compatible con OpenAI. Guarda la clave como una
referencia de entorno para que el secreto en crudo nunca acabe en el archivo de
configuración.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5 \
  --default
```

Verás una confirmación como esta:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5)
```

Algunas cosas que conviene saber:

- Ejecuta `pepe model add NAME` sin `--base-url` para obtener un selector guiado.
  Elige un proveedor del catálogo, elige cómo autenticarte y luego elige un modelo
  de la lista en vivo del proveedor.
- `pepe model providers` lista los proveedores que Pepe conoce de fábrica.
- `pepe model list` muestra cada conexión guardada y marca la predeterminada.
- `pepe model test` envía una petición real mínima para confirmar que la conexión
  funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5)...
✓ openrouter works - reply: pong
```

El panel también puede hacer todo esto, en su pestaña Modelos, si prefieres un
formulario a la línea de comandos.

## 4. Añadir un agente

Un agente es un nombre, un prompt de sistema y una lista de herramientas permitidas
que puede usar. Si dejas fuera `--tools`, el agente recibe todas las herramientas
integradas. Pasa una lista separada por comas para acotarlas. Añade `--model` para
vincular una conexión de modelo concreta, u omítelo para usar la predeterminada.

```bash
pepe agent add assistant \
  --prompt "You are a helpful, concise assistant." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

```bash
✓ agent assistant saved (tools: bash, read_file, write_file, edit_file, list_dir, fetch_url, web_search)
```

Las herramientas integradas cubren lo esencial: comandos de shell (`bash`,
`run_script`), archivos (`read_file`, `write_file`, `edit_file`, `move_file`,
`list_dir`) y la web (`fetch_url`, `web_search`), más un conjunto de herramientas
de gestión que se ven más adelante en esta página. Consulta la lista completa
cuando quieras con:

```bash
pepe tools
```

<div class="note"><strong>Las herramientas son cómo concedes capacidad.</strong> Un agente solo puede hacer lo que sus herramientas permiten. Dale a un agente de soporte <code>fetch_url</code> y <code>web_search</code> pero no <code>bash</code>, y sencillamente no podrá ejecutar comandos de shell. Empieza con poco y añade herramientas a medida que confíes en el agente.</div>

El panel tiene una pestaña Agentes que hace lo mismo con un formulario.

### Hazlo por chat

Un agente que tiene la herramienta `manage_agent` puede crear y dar forma a otros
agentes en la conversación. Dos cosas lo controlan: la herramienta debe estar en la
lista permitida del agente que actúa, y ese agente debe tener autoridad sobre el
objetivo (concedida con `pepe agent manage ADMIN TARGET`, o `"*"` para todos). Como
es una herramienta arriesgada, cada cambio pasa además por la barrera de permisos,
donde lo apruebas antes de que se aplique.

Enviarías:

> Create an agent called researcher that digs up sources and summarizes them.
> Give it web_search and fetch_url, nothing else.

El agente confirma los detalles contigo y luego (tras tu aprobación en el aviso de
permiso) crea el agente `researcher`, define su personalidad y le concede las dos
herramientas. La misma herramienta también puede apuntar un agente a un modelo
distinto, añadir o quitar una sola herramienta y agregar hechos duraderos a la
memoria de un agente.

## 5. Habla con él

Ejecuta un solo prompt. La respuesta se transmite a tu terminal a medida que el
modelo la produce, y cualquier llamada a herramienta se ejecuta por el camino.

```bash
pepe run assistant "what files are in this directory?"
```

Quita el nombre del agente para usar tu agente predeterminado:

```bash
pepe run "summarize the README in three bullets"
```

Para una conversación de ida y vuelta que recuerde el contexto, abre la consola
interactiva. Mantiene la sesión, así que las preguntas de seguimiento se apoyan en
lo anterior.

```bash
pepe chat assistant
```

Cuando una herramienta quiere hacer algo delicado (ejecutar un comando de shell,
escribir un archivo), la consola te pide que lo apruebes antes de ejecutarlo, y te
dice qué hace arriesgada la llamada (por ejemplo "writes to a file" o "accesses the
network").

### Hazlo por chat

Una vez que un agente tiene la herramienta `enable_tool`, puede añadir una
herramienta a su propia lista permitida en la conversación, lo que resulta cómodo
justo después de instalar un plugin. La herramienta ya debe existir como integrada
o como plugin. Como esto cambia la configuración, la llamada está protegida, así
que la apruebas en el aviso de permiso. La nueva herramienta está disponible desde
el siguiente mensaje del agente.

> You just installed the weather plugin. Turn on the get_weather tool for
> yourself.

## 6. Sírvelo en todas partes

Un solo comando pone el mismo agente detrás de una API HTTP compatible con OpenAI,
un WebSocket con streaming y un panel web local.

```bash
pepe serve --port 4000
```

```bash
✓ Pepe serving on http://localhost:4000  (override with PORT=NNNN)

  OpenAI API : POST http://localhost:4000/v1/chat/completions
  Models     : GET  http://localhost:4000/v1/models
  Health     : GET  http://localhost:4000/health
  WebSocket  : ws://localhost:4000/socket/websocket  (topic agent:default)

   dashboard: open on localhost only; remote clients are blocked until you set a password
```

### Llámalo como a OpenAI

El nombre del agente va en el campo `model`. Funciona cualquier SDK de OpenAI o un
simple `curl`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hi"}]}'
```

Como tiene la forma estándar de Chat Completions, las librerías cliente de OpenAI
que ya existen apuntan directamente a él. Aquí está la misma llamada desde un par
de lenguajes.

**Python**

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="unused")

resp = client.chat.completions.create(
    model="assistant",
    messages=[{"role": "user", "content": "hi"}],
)
print(resp.choices[0].message.content)
```

**Node**

```javascript
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://localhost:4000/v1", apiKey: "unused" });

const resp = await client.chat.completions.create({
  model: "assistant",
  messages: [{ role: "user", content: "hi" }],
});
console.log(resp.choices[0].message.content);
```

`GET /v1/models` lista tus agentes, así que un cliente que consulta los modelos
disponibles ve cada agente como uno.

<div class="note"><strong>La API está abierta hasta que la cierres.</strong> Sin tokens configurados, cualquiera que pueda alcanzar el puerto puede llamarla. Crea el primer token con <code>pepe token add</code> y a partir de entonces cada llamada necesita una cabecera <code>Authorization: Bearer</code>. Consulta la página de la API HTTP para los detalles.</div>

### El panel

Al servir también se abre un panel web local donde puedes gestionar agentes,
modelos, canales, tareas programadas, plugins, trazas y consumo sin editar el
archivo de configuración a mano. En localhost está abierto por defecto. Si vinculas
Pepe a una dirección pública, el acceso remoto sigue bloqueado hasta que defines
una contraseña del panel con `pepe dashboard password '<pass>'`.

## 7. Ponlo en un canal de chat

El mismo agente puede responder a personas en una plataforma de mensajería.
Telegram es lo más rápido para probar. Crea un bot con el BotFather de Telegram y
luego entrega el token a Pepe.

```bash
pepe gateway telegram setup
pepe gateway telegram
```

El primer comando guarda el token y vincula el bot a un agente. El segundo arranca
el sondeo. A partir de ahí, cualquiera que escriba al bot está hablando con tu
agente, con las mismas herramientas y memoria que tiene en todas partes.

Más allá de Telegram, Pepe se conecta a WhatsApp, Slack, Discord, Microsoft Teams y
Google Chat mediante el webhook oficial de cada plataforma, más un webhook de
entrada genérico para cualquier otra cosa. Puedes configurarlos de forma
interactiva ejecutando `pepe setup` y eligiendo Canales, o desde el panel.

### Hazlo por chat

Un agente que tiene la herramienta `manage_channel` puede crear y revincular bots
de Telegram desde una conversación. Nunca acepta un token en crudo. Le das el
nombre de una variable de entorno que contiene el token, que Pepe guarda como
`${THE_VAR}` para que el secreto nunca llegue al modelo ni a los registros. La
herramienta es arriesgada, así que el cambio pasa por la barrera de permisos antes
de tener efecto, y el sondeo en ejecución se reconcilia en vivo sin reiniciar.

> Set up a Telegram bot for the sales agent. The token is in the SALES_BOT_TOKEN
> environment variable.

El agente confirma los detalles y luego (tras tu aprobación) crea el bot vinculado
al agente `sales`, guardando su token como `${SALES_BOT_TOKEN}`.

## 8. Automatiza: tareas programadas y vigilancias

Pepe puede ejecutar un agente según un horario, o vigilar una condición y
notificarte una sola vez.

Una tarea programada ejecuta un prompt autocontenido según un horario cron
recurrente.

```bash
pepe cron add
pepe cron list
```

Una vigilancia sondea una comprobación barata y te avisa una única vez cuando se
cumple, y luego se detiene. Sobrevive a los reinicios.

```bash
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
pepe watch list
```

Ambas tienen también su lugar en el panel.

### Hazlo por chat

Un agente con la herramienta `schedule_task` puede crear trabajos recurrentes en la
conversación, y uno con la herramienta `watch` puede configurar notificaciones de
una sola vez. Ambas están controladas: el agente redacta los detalles, los confirma
contigo (qué, cuándo, en qué zona horaria, dónde reportar) y aplica el cambio solo
después de que lo apruebes en el aviso de permiso.

Programar:

> Every weekday at 8am, check our status page and send me a one line summary.

El agente escribe una tarea autocontenida con un horario cron (`0 8 * * 1-5`) y una
zona horaria, la confirma y la guarda cuando la apruebas. Por defecto reporta al
mismo chat.

Vigilar:

> Tell me as soon as example.com comes back up.

El agente crea una vigilancia de una sola vez que sondea el sitio con un
temporizador y te avisa una vez cuando tiene éxito, y luego se detiene.

## Dónde vive tu configuración

Todo lo que hiciste arriba está ahora en `~/.pepe/config.json`: la conexión al
modelo, el agente y cualquier canal. Sin base de datos, sin migraciones. Para mover
una configuración a otra máquina, copia ese archivo y define las mismas variables
de entorno a las que apuntan tus referencias `${VAR}`.

```bash
pepe config
```

Eso imprime la ruta de la configuración y un resumen de lo que está definido.

## Siguientes pasos

- [Agentes y herramientas](./agents/). De qué se compone un agente y cómo decide
  qué herramientas llamar.
- [API HTTP](./api/). Streaming, llamadas a herramientas por la red y cómo cerrar
  la API con tokens.
- [Canales](./channels/). Telegram, WhatsApp, Slack, Discord, Teams y Google Chat
  en profundidad.
- [Tareas programadas](./scheduled/). Ejecuta un agente según un horario
  recurrente, y vigilancias de una sola vez.
- [Seguridad y permisos](./security/). La barrera de aprobación, el aislamiento de
  las herramientas de shell y la contraseña del panel.
- [Plugins](./plugins/). Añade tus propias herramientas y canales sin reconstruir.

<div class="note"><strong>Ejecutas más de un inquilino?</strong> Pepe puede acotar agentes, modelos y canales a una empresa para que los inquilinos se mantengan aislados. Todo lo que configuraste arriba vive en el ámbito predeterminado, llamado Principal. Añade <code>--company NAME</code> a un comando para trabajar dentro de uno concreto.</div>
