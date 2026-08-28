---
title: Slots
description: Deja que un plugin instalado tome el control de un punto de extensión exclusivo, como la búsqueda en memoria o la búsqueda web, en lugar del predeterminado, con reversión automática si se comporta mal.
---

Hay tareas dentro de Pepe que solo pueden tener un dueño a la vez: algo tiene que ser *el*
encargado de responder una búsqueda en memoria, o *el* lugar donde corre un comando de
shell. Un **slot** es justamente ese tipo de punto de extensión, con un único ocupante en
todo momento, a diferencia de una herramienta o un canal de [plugin](/docs/plugins), donde
varios pueden convivir sin problema. La búsqueda en memoria es un slot: o responde la
búsqueda integrada, o toma el control un plugin instalado que tú mismo nombraste. Nunca
ambos a la vez, y nunca una acumulación silenciosa de varios plugins respondiendo la misma
pregunta.

El ocupante integrado no es un caso especial dentro del código; es simplemente el que
queda por defecto cuando no hay nada configurado. Cambiar el ocupante de un slot es un
cambio de configuración, jamás un cambio de código. Y si el ocupante configurado falla,
tarda demasiado, o devuelve algo con formato incorrecto, Pepe vuelve al integrado para esa
llamada puntual y lo deja registrado: un ocupante que se comporta mal puede bajar la
calidad de una respuesta, pero nunca llega a romper una conversación.

## Los slots que existen hoy

| Slot | Ocupante integrado | Qué responde |
|---|---|---|
| `memory` | Búsqueda por subcadena, sin distinguir mayúsculas, en `MEMORY.md`/`USER.md`/`people.md` | La herramienta `memory_search` |
| `web_search` | La Instant Answer API de DuckDuckGo | La herramienta `web_search` |
| `sandbox` | Corre directo, o a través del script wrapper configurado (ver [Seguridad](/docs/security)) | Las herramientas `bash`/`run_script`: *dónde* corre en verdad un comando de shell |
| `model_select` | La cadena estática de `Pepe.Config.model_chain_for_agent/1` | Qué cadena de modelos usa un turno |
| `heartbeat_interval` | Siempre deja pasar un pulso vencido | Si un pulso de heartbeat de Telegram, ya vencido, puede dispararse |
| `compaction` | Resume el tramo intermedio de una conversación larga usando el propio modelo | Cómo se condensa una conversación larga para que quepa en la ventana de contexto |
| `harness` | El propio bucle de conversación del agente (`Pepe.Agent.Runtime`) | El turno *completo*: no una llamada puntual, sino todo el ciclo de razonamiento |

Hay un slot que merece una advertencia aparte antes de asignarle nada: `harness`. Un
plugin instalado ahí pasa a manejar la tarea entera, y actúa con los mismos permisos que
tiene la conversación, así que instala solo uno que venga de una fuente en la que confíes.
Los detalles están en la sección Harness, más abajo.

## Administrar slots

```bash
pepe slot list                 # cada slot, su ocupante actual y su valor por defecto
pepe slot set memory NOMBRE    # fija un slot al nombre propio de un plugin instalado
pepe slot clear memory         # vuelve al integrado
```

`pepe slot list` marca como "usando el predeterminado en su lugar" a cualquier ocupante
configurado que ya no puede responder de verdad (fue eliminado, renombrado, o nunca llegó
a reclamar el slot). `pepe doctor` revisa exactamente lo mismo, así que un ajuste de slot
que quedó obsoleto no pasa desapercibido.

## Acotar un slot a un agente o a un proyecto

El `pepe slot set` de arriba fija un slot para toda la instalación: todos los agentes
comparten el mismo ocupante. Un agente puede anular eso solo para sí mismo:

```bash
pepe agent add support --slots memory:example_memory
```

o directamente en `config.json`:

```json
{
  "agents": {
    "support": { "slots": { "memory": "example_memory" } }
  }
}
```

Un proyecto puede definir su propio valor por defecto para todos sus agentes, con la
misma forma que ya usa `default_hooks`:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

