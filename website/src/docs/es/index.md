---
title: Introducción
description: Pepe corre agentes de IA en tu propia máquina. Describe quiénes son, conecta cualquier modelo compatible con OpenAI y déjalos hacer trabajo de verdad con herramientas, sin servidor de base de datos ni ataduras a un proveedor.
---

## Qué es Pepe

Pepe corre **agentes** de IA en tu propia máquina o servidor. Describes un
agente una sola vez (nombre, instrucciones, qué herramientas puede usar y
con qué modelo piensa) y de ahí en más Pepe se encarga de todo: cuando llega
una petición, el agente avanza paso a paso, apoyándose en sus herramientas,
hasta llegar a una respuesta de verdad.

Los agentes están pensados para durar: conversaciones, canales, tareas en
segundo plano, no peticiones sueltas de una sola vez. Pepe está construido
en Elixir/OTP, una tecnología diseñada justamente para ese tipo de carga,
así que un servidor modesto sostiene a todo un equipo de agentes corriendo
en paralelo sin exigir demasiada memoria ni CPU.

Ese bucle interno es la esencia de todo el proyecto. Una llamada de chat
cualquiera devuelve texto; un agente, en cambio, puede realmente hacer
cosas: leer un archivo, correr un comando, buscar en la web, llamar a tu
API, razonar sobre lo que encontró y seguir adelante. Pepe entrega ese
bucle ya resuelto, como un runtime terminado, en vez de algo que tienes que
armar a mano cada vez que empiezas un proyecto.

```bash
pepe run "lee package.json y dime qué dependencias están desactualizadas"
```

Defines el comportamiento una única vez, y ese mismo agente queda accesible
de cuatro formas distintas: desde la terminal, mediante una API HTTP
compatible con OpenAI, por un WebSocket con streaming, y desde canales de
mensajería como Telegram y WhatsApp. También hay un panel web para navegar
y chatear directamente desde el navegador. Así atiendes cada caso de uso
justo donde ya ocurre, sin necesidad de crear un agente distinto por cada
canal.

## El bucle de llamadas a herramientas

Este es el ciclo que Pepe repite en cada turno:

1. Envía al modelo la conversación completa, junto con las definiciones de
   herramientas del agente.
2. Si el modelo devuelve llamadas a herramientas, las ejecuta una por una y
   recoge cada salida.
3. Agrega a la conversación el mensaje del asistente junto con los
   resultados de esas herramientas.
4. Vuelve al paso 1, y se detiene cuando el modelo entrega una respuesta
   simple, o cuando el agente choca con su límite de seguridad
   `max_iterations`.

Durante todo el proceso, Pepe va anunciando cada paso, de modo que
cualquier superficie pueda mostrar el avance en tiempo real: la respuesta
según va llegando en streaming (`assistant_delta`), cada llamada a
herramienta junto con su resultado (`tool_call`, `tool_result`), la
respuesta final (`done`) y los errores (`error`).

Las herramientas arriesgadas, cualquiera que ejecute un comando o escriba
un archivo, se pueden configurar para que pidan tu autorización antes de
correr. Si la niegas, la herramienta simplemente no se ejecuta: el modelo
recibe una nota breve de "denegado" (y se dispara un evento
`tool_denied`), así que ningún agente actúa en silencio sobre tu máquina
sin tu consentimiento.

<div class="note"><strong>Herramientas integradas.</strong> A cualquier agente se le pueden asignar herramientas como <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code> y <code>web_search</code>. Tú decides cuáles recibe cada uno al crearlo, así que un bot de soporte y un agente de programación pueden terminar con capacidades muy distintas entre sí.</div>

## Las cinco superficies

Construyes un agente una sola vez, y Pepe lo expone después por la
superficie que mejor encaje con cada tarea. La configuración y la gestión,
a su vez, se hacen de tres maneras posibles: con la CLI `pepe`, desde el
panel web, o por chat, hablando en lenguaje natural con un agente que tenga
la herramienta de gestión adecuada.

### CLI

