---
title: Slots
description: Deja que un plugin instalado se haga cargo de un punto de extensión exclusivo - como la búsqueda de memoria o la búsqueda web - en lugar del predeterminado, con recuperación automática si se comporta mal.
---

Un **slot** es un punto de extensión con exactamente un ocupante a la vez - a diferencia de
una herramienta o canal de [plugin](/docs/plugins), donde varios conviven a la vez. La
búsqueda de memoria es un slot: o responde la búsqueda léxica integrada, o un plugin
instalado que nombraste se hace cargo - nunca los dos, y nunca una acumulación silenciosa
de varios plugins respondiendo la misma pregunta.

El ocupante integrado no es código especial; es solo el predeterminado cuando no hay nada
configurado. Cambiar el ocupante de un slot es reconfiguración, nunca un cambio de código -
y si el ocupante configurado falla, tarda demasiado, o devuelve algo malformado, Pepe cae
de vuelta al integrado para esa llamada concreta y lo registra. Un ocupante de plugin
comportándose mal cambia la calidad de la respuesta; nunca rompe una conversación.

## Los slots hoy

| Slot | Ocupante integrado | Qué responde |
|---|---|---|
| `memory` | Búsqueda por subcadena, sin distinguir mayúsculas, en `MEMORY.md`/`USER.md`/`people.md` | La herramienta `memory_search` |
| `web_search` | La API Instant Answer de DuckDuckGo | La herramienta `web_search` |
| `sandbox` | Corre directamente, o a través del script wrapper configurado (ver [Seguridad](/docs/security)) | Las herramientas `bash`/`run_script` - *dónde* corre de verdad un comando de shell |
| `model_select` | La chain estática de `Pepe.Config.model_chain_for_agent/1` | Qué chain de modelo usa un turno |
| `heartbeat_interval` | Siempre permite un pulso vencido | Si un pulso de heartbeat de Telegram ya vencido puede dispararse |
| `compaction` | Resume el tramo intermedio de una conversación larga con el propio modelo | Cómo se condensa una conversación larga para que quepa en la ventana de contexto |
| `harness` | El propio bucle de conversación del agente (`Pepe.Agent.Runtime`) | El turno *entero* - no una llamada, todo el bucle de razonamiento |

## Gestionar slots

```bash
pepe slot list                 # cada slot, su ocupante actual y su predeterminado
pepe slot set memory NOMBRE    # fija un slot a un plugin instalado, por su propio nombre
pepe slot clear memory         # vuelve al integrado
```

`pepe slot list` marca un ocupante configurado que no está resolviendo en este momento
(eliminado, renombrado, o que nunca llegó a reclamar el slot) como "usando el
predeterminado en su lugar" - lo mismo que verifica `pepe doctor`, así que un slot fijado a
algo obsoleto no pasa desapercibido.

## Delimitar un slot a un agente o proyecto

El `pepe slot set` de arriba fija un slot para toda la instalación - cada agente recibe el
mismo ocupante. Un agente puede anular eso para sí mismo:

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

Un proyecto puede tener su propio valor predeterminado para cada agente en él, con la
misma forma que ya usa `default_hooks`:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

La resolución es: anulación del agente → predeterminado del proyecto → configuración de
toda la instalación → el integrado. Un agente dentro de un proyecto puede usar un backend
de memoria distinto al de cualquier otro agente y proyecto, sin un cambio global que nadie
más pidió.

## Escribir un plugin de slot

Un plugin reclama un slot exportando el conjunto de funciones del slot **más** `slot/0`,
devolviendo el nombre exacto del slot - ese es el desambiguador, igual que el `name/0` de
una herramienta evita que se confunda con otra.