El orden de resolución es: anulación del agente, luego el valor por defecto del proyecto,
luego el ajuste de toda la instalación, y por último el integrado. Un agente dentro de un
proyecto puede correr un backend de memoria distinto al de cualquier otro agente o
proyecto, sin necesidad de un cambio global que nadie más pidió.

## Escribir un plugin de slot

Un plugin reclama un slot exportando el conjunto de funciones propio del slot, más
`slot/0`, que devuelve el nombre exacto del slot: ese es el desambiguador, tal como el
`name/0` de una herramienta evita que se la confunda con otra.

### Memoria

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` puede traer `:limit` y una pista `:mode` (`:keyword | :vector | :hybrid`); el
integrado ignora `:mode` por completo, pero un backend más elaborado (un vector store) es
libre de aprovecharla. `index/1` es opcional, pensado para un backend que mantiene su
propio almacén y necesita reconstruirlo.

### Búsqueda web

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "web_search"
@callback search(query :: String.t(), opts :: keyword()) ::
            {:ok, [%{title: String.t() | nil, url: String.t() | nil, snippet: String.t()}]} |
            {:error, term()}
```

### Sandbox

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "sandbox"
@callback run(program :: String.t(), argv :: [String.t()], opts :: keyword()) ::
            {:ok, {output :: String.t(), exit_status :: non_neg_integer()}} | {:error, term()}