El comando `pepe` es la vía tanto para configurar todo como para correr
agentes desde una terminal. Las ejecuciones puntuales transmiten su
respuesta directo a la salida estándar, y `pepe chat` abre una sesión
interactiva que recuerda la conversación.

```bash
pepe run assistant "resume el git log de la última semana"
pepe chat assistant
```

### Panel web

Levanta el servidor y abre el panel en el navegador para chatear con un
agente, revisar sesiones anteriores, y gestionar agentes, conexiones a
modelos, canales, tareas programadas, uso y traces, todo desde una
interfaz visual. En localhost queda abierto por defecto; si vas a
exponerlo, puedes protegerlo detrás de una contraseña de operador.

```bash
pepe serve --port 4000
# luego abre http://localhost:4000
```

### API HTTP compatible con OpenAI

Al levantar el servidor, Pepe habla el protocolo Chat Completions de
OpenAI, así que cualquier SDK de OpenAI, LangChain o incluso un `curl`
sencillo puede comunicarse con él sin necesitar ningún adaptador. Expone
`POST /v1/chat/completions` y `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "¿Qué archivos hay en este proyecto?"}]
  }'
```

Apunta cualquier cliente de OpenAI que ya tengas hacia
`http://localhost:4000/v1`, y el nombre del modelo pasa a ser directamente
el nombre de tu agente. Consulta [la página de la API HTTP](../api/) para
todo lo relacionado con streaming, eventos de herramientas y
autenticación.

### WebSocket

Si necesitas conversaciones en vivo, token a token, dentro de una app web o
móvil, conéctate por WebSocket y suscríbete al tema de tu agente
(`agent:<name>`). Ahí recibes el texto del asistente a medida que se
transmite, más un evento por cada llamada a herramienta y su resultado.
Los detalles, junto con un ejemplo de cliente, están en [la página de la
API](../api/).

### Canales de mensajería

Pon al mismo agente frente a usuarios reales, justo en las plataformas
donde ya están. Pepe trae gateways listos para Telegram, WhatsApp, Slack,
Discord, Microsoft Teams y Google Chat, además de un webhook de entrada
genérico para cualquier otra cosa. Cada canal queda vinculado a un agente
y mantiene su propia memoria de conversación por usuario. Consulta [la
página de canales](../channels/).

## Definir un agente

Un agente no es más que un nombre, un prompt de sistema, una lista de
herramientas y un modelo. Créalo desde la CLI:

