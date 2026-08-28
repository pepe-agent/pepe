---
title: Plugins
description: Extiende Pepe con tus propias herramientas y canales instalando plugins con su propia configuración.
---

Un plugin es un archivo que instalas para enseñarle algo nuevo a Pepe, sin recompilar y sin reiniciar: lo sueltas ahí y funciona. La mayoría de los plugins hacen una de dos cosas: agregan una **herramienta** que el modelo puede invocar, o agregan un **proveedor de canal** (una plataforma de mensajería nueva basada en webhook). Esta página cubre esas dos formas en profundidad, con diferencia las más comunes, y más abajo repasa el resto con menos detalle.

Un plugin también puede tomar otras formas: un **canal de conexión persistente** (uno que necesita un websocket de larga duración en vez de un simple webhook, ver [Slots](/docs/slots)), una **ruta HTTP propia** (un callback de redirección OAuth, un endpoint a medida, ver más abajo), un **proveedor de audio en tiempo real** (voz dúplex, ver más abajo), un **adaptador de protocolo de modelo**, un **hook** (reescribe de verdad el contenido de la conversación, encadenable e insertado en línea, ver más abajo), una **policy** (veta una llamada a herramienta, o toda una ejecución, antes de que ocurra; una comprobación que no pudo correr cuenta como un rechazo, así que falla cerrado) o un **observador de ejecución** (mira el bucle desde afuera, de solo lectura, la única forma que no puede afectar nada). Un plugin también puede ocupar un [**slot**](/docs/slots): búsqueda de memoria, búsqueda web, el sandbox donde corre un comando de shell, la compactación de la conversación, o el bucle de razonamiento entero.

Por debajo, todo plugin es Elixir compilado en tiempo de ejecución desde `~/.pepe/plugins/`, y un módulo se empareja con la forma o formas que implementa.

## El behaviour Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Propósito |
|---|---|
| `name/0` | El nombre de función que invoca el modelo, por ejemplo `"read_file"`. Debe ser único entre todas las herramientas; un plugin nunca gana un choque de nombre contra una herramienta integrada. |
| `spec/0` | La especificación de función al estilo OpenAI: nombre, descripción en lenguaje llano y un JSON Schema para los parámetros. Es lo que el modelo lee para decidir cuándo y cómo invocar la herramienta. |
| `run/2` | Ejecuta la llamada. `args` son los argumentos ya decodificados (un mapa con claves de tipo cadena); `ctx` lleva el contexto de la ejecución actual (más abajo). Devuelve `{:ok, text}` o `{:error, message}`; en ambos casos el resultado se convierte en cadena y vuelve al modelo, así que redáctalo pensando en que el modelo lo va a leer. |

`Pepe.Tools.Tool.function/3` te arma el sobre de la especificación, así que solo tienes que aportar el nombre, la descripción y los parámetros.

Una herramienta completa y funcional, guardada como `.exs` e instalada (ver más abajo):

```elixir
defmodule MyPlugin.Reverse do
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "reverse_text"

  @impl true
  def spec do
    function("reverse_text", "Reverse the characters in a piece of text.", %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "The text to reverse."}
      },
      "required" => ["text"]
    })
  end

  @impl true
  def run(%{"text" => text}, _ctx) do
    {:ok, String.reverse(text)}
  end

  def run(_args, _ctx), do: {:error, "missing 'text'"}
end
```

La segunda cláusula de `run/2` es buena práctica: si el modelo se olvida de un argumento obligatorio, conviene devolver un error claro en vez de dejar que reviente (un fallo también se captura, pero un mensaje pensado a propósito ayuda al modelo a corregirse en la próxima vuelta).

**`ctx`**, el segundo argumento de `run/2`, lleva la ejecución actual consigo: `ctx[:agent]` (el agente que está corriendo, por ejemplo `%{name: "assistant"}`), `ctx[:session_key]` (la conversación en vivo, ausente en ejecuciones de un solo turno) y `ctx[:cwd]` (el directorio de trabajo). Trata cada clave como opcional. Las herramientas que leen o escriben archivos resuelven las rutas a través de `Pepe.Agent.Workspace`; las que llaman a una API externa por lo general ignoran `ctx` por completo y usan directamente el cliente HTTP `Req` que ya viene incluido, sin necesitar ninguna dependencia extra.

## El behaviour Channel provider

Un proveedor de canal le enseña a Pepe a hablar una plataforma de mensajería nueva sobre el webhook de entrada genérico que ya existe: ninguna ruta nueva, solo un módulo más en el registro.

