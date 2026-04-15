---
title: Introducción
description: Pepe es un runtime de agentes de IA autoalojado e independiente del modelo. Define agentes, conecta cualquier modelo compatible con OpenAI y ejecuta un verdadero bucle de llamadas a herramientas, sin base de datos y sin ataduras a un proveedor.
---

## Qué es Pepe

Pepe es un runtime de agentes de IA autoalojado, construido en Elixir. Tú defines
un **agente** (un nombre, un prompt de sistema, un conjunto de herramientas y una
conexión a un modelo), y Pepe lo ejecuta: envía la conversación al modelo,
ejecuta cualquier herramienta que el modelo pida, le devuelve los resultados y
repite hasta que el modelo produce una respuesta final.

Elixir/OTP importa porque los agentes son conversaciones largas, canales y tareas
en segundo plano, no solo una petición HTTP. Pepe puede mantener muchas sesiones
supervisadas con poco overhead, lo que ayuda a alojar un equipo de agentes sin
inflar la memoria ni la CPU del servidor.

Ese bucle interno es la razón de ser de todo. Una simple llamada de chat devuelve
texto. Un agente puede realmente hacer cosas: leer un archivo, ejecutar un
comando, buscar en la web, llamar a tu API, y luego razonar sobre lo que encontró
y continuar. Pepe te entrega ese bucle como un runtime terminado, en lugar de
algo que tienes que armar a mano en cada proyecto.

```bash
pepe run "lee package.json y dime qué dependencias están desactualizadas"
```

Defines el comportamiento una vez, y el mismo agente queda accesible de cuatro
formas: desde la terminal, mediante una API HTTP compatible con OpenAI, a través
de un WebSocket con streaming, y desde canales de mensajería como Telegram y
WhatsApp. También hay un panel web para navegar y conversar desde el navegador.
Atiende cada caso de uso allí donde ya vive, sin crear un agente separado para
cada canal.

## El bucle de llamadas a herramientas

Este es el ciclo que Pepe ejecuta en cada turno:

1. Envía la conversación, junto con las definiciones de herramientas del agente,
   al modelo.
2. Si el modelo devuelve llamadas a herramientas, ejecuta cada una y recoge su
   salida.
3. Añade el mensaje del asistente y los resultados de las herramientas a la
   conversación.
4. Vuelve al paso 1. Se detiene cuando el modelo devuelve una respuesta simple,
   o cuando el agente alcanza su límite de seguridad `max_iterations`.

Por el camino, el runtime emite eventos de ciclo de vida para que cualquier
superficie pueda mostrar el progreso en tiempo real: fragmentos de texto en
streaming (`assistant_delta`), un turno completo del asistente (`assistant`),
cada llamada a herramienta (`tool_call`), cada resultado de herramienta
(`tool_result`), la respuesta final (`done`) y los errores (`error`). Las
superficies con streaming muestran los tokens a medida que llegan.

Las herramientas arriesgadas (cualquiera que ejecute un comando o escriba un
archivo) pueden pasar por una barrera de permisos que pide al usuario aprobar
antes de que la herramienta se ejecute. Si el usuario se niega, el runtime emite
un evento `tool_denied` y le entrega al modelo un breve mensaje de "denegado" en
lugar de ejecutar la herramienta, de modo que un agente nunca actúa en silencio
sobre tu máquina sin tu consentimiento.

<div class="note"><strong>Herramientas integradas.</strong> A cada agente se le pueden dar herramientas como <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code> y <code>web_search</code>. Eliges cuáles recibe cada agente al crearlo, así un bot de soporte y un agente de programación pueden tener capacidades muy distintas.</div>

## Las cuatro superficies

Construyes un agente una vez. Pepe lo expone luego a través de la superficie que
mejor encaje con la tarea. La configuración y la gestión, por su parte, ocurren
de tres maneras: la CLI `pepe`, el panel web y por chat (hablando en lenguaje
natural con un agente que posee la herramienta de gestión adecuada).

