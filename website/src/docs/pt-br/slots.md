---
title: Slots
description: Deixe um plugin instalado assumir um ponto de extensão exclusivo - como a busca de memória ou a busca web - no lugar do padrão, com fallback automático se ele se comportar mal.
---

Um **slot** é um ponto de extensão com exatamente um ocupante por vez, diferente de uma
tool ou canal de [plugin](/docs/plugins), onde vários convivem juntos. A busca de memória é
um slot: ou a busca textual embutida responde, ou um plugin instalado que você nomeou
assume; nunca os dois, e nunca um empilhamento silencioso de vários plugins respondendo à
mesma pergunta.

O ocupante embutido não é código especial; é só o padrão quando nada está configurado.
Trocar o ocupante de um slot é reconfiguração, nunca uma mudança de código, e se o
ocupante configurado travar, demorar demais ou devolver algo malformado, o Pepe cai de
volta para o embutido naquela chamada específica e registra isso. Um ocupante de plugin se
comportando mal muda a qualidade da resposta; nunca quebra uma conversa.

## Os slots hoje

| Slot | Ocupante embutido | O que responde |
|---|---|---|
| `memory` | Busca por substring, sem diferenciar maiúsculas, em `MEMORY.md`/`USER.md`/`people.md` | A tool `memory_search` |
| `web_search` | API Instant Answer do DuckDuckGo | A tool `web_search` |
| `sandbox` | Roda direto, ou pelo script wrapper configurado (veja [Segurança](/docs/security)) | As tools `bash`/`run_script`, *onde* um comando shell roda de fato |
| `model_select` | A chain estática de `Pepe.Config.model_chain_for_agent/1` | Qual chain de modelo um turno usa |
| `heartbeat_interval` | Sempre permite um pulso que já venceu | Se um pulso de heartbeat do Telegram que já venceu pode disparar |
| `compaction` | Resume o meio de uma conversa longa com o próprio modelo | Como uma conversa longa é condensada para caber na janela de contexto |
| `harness` | O próprio loop de conversa do agente (`Pepe.Agent.Runtime`) | O turno *inteiro*: não uma chamada, o loop de raciocínio inteiro |

## Gerenciando slots

```bash
pepe slot list                 # todo slot, seu ocupante atual e seu padrão
pepe slot set memory NOME      # fixa um slot num plugin instalado, pelo próprio nome dele
pepe slot clear memory         # volta pro embutido
```

`pepe slot list` sinaliza um ocupante configurado que não está resolvendo no momento
(removido, renomeado, ou nunca reivindicou o slot de fato) como "usando o padrão em vez
disso", a mesma coisa que o `pepe doctor` verifica, então um slot preso a algo obsoleto
não passa despercebido.

## Escopando um slot para um agente ou projeto

O `pepe slot set` acima fixa um slot para a instalação inteira: todo agente recebe o mesmo
ocupante. Um agente pode sobrescrever isso para si mesmo:

```bash
pepe agent add support --slots memory:example_memory
```

ou direto no `config.json`:

```json
{
  "agents": {
    "support": { "slots": { "memory": "example_memory" } }
  }
}
```

Um projeto pode ter seu próprio padrão para todo agente nele, no mesmo formato que o
`default_hooks` já usa:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

A resolução é: sobrescrita do agente → padrão do projeto → configuração da instalação
inteira → o embutido. Um agente dentro de um projeto pode rodar um backend de memória
diferente de todo outro agente e projeto, sem uma mudança global que ninguém mais pediu.

## Escrevendo um plugin de slot

Um plugin reivindica um slot exportando o conjunto de funções do slot **mais** `slot/0`,
devolvendo o nome exato do slot: esse é o desambiguador, do mesmo jeito que o `name/0` de
uma tool evita que ela seja confundida com outra.

### Memória

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` pode carregar `:limit` e uma dica `:mode` (`:keyword | :vector | :hybrid`), o
embutido ignora `:mode`; um backend mais rico (um vector store) é livre para usá-la.
`index/1` é opcional, para um backend que mantém o próprio armazenamento e precisa
reconstruí-lo.

### Busca web

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "web_search"
@callback search(query :: String.t(), opts :: keyword()) ::
            {:ok, [%{title: String.t() | nil, url: String.t() | nil, snippet: String.t()}]} |
            {:error, term()}
```