```bash
pepe agent add assistant \
  --prompt "Eres Pepe, un agente de programación útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

También puedes hacer esto mismo desde el panel, en la página **Agents**,
que trae un formulario para la persona, el modelo y la selección de
herramientas.

### Hazlo por chat

Un agente que tenga la herramienta `manage_agent` puede crear y moldear
otros agentes directamente desde una conversación. Basta con mandarle un
mensaje sencillo:

> Tú: Crea un nuevo agente llamado "researcher" cuyo trabajo sea escarbar en la
> documentación y resumir hallazgos, y dale web_search y fetch_url.

El agente recurre a `manage_agent` para hacer `create` del nuevo agente,
definir su persona y sumarle cada herramienta. `manage_agent` viene
deliberadamente restringido: solo puede tocar los agentes que se le
autorizaron de forma explícita, tiene instrucciones de confirmar los
cambios contigo antes de aplicarlos y, como es una herramienta arriesgada,
cada llamada sigue pasando por tu aprobación antes de escribir nada. Así,
ves el cambio propuesto y lo apruebas antes de que entre en vigor.

## Conectar un modelo

Pepe nunca trae un modelo ni una clave incluidos. Tú lo apuntas hacia
cualquier proveedor compatible con OpenAI mediante una conexión de modelo:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

La página **Models** del panel hace exactamente lo mismo con un
formulario, y de paso te deja probar la conexión antes de guardarla.
Fíjate en `${OPENROUTER_API_KEY}`: los secretos se guardan como
referencias a variables de entorno, y se expanden solo al momento de
leerlos, así que tus claves jamás quedan escritas en disco en texto plano.

## Añadir un canal

Vincula un agente a un canal de mensajería para que la gente pueda
hablarle justo donde ya está. Desde el panel, la página **Channels** te va
guiando para conectar un bot y elegir con qué agente conversa. A partir de
ahí, el canal mantiene una memoria de conversación separada por cada
usuario.

### Hazlo por chat

Un agente con la herramienta `manage_channel` puede levantar un bot de
Telegram directamente desde una conversación:

> Tú: Añade un bot de Telegram llamado "support-bot" que hable con el agente de
> soporte. El token está en la variable de entorno SUPPORT_BOT_TOKEN.

El agente usa `manage_channel` para agregar el bot y vincularlo al agente
indicado. Esta capacidad también viene deliberadamente restringida: solo
puede tocar bots con nombre propio (nunca el predeterminado, que está
protegido), tiene instrucciones de confirmar los detalles contigo primero
y, al ser una herramienta arriesgada, la llamada pasa por la barrera de
permisos. Y lo más importante: tú le das el **nombre** de la variable de
entorno que guarda el token, nunca el token en sí, así que el secreto
jamás pasa por el chat ni por el modelo. Una vez aplicado el cambio, el bot
arranca en vivo, sin necesidad de reiniciar nada.

## Decisiones de diseño que lo mantienen simple

### Autoalojado, tus claves, tus datos

Pepe nunca viene con un modelo ni una clave de API incluidos. Lo corres en
tu propia máquina o servidor, y lo apuntas hacia el proveedor que
prefieras. Nada de una conversación sale de tu infraestructura, salvo las
llamadas que tú mismo configuraste hacia el endpoint del modelo elegido.

### Independiente del modelo

Como se llega a cualquier proveedor por el mismo protocolo Chat Completions
de OpenAI, cambiar de modelo es solo un cambio de configuración, no de
código. OpenAI, OpenRouter, Together, Groq, DeepSeek, Mistral y servidores
locales como Ollama, LM Studio o vLLM funcionan todos de la misma manera.
Una conexión de modelo incluso puede listar modelos de respaldo, de forma
que un fallo pasajero (un límite de tasa, un error del servidor, un corte
de red) en un proveedor pasa discretamente al siguiente, mientras que una
clave inválida o una petición mal formada falla de inmediato en vez de
reintentar sin sentido.

### Sin servidor de base de datos

Toda la configuración (conexiones a modelos, agentes, canales,
programaciones) vive en un único archivo JSON, `~/.pepe/config.json`,
fácil de leer, editar y respaldar. No hay nada que instalar junto a Pepe ni
nada que migrar. Los secretos se escriben como referencias `${ENV_VAR}` y
se expanden solo al leerlos, así que tus claves nunca terminan escritas en
disco en texto plano.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-5-chat"
    }
  }
}
```

### Conversaciones aisladas

Cada conversación corre por su cuenta, completamente separada de las
demás. Si una falla, el resto ni se entera: un solo turno defectuoso jamás
puede arrastrar a tus otros agentes o conversaciones.

### Multi-cliente cuando lo necesitas

El trabajo se puede acotar a un **proyecto**, para aislar agentes,
canales, modelos y uso por cliente. Si nunca activas esto, todo termina
viviendo en el **proyecto por defecto**, al que recurre cualquier comando
cuando no se especifica otro, y puedes olvidarte de los proyectos por
completo.

## A dónde ir después

- [Inicio rápido](../quickstart/): instala Pepe, conecta un modelo y ten tu
  primer agente corriendo en pocos minutos.
- [Agentes y herramientas](../agents/): de qué está hecho un agente y cómo
  decide cuándo usar sus herramientas.
- [API HTTP](../api/): maneja Pepe desde cualquier cliente compatible con
  OpenAI, tanto en modo petición/respuesta como en streaming.
- [Canales](../channels/): pon a un agente en Telegram, WhatsApp, Slack y
  más.
- [Tareas programadas](../scheduled/): haz correr agentes con una
  programación recurrente.
- [Seguridad y permisos](../security/): la barrera de permisos, el
  sandboxing, y cómo mantener a un agente dentro de límites seguros.