```

Cuando esto corre, `opts` ya llega con su `:env` limpio de todo secreto que Pepe tenga
guardado (revisa en [Seguridad](/docs/security) la sección sobre "la shell del agente no
hereda los secretos de Pepe"); eso vale sin importar qué ocupante responda. Este es el
único slot donde el `timeout_ms` propio de cada llamada de `bash` (no el techo, bastante
generoso, de 5 minutos del slot) es el plazo real para el integrado; un ocupante de plugin
igual debería responder con prontitud, porque el techo del slot es una red de contención,
no un presupuesto para gastar entero.

### Selección de modelo

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

Se llama una vez por turno (`Pepe.Agent.Runtime.do_run/3`), antes de recorrer la cadena de
modelos, nunca por cada llamada a herramienta. Devolver `[]` es una respuesta válida
("ningún modelo configurado"), no una respuesta malformada. Un `:model` explícito que pase
quien hace la llamada (una prueba fijada, un harness) ignora este slot por completo:
significa exactamente ese modelo, no lo que decidiera aplicar la política de un ocupante.

Un uso natural: cambiar a un modelo más económico cuando el gasto de un proyecto se
acerca a su tope. `Pepe.Usage.tier/1` reporta `:normal | :low_compute | :critical | :dead`
a partir de la misma proporción que ya usa el propio tope de gasto (ver
[Uso y facturación](/docs/billing)), así que un ocupante no tiene que recalcularla por su
cuenta.

### Ritmo del heartbeat

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

Es un veto adicional por encima del propio calendario estático de `heartbeat_minutes` u
horario de un bot de Telegram, algo que este slot nunca toca: se llama solo después de que
ese calendario ya determinó que un pulso está vencido, justo antes de que se dispare de
verdad. El integrado siempre lo permite. Un plugin instalado aquí puede saltarse un pulso
que de otro modo correspondería disparar; `Pepe.Usage.tier/1` es la señal más obvia, por
ejemplo saltarlo mientras un proyecto está en `:critical` o `:dead`.

### Compactación

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

Un plugin aquí decide cómo se condensa una conversación larga para que quepa en la
ventana de contexto del modelo: puede aplicar una estrategia de resumen distinta, una
heurística sin LLM de por medio, lo que prefiera. Siempre debería devolver
`{:ok, messages}`, incluso cuando decide no condensar nada (el integrado nunca falla del
todo; y si el plugin se cae o agota su tiempo, esa llamada puntual igual degrada al
integrado).

**Cómo construir uno, paso a paso:**

1. Escribe un módulo que implemente `name/0`, `slot/0` (devolviendo `"compaction"`), y
   `compact/4`. Abajo hay una estrategia sencilla sin LLM: en cuanto la conversación
   supera cierta cantidad de mensajes, descarta todo salvo el system prompt y los
   intercambios más recientes, dejando un marcador de una sola línea en lugar de un
   resumen real. Es más barato e instantáneo, al precio de olvidar de verdad el tramo
   intermedio en vez de condensarlo.

   ```elixir
   defmodule TailOnlyCompaction do
     # Este slot no trae un módulo @behaviour dedicado: name/0, slot/0 y compact/4 se
     # emparejan por forma, igual que los plugins de memory/web_search.
     def name, do: "tail_only_compaction"
     def slot, do: "compaction"

     @keep_last 12

     def compact(messages, _model, _agent, _session_key) do
       {system, rest} = Enum.split_with(messages, &(&1["role"] == "system"))

       if length(rest) <= @keep_last do
         {:ok, messages}
       else
         marker = %{"role" => "user", "content" => "<system-reminder>\nEarlier turns were dropped to fit the context window (tail_only_compaction).\n</system-reminder>"}
         {:ok, system ++ [marker | Enum.take(rest, -@keep_last)]}
       end
     end
   end
   ```

2. Guárdalo como `~/.pepe/plugins/tail_only_compaction.exs` (o instálalo desde donde
   esté: `pepe plugin install ./tail_only_compaction.exs`).
3. Apunta el slot `compaction` hacia él, ya sea para toda la instalación o solo para un
   agente o proyecto puntual:

   ```bash
   pepe slot set compaction tail_only_compaction   # cada agente
   pepe agent add support --slots compaction:tail_only_compaction  # solo este
   ```

4. Confirma que está activo: `pepe slot list` muestra el ocupante; un fallo o un tiempo
   agotado hace que esa llamada vuelva al integrado, y eso también queda visible ahí.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

Este es el único slot que no recibe el mismo aislamiento que todos los demás: un ocupante
de harness corre dentro del propio proceso del turno, no en una `Task` supervisada,
porque necesita llamar de vuelta a la barrera de permisos y a la ejecución de
herramientas de Pepe exactamente como lo hace el bucle integrado. Eso implica leer el
estado del turno (si la ejecución incorporó contenido externo, qué se aprobó ya) desde
ese mismo proceso, algo que una `Task` aislada, a propósito, no puede ver. Asignarle un
plugin a este slot le entrega el turno *completo*: la barrera de permisos, el control de
bucle y la compactación de contexto son toda maquinaria propia del bucle integrado, y
nada de eso se aplica automáticamente a un turno que está manejando un plugin de harness.
Uno bien construido llama él mismo a `opts[:on_event]` para que una superficie de chat en
vivo siga mostrando texto en streaming, y puede llamar a `Pepe.Trace.event/1` o a
`Pepe.Agent.RunObservers.notify/1` si quiere tener fidelidad completa de traza y
observadores. Un harness que se cae o agota su tiempo devuelve un error en vez de volver
a correr el turno en silencio sobre el bucle integrado: un harness que ya tomó una acción
real (envió una respuesta, corrió una herramienta) por su cuenta no debería arriesgarse a
repetirla.

**Cómo construir uno, paso a paso:**

1. Escribe un módulo que implemente `name/0`, `slot/0` (devolviendo `"harness"`), y
   `run/3`. El ejemplo de abajo delega a un comando externo y devuelve su salida como la
   respuesta completa: es el harness real más pequeño posible, a modo de "delegarle todo
   a la CLI de otro agente":

   ```elixir
   defmodule ExternalCliHarness do
     @behaviour Pepe.Agent.Harness

     @impl true
     def name, do: "external_cli_harness"

     @impl true
     def slot, do: "harness"

     @impl true
     def run(agent, messages, opts) do
       prompt = messages |> List.last() |> Map.get("content", "")

       case System.cmd("my-agent-cli", ["--prompt", prompt], stderr_to_stdout: true) do
         {output, 0} ->
           content = String.trim(output)
           if fun = opts[:on_event], do: fun.({:assistant_delta, content})
           {:ok, content, messages ++ [%{"role" => "assistant", "content" => content}]}

         {output, _status} ->
           {:error, {:external_cli_failed, output}}
       end
     end
   end
   ```

   Llamar a `opts[:on_event]` con `{:assistant_delta, content}` es justamente lo que hace
   que una superficie en vivo (la CLI, el chat del panel) muestre la respuesta de verdad a
   medida que va llegando; revisa la nota del moduledoc de arriba. Si te lo saltas, la
   respuesta igual se devuelve correctamente, solo que no se va a renderizar en vivo en
   una superficie con streaming.

2. Guárdalo como `~/.pepe/plugins/external_cli_harness.exs` e instálalo:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Asigna el slot `harness` a él. Esta es una decisión de más peso que la mayoría de los
   slots, porque le entrega al plugin el turno entero (ver arriba), así que acotarlo
   primero a un solo agente mientras pruebas suele ser lo más sensato:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # solo este agente
   pepe slot set harness external_cli_harness                      # cada agente
   ```