### Sandbox

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "sandbox"
@callback run(program :: String.t(), argv :: [String.t()], opts :: keyword()) ::
            {:ok, {output :: String.t(), exit_status :: non_neg_integer()}} | {:error, term()}
```

`opts` já chega com o `:env` limpo de todo segredo que o Pepe guarda quando isso roda
(veja em [Segurança](/docs/security) "o shell do agente não herda os segredos do
Pepe"), vale para qualquer ocupante que responda. Esse é o único slot onde o próprio
`timeout_ms` por chamada do `bash` (não o teto generoso de 5 minutos do slot) é o prazo
real para o embutido; um ocupante de plugin ainda deve responder rápido, já que o teto do
slot é uma rede de segurança, não um orçamento para gastar.

### Seleção de modelo

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

Chamado uma vez por turno (`Pepe.Agent.Runtime.do_run/3`), antes da chain de modelo ser
percorrida, nunca por tool call. Devolver `[]` é uma resposta válida ("nenhum modelo
configurado"), não malformada. Um `:model` explícito passado pelo chamador (um teste
fixado, um harness) ignora esse slot por completo: significa exatamente aquele modelo, não
o que uma política de ocupante aplicaria.

Um uso natural: trocar para um modelo mais barato quando o gasto de um projeto se aproxima
do teto. `Pepe.Usage.tier/1` informa `:normal | :low_compute | :critical | :dead` a partir
da mesma proporção que o próprio teto de gasto usa (veja [Uso e cobrança](/docs/billing)),
então um ocupante não precisa recalcular isso.

### Ritmo do heartbeat

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

Mais um veto em cima do próprio calendário estático de `heartbeat_minutes`/horário de um
bot do Telegram, que esse slot nunca toca: chamado só depois que esse calendário já disse
que um pulso venceu, bem antes dele disparar de fato. O embutido sempre permite. Um plugin
aqui pode pular um pulso que já venceu; `Pepe.Usage.tier/1` é o sinal óbvio, por exemplo
pular enquanto um projeto está em `:critical` ou `:dead`.

### Compactação

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

Um plugin aqui decide como uma conversa longa é condensada para caber na janela de contexto
do modelo: uma estratégia de resumo diferente, uma heurística sem LLM, o que quiser. Deve
sempre devolver `{:ok, messages}`, mesmo quando decidir não condensar nada (o embutido nunca
falha de vez; uma quebra/timeout ainda degrada para o embutido naquela chamada).

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `name/0`, `slot/0` (devolvendo `"compaction"`), e
   `compact/4`. Abaixo, uma estratégia simples sem LLM: quando a conversa passa de uma
   contagem de mensagens, descarta tudo menos o system prompt e as trocas mais recentes,
   com um marcador de uma linha em vez de um resumo de verdade, mais barato e instantâneo,
   ao custo de esquecer o meio de fato em vez de condensá-lo.

   ```elixir
   defmodule TailOnlyCompaction do
     # Nenhum módulo @behaviour dedicado é distribuído pra esse slot - name/0, slot/0,
     # compact/4 são casados pelo formato, do mesmo jeito que os plugins de memory/web_search.
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

2. Salve como `~/.pepe/plugins/tail_only_compaction.exs` (ou instale de onde ele estiver:
   `pepe plugin install ./tail_only_compaction.exs`).
3. Aponte o slot `compaction` para ele: para a instalação inteira, ou só para um agente/projeto:

   ```bash
   pepe slot set compaction tail_only_compaction   # todo agente
   pepe agent add support --slots compaction:tail_only_compaction  # só esse aqui
   ```

4. Confirme que está ativo: `pepe slot list` mostra o ocupante; uma quebra ou timeout cai
   de volta para o embutido naquela chamada, e isso também fica visível ali.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