```elixir
@callback name() :: String.t()
@callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error
@callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error
@callback parse(payload :: map()) :: {:ok, [inbound]} | :ignore
@callback deliver(config :: map(), to :: String.t(), text :: String.t()) :: :ok | {:error, term()}
```

| Callback | ¿Obligatorio? | Propósito |
|---|---|---|
| `name/0` | sí | Clave de registro y el segmento `:provider` de la URL del webhook, por ejemplo `"whatsapp"`. |
| `verify/2` | sí | Responde al handshake `GET` de la plataforma cuando registras la URL del webhook. `{:ok, challenge}`, o `:error` si el proveedor no maneja eso. |
| `authenticate/3` | sí | Verifica la firma de un `POST` entrante contra el secreto de la conexión. `:ok` para aceptarlo, `:error` para descartarlo. |
| `parse/1` | sí | Normaliza un payload ya decodificado en cero o más mensajes `%{from, text, id}`, o devuelve `:ignore` cuando no hay nada que hacer con eso (recibos, actualizaciones de estado). |
| `deliver/3` | sí | Envía una respuesta de texto a `to` (una dirección propia del proveedor: número de teléfono, id de canal, etc.). |
| `label/0` | no | Etiqueta legible para el panel (usa `name/0` si se omite). |
| `config_schema/0` | no | Los campos que el panel renderiza para configurar una conexión, con la misma forma que el array `config` de un manifiesto de plugin (ver más abajo). |
| `respond/3` | no | Una respuesta HTTP **síncrona** al `POST` sin procesar, para protocolos que necesitan una antes de que el agente haga nada (el desafío de verificación de URL de Slack, el `PING` de Discord). Devuelve `{:reply, status, content_type, body}`, o `:cont` para dejar que siga a `parse/1`. |
| `deliver_file/4` | no | Envía un archivo como adjunto. Si lo omites, `send_file` simplemente informa que el canal no puede recibir archivos. |
| `addressed?/2` | no | ¿Este payload va dirigido al bot y merece respuesta? Permite que un proveedor respete `require_mention` en chats grupales (si se omite, el valor por defecto es que siempre va dirigido al bot). |
| `deliver_blocks/3` | no | Renderiza contenido estructurado (ver [Bloques de presentación](#bloques-de-presentación) más abajo) en la interfaz nativa de la plataforma. Si lo omites, la herramienta `send_presentation` igual entrega el contenido, aplanado a texto simple a través de `deliver/3`. |

### Bloques de presentación

Una herramienta puede enviar contenido más rico que texto simple (una tabla, una fila de botones) a través de la herramienta `send_presentation` y el esquema de bloques compartido `Pepe.Presentation`:

```
%{"type" => "text", "text" => "..."}
%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}
%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}
```

Hoy Slack renderiza esto como Block Kit de verdad (una `section` por cada bloque de texto o tabla, un bloque `actions` con botones reales). Un proveedor que todavía no agregó `deliver_blocks/3` igual recibe el contenido: `Pepe.Presentation.to_text/1` lo aplana a texto simple legible y lo manda por el `deliver/3` normal del proveedor. Así, una herramienta que envía bloques funciona de inmediato en todos los canales, y solo se ve enriquecida donde algún proveedor se tomó el trabajo de renderizarlos.

## El behaviour PluginRoute: la ruta HTTP propia de un plugin

El contrato de eventos entrantes de `Pepe.Webhooks.Provider` es fijo, una sola forma pensada para plataformas de chat. `Pepe.PluginRoute` existe para lo que necesita algo distinto: un callback de redirección OAuth que tiene que caer sobre el dominio público del propio Pepe, un endpoint REST o RPC hecho a medida.

```elixir
@callback route_prefix() :: String.t()
@callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()
```

`call/2` recibe el `Plug.Conn` sin procesar (ya pasado por el parseo de body del propio endpoint) y los segmentos de ruta que vienen después de tu propio prefijo: control total, igual que cualquier Plug escrito a mano, porque Pepe no puede anticipar todas las formas que el protocolo propio de un plugin pueda necesitar. Si `call/2` revienta, responde `500`, pero nunca se lleva por delante el proceso de la petición ni ninguna otra cosa.

**Cómo construir uno, paso a paso:**

1. Escribe un módulo que implemente `route_prefix/0` y `call/2`:

   ```elixir
   defmodule MyPlugin.OAuthCallback do
     @behaviour Pepe.PluginRoute

     @impl true
     def route_prefix, do: "weather_oauth"

     @impl true
     def call(conn, _path) do
       # maneja la redirección del proveedor, intercambia el código, etc.
       Plug.Conn.send_resp(conn, 200, "connected")
     end
   end
   ```

2. Guárdalo como `~/.pepe/plugins/weather_oauth.exs` e instálalo:
   `pepe plugin install ~/.pepe/plugins/weather_oauth.exs`.
3. **Activa la ruta explícitamente.** Reclamar un prefijo en el código no expone nada por sí solo; hace falta un **segundo opt-in, deliberado**, porque una ruta (a diferencia de una herramienta) responde a cualquier petición entrante, no solo a la que el propio modelo del agente decidió hacer:

   ```bash
   pepe plugin route list                 # cada plugin instalado que reclama ruta, activo o no
   pepe plugin route enable weather_oauth # ahora accesible en /plugin-routes/weather_oauth/...
   pepe plugin route disable weather_oauth
   ```

4. Apunta lo que necesite llegar a ella (la URL de redirección de una app OAuth, quien envía un webhook) a `https://tu-dominio/plugin-routes/weather_oauth/...`. Los segmentos de ruta que vienen después del prefijo llegan como segundo argumento de `call/2`.

## El behaviour Realtime provider: audio dúplex

Ningún otro punto de extensión de Pepe sostiene un flujo continuo y bidireccional: una llamada a herramienta, un webhook o un ocupante de slot son siempre de petición y respuesta, o de una sola vez. `Pepe.Realtime.Provider` es esa pieza que faltaba: un plugin controla por completo cómo el audio entrante se convierte en una respuesta saliente (un modelo en tiempo real alojado en la nube, una tubería de STT en streaming seguida de TTS), y un canal WebSocket nuevo transporta los bytes.

```elixir
@callback name() :: String.t()
@callback start(agent :: map(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}
@callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}
@callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}   # opcional
@callback stop(session :: term()) :: :ok
```

Un cliente se une a `realtime:<agent_name>` (`realtime:default` para el agente predeterminado) con `{"provider": "your_provider_name"}` en el payload de la unión, y después envía fragmentos binarios en el evento `"audio"`. El `sink` que recibe `start/3` es el pid al que se le mandan los eventos de vuelta durante toda la vida de la sesión: `{:realtime_audio, chunk}`, `{:realtime_text, text}`, o `{:realtime_stopped, reason}` si el proveedor termina la sesión por su cuenta. Es aditivo, no un slot: se pueden instalar varios proveedores a la vez, y cada cliente elige uno por nombre en cada conexión; nada necesita habilitarse de forma global como sí ocurre con un `Pepe.PluginRoute`. Pepe no trae ningún proveedor realtime propio: este es justamente el punto de extensión que un plugin viene a llenar.

**Cómo construir uno, paso a paso:**

1. Escribe un módulo que implemente `name/0`, `start/3`, `push_audio/2`, `stop/1` y, si quieres, `push_text/2`. El ejemplo de abajo es un proveedor de eco: devuelve el mismo audio que recibe, más un subtítulo por cada fragmento. Alcanza para desarrollar un cliente contra él antes de tener un backend real de STT/TTS o de un modelo alojado:

   ```elixir
   defmodule EchoRealtime do
     @behaviour Pepe.Realtime.Provider

     @impl true
     def name, do: "echo_realtime"

     @impl true
     def start(agent, _opts, sink) do
       send(sink, {:realtime_text, "session started for #{agent.name}"})
       {:ok, sink}
     end

     @impl true
     def push_audio(sink, chunk) do
       send(sink, {:realtime_text, "echoing #{byte_size(chunk)} bytes"})
       send(sink, {:realtime_audio, chunk})
       :ok
     end

     @impl true
     def push_text(sink, text) do
       send(sink, {:realtime_text, "echo: " <> text})
       :ok
     end

     @impl true
     def stop(_sink), do: :ok
   end
   ```

   Aquí el propio argumento `sink` de `start/3` funciona también como el término de sesión, porque este proveedor no tiene ninguna conexión o proceso real propio que rastrear; un proveedor que hable con un backend de verdad (un modelo alojado, una tubería local de STT/TTS) devolvería algo que identifique *eso*, y usaría `sink` únicamente para mandar eventos de vuelta.

2. Guárdalo como `~/.pepe/plugins/echo_realtime.exs` e instálalo: `pepe plugin install ~/.pepe/plugins/echo_realtime.exs`. No hay nada más que activar: un proveedor realtime no tiene slot que fijar ni ruta que habilitar, queda vivo apenas se instala, esperando a que un cliente lo pida por su nombre.
3. Desde un cliente, únete a `realtime:<agent_name>` en el WebSocket ya existente (`/socket/websocket`) indicándolo en el payload:

   ```js
   let ws = new WebSocket("ws://localhost:4000/socket/websocket");
   ws.onmessage = (e) => console.log(JSON.parse(e.data));
   ws.onopen = () => {
     ws.send(JSON.stringify({
       topic: "realtime:default", event: "phx_join",
       payload: { provider: "echo_realtime" }, ref: 1
     }));
   };
   ```

4. Una vez conectado, envía fragmentos binarios en el evento `"audio"`; los eventos `{:realtime_audio, ...}` y `{:realtime_text, ...}` vuelven de la misma manera que cualquier otro push del canal.

## El behaviour Hook: mutación real de contenido

Un hook reescribe de verdad el contenido de la conversación, en línea, en el mismo camino síncrono en el que ya corren `pii_redact`, `llm_redact`, `http_redact` y `presidio`. Así es como un plugin de compactación de contexto o de censura de contenido hace trabajo real, algo que no debe confundirse con un observador de ejecución (más abajo), que solo puede mirar.

```elixir
@callback name() :: String.t()
@callback stages() :: [:inbound | :outbound | :learn | :tool_result]
@callback run(stage, text :: String.t(), settings :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:ok, String.t(), [%{"fake" => String.t(), "real" => String.t()}]}
```

`:inbound` corre sobre el texto del usuario antes de que el modelo lo vea; `:outbound` sobre la respuesta antes de que se mande de vuelta; `:tool_result` sobre la salida cruda de una herramienta antes de que se sume a la conversación. Un agente se suscribe a hooks por nombre (`mix pepe agent add NOMBRE --hooks tu_hook,pii_redact`). Un hook de plugin se suma a los cuatro integrados sin reemplazarlos, y uno integrado siempre gana un choque de nombre, así que elige un nombre distinto de `pii_redact`, `llm_redact`, `http_redact` y `presidio`.

Los hooks se encadenan: con `--hooks bracket,exclaim`, `exclaim` recibe el texto ya mutado por `bracket`, en orden. Es secuencial, cada uno viendo la salida del anterior, nunca un reparto en paralelo. Devuelve el texto (sin cambios si no hiciste ninguno) y, si quieres, una lista de entradas de mapa reversible (`fake` para el token, `real` para el valor que reemplazó) para que se restauren a la salida.

**Falla abierto, y a propósito**: un hook que lanza una excepción cae de vuelta al texto de entrada en lugar de romper el turno. Un hook muta o censura, pero nunca bloquea. Para vetar una llamada por completo está `Pepe.Permissions.Policy`, más abajo, un mecanismo deliberadamente distinto y más acotado.

## El behaviour Policy: vetar una llamada a herramienta

Un plugin de policy puede rechazar una llamada a herramienta antes de que corra, por una razón que solo tu plugin conoce (una regla interna de la empresa, un servicio externo de lista de permitidos, un limitador de tasa).

```elixir
@callback name() :: String.t()
@callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

Cada policy instalada se consulta en **cada** llamada a la barrera de permisos, para todos los agentes a los que aplica. No es algo opcional como un hook, ya que instalar una policy solo puede sumar restricciones, nunca quitarlas. Se comprueba antes que la propia lógica de preaprobación de Pepe, así que una policy puede vetar incluso una llamada que el operador ya marcó como aprobada de forma permanente (`:always`). Sin llegar a un rechazo total, `:ask` o `{:ask, reason}` obliga a que un humano revise una llamada que de otro modo se habría preaprobado en silencio (el motivo aparece junto al aviso). Entre todas las policies instaladas gana siempre la más restrictiva: `:deny` le gana a `:ask`, y `:ask` le gana a `:allow`.

El alcance de "a los que aplica" todavía se puede acotar, pero solo por el operador, nunca por el propio agente, porque eso anularía el sentido de la policy:

```bash
pepe policy list                                      # cada policy instalada + su alcance
pepe policy scope no_bash_policy --agents support --projects acme
pepe policy scope no_bash_policy --clear              # vuelve a aplicarse en todas partes
```

o directamente en `config.json` (bajo `"policy_scope"`, por nombre de policy). Si no hay entrada para el nombre de una policy, se entiende que no tiene alcance restringido: aplica a todos los agentes, el comportamiento original y por defecto. Un agente nunca puede excluirse a sí mismo de una policy; solo quien configura el alcance decide dónde se llega a consultar.

**Falla cerrado: la única excepción deliberada en todo este sistema de plugins.** Cualquier otra superficie de plugin en Pepe, ante un fallo o un timeout, se degrada a "como si no estuviera instalada". Un plugin de policy hace justo lo contrario: si `check/3` lanza una excepción, se cuelga más allá de su timeout, o devuelve cualquier cosa que no sea un `:allow` explícito, **la llamada queda denegada**. Una comprobación de seguridad que no pudo correr no es lo mismo que una que sí pasó.

```elixir
defmodule MyPlugin.NoBashPolicy do
  @behaviour Pepe.Permissions.Policy

  @impl true
  def name, do: "no_bash_policy"

  @impl true
  def check("bash", _args, _ctx), do: {:deny, "bash is blocked on this instance"}
  def check(_name, _args, _ctx), do: :allow
end
```

Agrega un `check_run/3` opcional para vetar una ejecución completa, antes de cualquier llamada a herramienta y antes de la primera llamada al modelo. Es la única forma de decir "no proceses este mensaje en absoluto" (un remitente vetado, un límite de tasa a nivel de mensaje), ya que `check/3` nunca se dispara en un turno que jamás llega a invocar una herramienta:

```elixir
@callback check_run(agent :: map(), first_message :: String.t(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

## El behaviour RunObserver

Un observador de ejecución mira el turno de un agente desde afuera, útil para registrar logs, métricas o alertas sobre lo que hace un agente, sin tocar nada de lo que hace. Es estrictamente de solo observación: nunca ve el historial de mensajes de la conversación, no puede bloquear un turno y no puede cambiar nada en él; solo se entera de lo que ya pasó, después de que pasó.

```elixir
@callback name() :: String.t()
@callback subscriptions() :: [atom()]
@callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
```

`subscriptions/0` indica qué tipos de evento te interesan, cualquier combinación de `:run_start`, `:tool_call`, `:tool_denied`, `:tool_result`, `:assistant`, `:assistant_delta`, `:failover`, `:output_cap`, `:usage`, `:inline`, `:done`, `:error` y `:run_end`. `handle_event/3` se llama una vez por cada evento al que te suscribiste, en el mismo orden en que el turno los fue produciendo. `payload` es la tupla del evento tal cual (por ejemplo `{:tool_result, "web_search", "..."}`), con una excepción: `:tool_call` llega como `{:tool_call, name}`, sin sus argumentos, porque esos todavía no pasaron por la censura y podrían llevar secretos.

Un ejemplo mínimo que registra cada llamada a herramienta y la respuesta final:

```elixir
defmodule MyPlugin.ToolLogger do
  @behaviour Pepe.Agent.RunObserver
  require Logger

  @impl true
  def name, do: "tool_logger"

  @impl true
  def subscriptions, do: [:tool_call, :done]

  @impl true
  def handle_event(:tool_call, {:tool_call, name}, _meta), do: Logger.info("tool called: #{name}")
  def handle_event(:done, {:done, content}, _meta), do: Logger.info("run finished: #{String.slice(content, 0, 80)}")
end
```

El despacho es asíncrono y está aislado: un observador colgado o que falla nunca frena ni rompe la conversación que está observando. Uno que falla 3 veces seguidas queda deshabilitado, y no solo en esa ejecución sino en todas las futuras, para que un observador roto no siga pagando su propio costo de detección para siempre ni te llene los logs con el mismo fallo una y otra vez. Acá no hay nada que concederle a un agente: instalado ya significa habilitado.

## El registro

`Pepe.Tools.all/0` devuelve las herramientas integradas seguidas de cada herramienta de plugin cargada; `Pepe.Webhooks` hace lo mismo con los proveedores de canal. Las integradas y los plugins se combinan en un único registro, y las dos formas resuelven un choque de nombres de manera opuesta. Con las herramientas, siempre gana la integrada, así que elige un nombre distinto de `read_file`, `web_search` y el resto de `pepe tools`. Con los proveedores de canal, en cambio, gana el plugin del mismo nombre, que es justamente cómo reemplazas un proveedor incluido de fábrica por tu propia versión.

### Conceder una herramienta a un agente

Instalar un plugin no le entrega sus herramientas a todos los agentes: solo quedan expuestas las que estén explícitamente listadas en cada agente, con el mismo control de permisos que una integrada.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Panel:** abre el agente en Agentes y marca la herramienta; las herramientas de plugin aparecen junto a las integradas.

**Por chat:** un agente con `enable_tool` puede activar una herramienta para sí mismo:

> Tú: activa la herramienta reverse_text
>
> Agente: reverse_text activada; ya puedes usarla desde tu próximo mensaje

Para conceder una herramienta a *otro* agente, la acción `add_tool` de `manage_agent` se encarga (limitada a los agentes que quien la pide tiene permiso de gestionar, y siempre confirma contigo antes):

> Tú: dale al agente de soporte la herramienta gmail_search
>
> Agente: voy a añadir gmail_search al agente "support". ¿Confirmas?

## Dónde viven los plugins y cómo se cargan

Los plugins viven en `~/.pepe/plugins/` (respeta `PEPE_HOME`). Pepe recorre esa carpeta de forma recursiva buscando archivos `.exs`, compila cada uno una sola vez, y solo vuelve a compilarlo cuando cambia en disco. Sueltas un archivo ahí y funciona sin reiniciar nada; lo editas, y el cambio se aplica en la siguiente llamada a una herramienta. Un mismo archivo puede definir varios módulos (el ejemplo de Google de más abajo trae cuatro).

Un plugin toma una de dos formas: un archivo `.exs` suelto, o un **paquete** (un directorio con un `manifest.json` y uno o más archivos `.exs`).

Compilar en tiempo de ejecución trae consigo una limitación honesta: **un plugin no puede traer una dependencia externa nueva**. Elixir resuelve y compila las dependencias en tiempo de compilación del proyecto, así que un plugin solo puede usar las bibliotecas que Pepe ya trae de fábrica (`Req`, `Jason`, la biblioteca estándar y el resto de sus dependencias). Un plugin que necesita una biblioteca completamente nueva no se puede simplemente soltar ahí; implicaría recompilar Pepe entero. En la práctica esto casi nunca es un problema, porque una herramienta que llama a una API HTTP, o un proveedor de canal como Chatwoot, no necesitan nada más allá de lo que ya viene incluido, y por eso se instalan sin fricción.

## Instalar un plugin

La fuente puede ser un archivo local, un directorio local, un `.tar.gz`, una URL a cualquiera de esos, o una referencia de [PepeHub](https://hub.pepe-agent.com), y `install` desempaqueta lo que le des en la carpeta de plugins. Una URL de repositorio de GitHub se descarga como su archivo fuente y se extrae, tomando la rama por defecto (`main`, y si no existe, `master`) cuando no indicas ninguna; agrega `/tree/<branch>` a la URL para elegir otra. Un `.tar.gz`, local o remoto, se extrae y el paquete queda ubicado bajo el `name` de su manifiesto. Un directorio se copia tal cual, y un `.exs` suelto se copia directo.

Una referencia de PepeHub puede ser la forma corta `@handle/nombre` o la propia URL de la página del paquete, copiada tal cual desde `hub.pepe-agent.com`: las dos apuntan al mismo paquete, así que cualquiera de las dos sirve. Si apuntas `plugin install` a un nombre que en realidad es una skill de PepeHub y no un plugin, falla con un mensaje claro que te dice que uses `skill install` en su lugar.

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin install @jhonathas/backup-tool
pepe plugin list
pepe plugin remove google
```

**Panel:** la página de Plugins acepta una URL de GitHub, una URL `.tar.gz` o una ruta local; marcas una casilla confirmando que confías en la fuente y le das a Instalar. Los plugins instalados aparecen listados con un botón Eliminar, y cuando el plugin declara ajustes propios, también un botón Configurar.

**Desde el chat, con `manage_plugin`:** un agente que tenga esta herramienta puede instalar en tu nombre: primero corre `scan` sobre una fuente para ver qué hace, y después `install`, `list` o `remove`. Pasa por el mismo escaneo de seguridad que la CLI, pero sin la vía de escape `--force`: un veredicto peligroso siempre se rechaza desde el chat, y el agente te va a decir que revises el código y corras `--force` vos mismo en una terminal si aun así quieres instalarlo.

## El escaneo de seguridad

Un plugin es Elixir corriente, con acceso total a la aplicación en ejecución; instalar uno es una decisión de confianza, igual que instalar cualquier otro programa en tu máquina. Instala solo desde una fuente en la que confíes, y de preferencia fija una versión o un commit concretos.

Antes de dejarlo en disco, `Pepe.Skills.Sentinel` escanea el código. Lee la **estructura** del código (su árbol de sintaxis), no solo el texto en bruto, así que marca con precisión las llamadas peligrosas:

- ejecutar comandos de shell (`System.cmd`, `:os.cmd`),
- evaluación dinámica (`Code.eval_string`),
- deserialización insegura (`:erlang.binary_to_term`),
- llamadas destructivas al sistema de archivos (`File.rm_rf`),
- agotamiento de átomos (`String.to_atom`),
- lectura del entorno o de rutas con secretos (`~/.ssh`, la configuración de Pepe),
- acceso a la red.

Como analiza la estructura en vez de las palabras, también detecta las formas con alias y las variantes en Erlang de esas mismas llamadas, y no se confunde cuando esas mismas palabras aparecen dentro de un comentario o una cadena de texto. Nunca ejecuta el código, y siempre devuelve uno de tres veredictos:

- **limpio**: sin hallazgos.
- **precaución**: algo se marcó, pero suele ser legítimo (un plugin de canal *debería* hacer llamadas de red); se muestra, pero no bloquea nada.
- **peligro**: no hay ninguna buena razón para que esto esté ahí; bloquea la instalación.

```bash
pepe plugin scan ./my_plugin.exs        # escanea sin instalar
pepe plugin install ./risky.exs --force # sigue adelante de todos modos, después de revisarlo
```

<div class="note"><strong>Un plugin corre con acceso total.</strong> El escaneo es una red de seguridad, no un sustituto de leer el código con tus propios ojos.</div>

## El manifiesto y el diálogo de Configurar

El `manifest.json` de un paquete lo identifica, lo describe y, lo más útil de todo, declara los ajustes que necesita. Tomado del ejemplo de Google incluido de fábrica:

```json
{
  "name": "google",
  "version": "0.1.0",
  "description": "Google Workspace tools: read/create Calendar events and search/send Gmail, as agent tools.",
  "provides": ["tool:gcal_upcoming", "tool:gcal_create_event", "tool:gmail_search", "tool:gmail_send"],
  "files": ["google.exs"],
  "config": [
    {"key": "access_token", "label": "Access token", "type": "secret", "hint": "ya29... (expires in ~1h); or fill the refresh trio below. Store as ${ENV_VAR} to keep it out of the file."},
    {"key": "client_id", "label": "OAuth client ID", "type": "text", "hint": "...apps.googleusercontent.com"},
    {"key": "client_secret", "label": "OAuth client secret", "type": "secret"},
    {"key": "refresh_token", "label": "Refresh token", "type": "secret", "hint": "minted once from the consent flow; survives access-token expiry"}
  ]
}
```

Cada entrada de `config` describe un campo: `key` (el nombre que lee tu código), `label` (lo que se muestra en el formulario), `type` (`"text"`, `"secret"` para una entrada enmascarada, o `"select"` con una lista de `"options"`), y un `hint` opcional. El panel lee este array y renderiza el diálogo de Configurar solo a partir de eso; un plugin nuevo no necesita ninguna pantalla propia. Un valor puede ser una referencia `${ENV_VAR}`, que se guarda tal cual y se resuelve desde el entorno recién al leerla, así que los secretos nunca quedan expandidos dentro del archivo de configuración.

Lee un ajuste guardado desde el código de tu propio plugin con `Pepe.Plugins.config/3` (el nombre es el del paquete en el manifiesto; el tercer argumento es un valor por defecto):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

Un patrón habitual: preferir el valor guardado en el panel, y si no está, recurrir a una variable de entorno, para que el plugin funcione tanto si el operador llena el formulario como si prefiere exportar una variable (el ejemplo de Google de más abajo hace exactamente eso).

## Ejemplo: el plugin de herramientas de Google Workspace

`examples/plugins/google/google.exs` trae cuatro herramientas en un solo archivo:

| Herramienta | Qué hace |
|------|--------------|
| `gcal_upcoming` | Lista los próximos eventos del Google Calendar principal |
| `gcal_create_event` | Crea un evento (resumen, inicio, fin, descripción) |
| `gmail_search` | Busca en Gmail y devuelve remitente y asunto de las coincidencias |
| `gmail_send` | Envía un correo en texto plano |

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

Se autentica con un token bearer de OAuth2 resuelto en el momento de cada llamada; nada sensible queda embebido en el código. Puedes exportar un token de acceso ya generado (lo más rápido, pero expira en aproximadamente una hora):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

o usar un refresh token (sobrevive a la expiración, porque el plugin genera un token de acceso nuevo en cada llamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Consigue estos valores creando un cliente OAuth (tipo "Desktop app") dentro de un proyecto de Google Cloud, con las API de Calendar y Gmail habilitadas, después de correr una vez el flujo de consentimiento para los permisos que vayas a usar. O completa los mismos campos en el diálogo de Configurar del plugin, guardando los secretos como referencias `${ENV_VAR}`.

El código completo de una de las herramientas, para ver el patrón de principio a fin:

```elixir
defmodule Pepe.Plugins.GCalUpcoming do
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gcal_upcoming"

  @impl true
  def spec do
    function("gcal_upcoming", "List upcoming events on the user's primary Google Calendar.", %{
      "type" => "object",
      "properties" => %{
        "max" => %{"type" => "integer", "description" => "How many events to return (default 10)."}
      }
    })
  end

  @impl true
  def run(args, _ctx) do
    max = args["max"] || 10
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    API.with_token(fn token ->
      params = [maxResults: max, orderBy: "startTime", singleEvents: true, timeMin: now]

      case API.get("https://www.googleapis.com/calendar/v3/calendars/primary/events", token, params) do
        {:ok, %{"items" => items}} -> {:ok, format_events(items)}
        {:ok, _} -> {:ok, "No upcoming events."}
        error -> error
      end
    end)
  end
end
```

> Tú: ¿qué tengo mañana en el calendario? Envíale un resumen por correo a sam@example.com
>
> Agente: (invoca gcal_upcoming, y después gmail_send) Tienes 3 eventos mañana. Envié el resumen por correo a sam@example.com.

## Ejemplo: el plugin de canal Chatwoot

`examples/plugins/chatwoot/` muestra la otra forma posible: un **canal**, no una herramienta. Registra un proveedor `chatwoot` para que Pepe pueda sentarse detrás de una bandeja de [Chatwoot](https://www.chatwoot.com) como el agente de IA, en todos los canales que Chatwoot ya cubre (WhatsApp, widget web, Instagram, y demás).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Traspaso nativo a una persona, sin pegamento adicional.** Chatwoot lleva la señal de traspaso en cada webhook: el `status` de la conversación. El plugin implementa `parse/1` para responder solo a las conversaciones marcadas `pending` (propiedad del bot); en el momento en que un agente humano la toma (`open`), Pepe se queda callado, y retoma en cuanto vuelve a `pending`.

**Configuración, del lado de Chatwoot:** crea un AgentBot y apunta su webhook saliente a `https://TU_HOST/webhooks/<project>/chatwoot/<slug>`. La conexión guarda `base_url`, `account_id` y un `api_token` (como `${ENV_VAR}`) a través de `config_schema/0`, completados desde el panel con el mismo patrón de Configurar que cualquier otro plugin.

> Esta es una de dos formas mutuamente excluyentes de usar WhatsApp: **o bien** WhatsApp directo dentro de Pepe (el proveedor `whatsapp` integrado), **o bien** WhatsApp sobre Chatwoot con Pepe detrás (este plugin). Nunca conectes el mismo número a las dos a la vez.

## Entregar un archivo, no solo texto

El `run/2` de una herramienta solo puede devolver texto. Para entregarle a la persona de la conversación un archivo de verdad (una hoja de cálculo, un PDF), no reinventes la entrega: invoca la herramienta integrada `send_file` con una ruta, y Pepe resuelve el canal a partir de la sesión y lo entrega ahí mismo. Concédele `send_file` a un agente y ya funciona desde el chat, en cualquier canal cuyo proveedor implemente `deliver_file/4`.

## Checklist

**Escribir una herramienta:**

1. Implementa `name/0`, `spec/0` y `run/2`; ponle un nombre distinto de cualquier herramienta integrada.
2. Devuelve `{:ok, text}` o `{:error, message}` desde `run/2`, redactado pensando en que el modelo lo va a leer.
3. ¿Necesita credenciales u opciones? Incluye un `manifest.json` con un array `config`, y léelas con `Pepe.Plugins.config/3`.

**Escribir un canal:**

1. Implementa `name/0`, `verify/2`, `authenticate/3`, `parse/1` y `deliver/3`; agrega `config_schema/0` si necesita credenciales configuradas desde el panel.
2. Agrega `respond/3` solo si el protocolo de la plataforma exige una respuesta síncrona antes de cualquier trabajo del agente; `deliver_file/4` solo si puede recibir adjuntos.

**En cualquiera de los dos casos:** escanéalo (`pepe plugin scan SRC` o `manage_plugin scan`), instálalo, revisa lo que encontró el escaneo, y después concédele la herramienta a un agente (por CLI, panel, o `enable_tool`/`manage_agent` desde el chat). Un canal no necesita ninguna concesión: queda activo apenas se instala.