### Memoria

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` puede llevar `:limit` y una pista `:mode` (`:keyword | :vector | :hybrid`) - el
integrado ignora `:mode`; un backend más rico (un vector store) es libre de usarla.
`index/1` es opcional, para un backend que mantiene su propio almacén y necesita
reconstruirlo.

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

`opts` ya llega con su `:env` limpio de cada secreto que Pepe guarda cuando esto corre
(ver en [Seguridad](/docs/security) "el shell del agente no hereda los secretos de
Pepe") - válido sin importar qué ocupante responda. Este es el único slot donde el
propio `timeout_ms` por llamada de `bash` (no el techo generoso de 5 minutos del slot)
es el plazo real para el integrado; un ocupante de plugin debe seguir respondiendo
rápido, ya que el techo del slot es una red de seguridad, no un presupuesto para gastar.

### Selección de modelo

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

Se llama una vez por turno (`Pepe.Agent.Runtime.do_run/3`), antes de recorrer la chain de
modelo - nunca por tool call. Devolver `[]` es una respuesta válida ("ningún modelo
configurado"), no malformada. Un `:model` explícito que pasa el llamador (una prueba
fijada, un harness) ignora este slot por completo - significa exactamente ese modelo, no lo
que aplicaría la política de un ocupante.

Un uso natural: cambiar a un modelo más barato cuando el gasto de un proyecto se acerca a
su tope. `Pepe.Usage.tier/1` informa `:normal | :low_compute | :critical | :dead` a partir
de la misma proporción que ya usa el propio tope de gasto (ver [Uso y facturación](/docs/billing)),
así un ocupante no tiene que recalcularlo.

### Ritmo del heartbeat

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

Un veto más encima del propio calendario estático de `heartbeat_minutes`/horario de un bot
de Telegram, que este slot nunca toca: se llama solo después de que ese calendario ya haya
dicho que un pulso venció, justo antes de que dispare de verdad. El integrado siempre
permite. Un plugin aquí puede saltarse un pulso ya vencido - `Pepe.Usage.tier/1` es la señal
obvia, por ejemplo saltarlo mientras un proyecto está en `:critical` o `:dead`.

### Compactación

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

Un plugin aquí decide cómo se condensa una conversación larga para que quepa en la ventana
de contexto del modelo - una estrategia de resumen distinta, una heurística sin LLM, lo que
quiera. Siempre debería devolver `{:ok, messages}`, incluso cuando decide no condensar nada
(el integrado nunca falla del todo; un fallo o un tiempo de espera igual degrada al
integrado para esa llamada).

**Construir uno, paso a paso:**

1. Escribe un módulo que implemente `name/0`, `slot/0` (devolviendo `"compaction"`), y
   `compact/4`. Abajo hay una estrategia simple sin LLM: una vez que la conversación supera
   un número de mensajes, descarta todo salvo el system prompt y los intercambios más
   recientes, con un marcador de una línea en vez de un resumen real - más barato e
   instantáneo, al costo de olvidar de verdad el tramo intermedio en lugar de condensarlo.

   ```elixir
   defmodule TailOnlyCompaction do
     # Este slot no trae un módulo @behaviour dedicado - name/0, slot/0, compact/4 se
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
3. Apunta el slot `compaction` hacia él - para toda la instalación, o solo para un
   agente/proyecto:

   ```bash
   pepe slot set compaction tail_only_compaction   # cada agente
   pepe agent add support --slots compaction:tail_only_compaction  # solo este
   ```

4. Confirma que está activo: `pepe slot list` muestra el ocupante; un fallo o un tiempo
   de espera cae de vuelta al integrado para esa llamada, y también queda visible ahí.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # siempre "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

Este es el único slot que no recibe el aislamiento que tienen todos los demás: un ocupante
de harness corre en el propio proceso del turno, no en una `Task` supervisada, porque
necesita llamar de vuelta al propio gate de permisos y a la ejecución de herramientas de
Pepe exactamente como lo hace el bucle integrado - eso lee el estado del turno (si la
ejecución ha recibido contenido externo, qué ya se aprobó) desde ese proceso, algo que una
`Task` aislada deliberadamente no puede ver. Fijar un plugin aquí le entrega el turno
*entero*: el gate de permisos, el guardián de bucle y la compactación de contexto son toda
maquinaria propia del bucle integrado, y nada de eso se aplica automáticamente a un turno
que un plugin de harness está conduciendo - uno bien hecho llama él mismo a
`opts[:on_event]` para que una superficie de chat en vivo siga transmitiendo, y puede
llamar a `Pepe.Trace.event/1`/`Pepe.Agent.RunObservers.notify/1` para tener fidelidad
completa de traza/observador si lo desea. Un harness que falla o agota su tiempo devuelve
un error en vez de volver a correr el turno en silencio sobre el bucle integrado - un
harness que ya tomó una acción real (envió una respuesta, corrió una herramienta) por sus
propios medios no debería arriesgarse a hacerlo dos veces.