Esse é o único slot que não ganha o isolamento que todo outro ganha: um ocupante de harness
roda no próprio processo do turno, não numa `Task` supervisionada, porque precisa chamar de
volta o próprio portão de permissão e a execução de ferramentas do Pepe exatamente como o
loop embutido faz: eles leem o estado do turno (se a execução recebeu conteúdo externo, o
que já foi aprovado) daquele processo, algo que uma `Task` isolada deliberadamente não
consegue ver. Fixar um plugin aqui entrega a ele o turno *inteiro*: o portão de permissão, a
trava de loop e a compactação de contexto são todos maquinário do próprio loop embutido, e
nada disso se aplica automaticamente a um turno que um plugin de harness está conduzindo;
um bem-comportado chama `opts[:on_event]` por conta própria para que uma superfície de chat
ao vivo continue transmitindo, e pode chamar `Pepe.Trace.event/1`/
`Pepe.Agent.RunObservers.notify/1` para ter fidelidade total de trace/observador se quiser.
Um harness que quebra ou estoura o tempo devolve um erro em vez de silenciosamente rodar o
turno de novo no loop embutido; um harness que já tomou uma ação real (mandou uma resposta,
rodou uma tool) por conta própria não deveria arriscar fazer isso duas vezes.

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `name/0`, `slot/0` (devolvendo `"harness"`), e `run/3`.
   O exemplo abaixo chama um comando externo via shell e devolve a saída dele como a
   resposta inteira, o menor harness real possível, no lugar de "delegar para uma CLI de
   agente diferente":

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

   Chamar `opts[:on_event]` com `{:assistant_delta, content}` é o que faz uma superfície
   ao vivo (a CLI, o chat do painel) mostrar a resposta de fato conforme ela chega, veja
   a nota do moduledoc acima. Pule isso e a resposta ainda volta corretamente, só que não
   vai renderizar ao vivo numa superfície de streaming.

2. Salve como `~/.pepe/plugins/external_cli_harness.exs` e instale:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Fixe o slot `harness` nele: essa é uma decisão maior que a maioria dos slots, já que
   entrega ao plugin o turno inteiro (veja acima), então escopar para um agente só enquanto
   testa costuma ser o primeiro passo certo:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # só esse agente
   pepe slot set harness external_cli_harness                      # todo agente
   ```

4. Teste: `pepe run cli-backed "hello"` nunca chega no modelo de jeito nenhum; a resposta
   vem direto do `external_cli_harness`.

Um exemplo mínimo, salvo como `~/.pepe/plugins/example_memory.exs`:

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

A própria marcação de conteúdo não confiável da tool `web_search` (veja
[Segurança](/docs/security)) fica na tool, não importa qual backend ocupe o slot: um
backend de slot devolve resultados estruturados simples, não texto; a fronteira de
confiança é traçada uma vez só, no core.

## O que não é um slot

Dois outros pontos de extensão parecem similares, mas são aditivos, não exclusivos, porque
mais de um ocupante realmente precisa conviver:

- **Um adaptador de protocolo de modelo** (um plugin implementando `Pepe.LLM.Adapter` para
  um provedor cujo protocolo de chat não é compatível com OpenAI, o mesmo papel que os
  adaptadores embutidos Responses/Messages já cumprem) se registra sob seu próprio valor de
  `api`; vários protocolos rodam ao mesmo tempo, um por conexão de modelo. Um plugin nunca
  consegue substituir `"openai-responses"` ou `"anthropic-messages"`.
- **Um canal de chat de conexão persistente** (um plugin implementando
  `Pepe.Gateways.Channel` para uma plataforma como Discord ou Matrix que precisa de um
  websocket de longa duração, não só um webhook de entrada) roda junto de todo outro canal,
  incluindo o Telegram, no próprio domínio de falha supervisionado, para um que se comporte
  mal não conseguir derrubar os outros junto. Veja [Plugins](/docs/plugins) para o formato
  baseado em webhook `Pepe.Webhooks.Provider`, que a maioria dos plugins de canal deveria
  buscar primeiro; um canal persistente é para as plataformas que um webhook genuinamente não
  cobre.
- **Um provedor de áudio em tempo real** (`Pepe.Realtime.Provider`) e **uma rota HTTP
  própria de um plugin** (`Pepe.PluginRoute`) também são aditivos, e ambos estão cobertos em
  [Plugins](/docs/plugins): vários de qualquer um dos dois podem estar instalados ao mesmo
  tempo, e um cliente (ou o operador, no caso de uma rota) escolhe qual pelo nome, diferente
  do ocupante único de um slot.