### CLI

El comando `pepe` es la forma de configurar las cosas y de ejecutar agentes desde
una terminal. Las ejecuciónes puntuales transmiten su respuesta directamente a la
salida estándar, y `pepe chat` abre una sesión interactiva que recuerda la
conversación.

```bash
pepe run assistant "resume el git log de la última semana"
pepe chat assistant
```

### Panel web

Ejecuta el servidor y abre el panel en un navegador para conversar con un agente,
navegar por sesiones anteriores y gestionar agentes, conexiones a modelos,
canales, tareas programadas, uso y trazas desde una interfaz de apuntar y hacer
clic. En localhost está abierto por defecto; puedes protegerlo tras una
contraseña de operador cuando lo expongas.

```bash
pepe serve --port 4000
# luego abre http://localhost:4000
```

### API HTTP compatible con OpenAI

Arranca el servidor y Pepe habla el protocolo Chat Completions de OpenAI, así que
cualquier SDK de OpenAI, LangChain o un simple `curl` pueden comúnicarse con él
sin adaptador. Sirve `POST /v1/chat/completions` y `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "qué archivos hay en este proyecto?"}]
  }'
```

Apunta un cliente de OpenAI existente a `http://localhost:4000/v1` y el nombre del
modelo pasa a ser el nombre de tu agente. Consulta [la página de la API
HTTP](./api/) para streaming, eventos de herramientas y autenticación.

### WebSocket

Para conversaciones en vivo, token a token, en una app web o móvil, conéctate por
un WebSocket y suscríbete al tema de tu agente (`agent:<name>`). Recibes el texto
del asistente a medida que se transmite, más eventos por cada llamada y resultado
de herramienta. Los detalles y un ejemplo de cliente están en [la página de la
API](./api/).

### Canales de mensajería

Pon el mismo agente frente a usuarios reales en las plataformas que ya usan. Pepe
incluye pasarelas para Telegram, WhatsApp, Slack, Discord, Microsoft Teams y
Google Chat, además de un webhook de entrada genérico para cualquier otra cosa.
Cada canal se vincula a un agente y mantiene su propia memoria de conversación por
usuario. Consulta [la página de canales](./channels/).

## Definir un agente

Un agente no es más que un nombre, un prompt de sistema, una lista de
herramientas y un modelo. Crea uno desde la CLI:

```bash
pepe agent add assistant \
  --prompt "Eres Pepe, un agente de programación útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

También puedes hacerlo en el panel web, en la página **Agents**, que incluye un
formulario para la persona, el modelo y la selección de herramientas.

### Hazlo por chat

Un agente que posee la herramienta `manage_agent` puede crear y dar forma a otros
agentes directamente desde una conversación. Envíale un mensaje sencillo:

> Tú: Crea un nuevo agente llamado "researcher" cuyo trabajo sea escarbar en la
> documentación y resumir hallazgos, y dale web_search y fetch_url.

El agente usa `manage_agent` para `create` el nuevo agente, definir su persona y
añadir cada herramienta. `manage_agent` es una capacidad protegida: el agente
solo puede tocar los agentes de su propia lista de permitidos, tiene la
instrucción de confirmar los cambios contigo primero, y como es una herramienta
arriesgada, cada llamada aún pasa por la barrera de permisos antes de que se
escriba nada. Así ves el cambio propuesto y lo apruebas antes de que surta efecto.

## Conectar un modelo

Pepe nunca incluye un modelo ni una clave. Lo apuntas a cualquier proveedor
compatible con OpenAI mediante una conexión a un modelo:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model anthropic/claude-3.5-sonnet \
  --default
```

La página **Models** del panel hace lo mismo con un formulario, y puede probar una
conexión antes de guardarla. Fíjate en `${OPENROUTER_API_KEY}`: los secretos se
guardan como referencias a variables de entorno y se expanden solo al leerse, así
que tus claves nunca se escriben de vuelta en disco en texto plano.