4. Pruébalo: `pepe run cli-backed "hello"` nunca llega a tocar el modelo; la respuesta
   sale directo de `external_cli_harness`.

Un ejemplo mínimo de plugin de slot, guardado como `~/.pepe/plugins/example_memory.exs`:

```elixir
defmodule ExampleMemory do
  @behaviour Pepe.Memory.Backend

  def name, do: "example_memory"
  def slot, do: "memory"

  def search(_agent_name, _query, _opts), do: {:ok, []}
end
```

```bash
pepe plugin install ~/.pepe/plugins/example_memory.exs
pepe slot set memory example_memory
```

El propio envoltorio de contenido no confiable que usa la herramienta `web_search` (ver
[Seguridad](/docs/security)) se queda dentro de la herramienta, sin importar qué backend
ocupe el slot: un backend de slot devuelve resultados estructurados simples, no texto; el
límite de confianza se traza una sola vez, en el núcleo.

## Lo que no es un slot

Hay otros dos puntos de extensión que se parecen a primera vista, pero son aditivos, no
exclusivos, porque ahí sí hace falta que convivan varios ocupantes al mismo tiempo:

- **Un adaptador de protocolo de modelo** (un plugin que implementa `Pepe.LLM.Adapter`
  para un proveedor cuyo protocolo de chat no es compatible con OpenAI, el mismo papel
  que ya cumplen los adaptadores integrados de Responses y Messages) se registra bajo su
  propio valor de `api`; varios protocolos corren al mismo tiempo, uno por conexión de
  modelo. Un plugin nunca puede reemplazar `"openai-responses"` ni
  `"anthropic-messages"`.
- **Un canal de chat con conexión persistente** (un plugin que implementa
  `Pepe.Gateways.Channel`, pensado para una plataforma como Discord o Matrix que necesita
  un websocket de larga duración y no le alcanza con un webhook entrante) corre junto a
  cualquier otro canal, incluido Telegram, dentro de su propio dominio de fallos
  supervisado, de modo que uno que se porte mal no arrastre a los demás. Consulta
  [Plugins](/docs/plugins) para ver el formato basado en webhook de
  `Pepe.Webhooks.Provider`, que es lo primero a lo que debería recurrir la mayoría de los
  plugins de canal; un canal persistente es para esas plataformas que un webhook
  genuinamente no puede cubrir.
- **Un proveedor de audio en tiempo real** (`Pepe.Realtime.Provider`) y **una ruta HTTP
  propia de un plugin** (`Pepe.PluginRoute`) también son aditivos, y ambos se explican en
  [Plugins](/docs/plugins): se pueden instalar varios de cualquiera de los dos a la vez, y
  quien elige cuál usar por nombre es el cliente (o el operador, en el caso de una ruta),
  a diferencia del ocupante único que tiene un slot.