**Construir uno, paso a paso:**

1. Escribe un módulo que implemente `name/0`, `slot/0` (devolviendo `"harness"`), y
   `run/3`. El ejemplo de abajo delega a un comando externo y devuelve su salida como
   toda la respuesta - el harness real más pequeño posible, en representación de
   "delegar a un CLI de otro agente":

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

   Llamar a `opts[:on_event]` con `{:assistant_delta, content}` es lo que hace que una
   superficie en vivo (el CLI, el chat del panel) muestre de verdad la respuesta a medida
   que llega - ver la nota del moduledoc arriba. Si lo omites, la respuesta igual se
   devuelve correctamente, solo que no se renderiza en vivo en una superficie con
   streaming.

2. Guárdalo como `~/.pepe/plugins/external_cli_harness.exs` e instálalo:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Fija el slot `harness` a él - esta es una decisión más grande que la mayoría de los
   slots, ya que le entrega al plugin el turno entero (ver arriba), así que limitarlo a
   un agente mientras se prueba suele ser el primer paso correcto:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # solo este agente
   pepe slot set harness external_cli_harness                      # cada agente
   ```

4. Pruébalo: `pepe run cli-backed "hello"` nunca llega al modelo en absoluto - la
   respuesta viene directo de `external_cli_harness`.

Un ejemplo mínimo, guardado como `~/.pepe/plugins/example_memory.exs`:

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

El propio marcado de contenido no confiable de la herramienta `web_search` (ver
[Seguridad](/docs/security)) se queda en la herramienta, sin importar qué backend ocupe el
slot - un backend de slot devuelve resultados estructurados simples, no texto; el límite de
confianza se traza una sola vez, en el núcleo.

## Lo que no es un slot

Otros dos puntos de extensión se parecen, pero son aditivos, no exclusivos, porque más de
un ocupante realmente necesita coexistir:

- **Un adaptador de protocolo de modelo** (un plugin que implementa `Pepe.LLM.Adapter` para
  un proveedor cuyo protocolo de chat no es compatible con OpenAI - el mismo papel que ya
  cumplen los adaptadores integrados Responses/Messages) se registra bajo su propio valor
  de `api`; varios protocolos funcionan a la vez, uno por conexión de modelo. Un plugin
  nunca puede sustituir `"openai-responses"` ni `"anthropic-messages"`.
- **Un canal de chat de conexión persistente** (un plugin que implementa
  `Pepe.Gateways.Channel` - para una plataforma como Discord o Matrix que necesita un
  websocket de larga duración, no solo un webhook de entrada) funciona junto a cualquier
  otro canal, incluido Telegram, en su propio dominio de fallos supervisado, para que uno
  que se comporte mal no pueda arrastrar a los demás. Consulta [Plugins](/docs/plugins)
  para el formato basado en webhook `Pepe.Webhooks.Provider`, al que la mayoría de los
  plugins de canal deberían recurrir primero - un canal persistente es para las
  plataformas que un webhook genuinamente no puede cubrir.
- **Un proveedor de audio en tiempo real** (`Pepe.Realtime.Provider`) y **una ruta HTTP
  propia de un plugin** (`Pepe.PluginRoute`) también son ambos aditivos, y ambos se cubren
  en [Plugins](/docs/plugins) - se pueden instalar varios de cualquiera de los dos a la
  vez, y un cliente (o el operador, en el caso de una ruta) elige cuál usar por su nombre,
  a diferencia del ocupante único de un slot.