## Añadir un canal

Vincula un agente a un canal de mensajería para que la gente pueda hablarle donde
ya está. Desde el panel, la página **Channels** te guía para conectar un bot y
elegir con qué agente conversa. El canal mantiene entonces una memoria de
conversación separada por usuario.

### Hazlo por chat

Un agente que posee la herramienta `manage_channel` puede levantar un bot de
Telegram desde una conversación:

> Tú: Añade un bot de Telegram llamado "support-bot" que hable con el agente de
> soporte. El token está en la variable de entorno SUPPORT_BOT_TOKEN.

El agente usa `manage_channel` para añadir el bot y vincularlo al agente
indicado. Esta capacidad está deliberadamente protegida: solo toca bots con
nombre (nunca el predeterminado protegido), tiene la instrucción de confirmar los
detalles contigo primero, y es una herramienta arriesgada, así que la llamada
pasa por la barrera de permisos. Y algo crucial: le das el **nombre** de una
variable de entorno que contiene el token, nunca el token en sí, de modo que el
secreto nunca pasa por el chat ni por el modelo. Tras el cambio, el bot en marcha
arranca en vivo, sin reiniciar.

## Decisiones de arquitectura que simplifican el uso

### Autoalojado, tus claves, tus datos

Pepe nunca incluye un modelo ni una clave de API. Lo ejecutas en tu propia máquina
o servidor, y lo apuntas al proveedor que quieras. Nada de una conversación sale
de tu infraestructura, salvo las llamadas que configures hacia el endpoint del
modelo que elijas.

### Independiente del modelo

Como cada proveedor se alcanza con el mismo protocolo Chat Completions de OpenAI,
cambiar de modelo es un cambio de configuración, no de código. OpenAI, OpenRouter,
Together, Groq, DeepSeek, Mistral y servidores locales como Ollama, LM Studio y
vLLM funcionan todos igual. Una conexión a un modelo puede incluso listar modelos
de reserva, así que un fallo transitorio (un límite de tasa, un error del
servidor, un corte de red) en un proveedor pasa discretamente al siguiente,
mientras que una clave errónea o una petición mal formada falla de inmediato en
lugar de reintentar sin sentido.

### Sin base de datos

Toda la configuración (conexiones a modelos, agentes, canales, programaciones)
vive en un único archivo JSON en `~/.pepe/config.json`. No hay nada que
aprovisionar ni nada que migrar. Los secretos se escriben como referencias
`${ENV_VAR}` y se expanden solo al leerse, así que tus claves nunca se escriben de
vuelta en disco en texto plano.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "anthropic/claude-3.5-sonnet"
    }
  }
}
```

### Conversaciones aisladas

Cada conversación se ejecuta como su propio proceso ligero y supervisado,
identificado por un id de sesión. Muchas corren en paralelo, y una caída en una
nunca toca a otra, así que un solo turno defectuoso no puede tumbar al resto de
tus agentes.

### Multiempresa cuando la necesitas

El trabajo puede acotarse a una **empresa**, aislando agentes, canales, modelos y
uso por empresa. Si nunca lo activas, todo vive en el ámbito predeterminado,
llamado **Principal**, y puedes ignorar las empresas por completo.

## A dónde ir después

- [Inicio rápido](./quickstart/). Instala Pepe, conecta un modelo y ejecuta tu
  primer agente en unos minutos.
- [Agentes y herramientas](./agents/). De qué se compone un agente y cómo decide
  usar herramientas.
- [API HTTP](./api/). Maneja Pepe desde cualquier cliente compatible con OpenAI,
  tanto por la vía de petición/respuesta como por la de streaming.
- [Canales](./channels/). Pon un agente en Telegram, WhatsApp, Slack y más.
- [Tareas programadas](./scheduled/). Ejecuta agentes con una programación
  recurrente.
- [Seguridad y permisos](./security/). La barrera de permisos, el aislamiento, y
  cómo mantener a un agente dentro de límites seguros.
