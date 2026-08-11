---
title: Slots
description: Deixe um plugin instalado assumir um ponto de extensão exclusivo - como a pesquisa de memória ou a pesquisa web - em vez do predefinido, com recuperação automática se se comportar mal.
---

Um **slot** é um ponto de extensão com exatamente um ocupante de cada vez - ao contrário de
uma ferramenta ou canal de [plugin](/docs/plugins), onde vários coexistem. A pesquisa de
memória é um slot: ou responde a pesquisa lexical incorporada, ou um plugin instalado que
nomeou assume - nunca os dois, e nunca uma acumulação silenciosa de vários plugins a
responder à mesma pergunta.

O ocupante incorporado não é código especial; é apenas o predefinido quando nada está
configurado. Trocar o ocupante de um slot é reconfiguração, nunca uma alteração de código -
e se o ocupante configurado falhar, demorar demasiado, ou devolver algo malformado, o Pepe
volta ao incorporado para essa chamada específica e regista-o. Um ocupante de plugin a
comportar-se mal muda a qualidade da resposta; nunca quebra uma conversa.

## Os slots hoje

| Slot | Ocupante incorporado | O que responde |
|---|---|---|
| `memory` | Pesquisa por substring, sem distinguir maiúsculas, em `MEMORY.md`/`USER.md`/`people.md` | A ferramenta `memory_search` |
| `web_search` | A API Instant Answer do DuckDuckGo | A ferramenta `web_search` |
| `sandbox` | Corre diretamente, ou através do script wrapper configurado (ver [Segurança](/docs/security)) | As ferramentas `bash`/`run_script` - *onde* um comando de shell corre de facto |
| `model_select` | A chain estática de `Pepe.Config.model_chain_for_agent/1` | Que chain de modelo um turno usa |
| `heartbeat_interval` | Permite sempre um pulso que já venceu | Se um pulso de heartbeat do Telegram que já venceu pode disparar |
| `compaction` | Resume o meio de uma conversa longa com o próprio modelo | Como uma conversa longa é condensada para caber na janela de contexto |
| `harness` | O próprio ciclo de conversa do agente (`Pepe.Agent.Runtime`) | O turno *inteiro* - não uma chamada, o ciclo de raciocínio completo |

## Gerir slots

```bash
pepe slot list                 # cada slot, o seu ocupante atual e o seu predefinido
pepe slot set memory NOME      # fixa um slot a um plugin instalado, pelo seu próprio nome
pepe slot clear memory         # reverte para o incorporado
```

`pepe slot list` assinala um ocupante configurado que não está a resolver-se de momento
(removido, renomeado, ou que nunca chegou a reivindicar o slot) como "a usar o predefinido
em vez disso" - o mesmo que o `pepe doctor` verifica, para que um slot preso a algo
obsoleto não passe despercebido.

## Delimitar um slot a um agente ou projeto

O `pepe slot set` acima fixa um slot para a instalação inteira - todo o agente recebe o
mesmo ocupante. Um agente pode sobrepor isso para si próprio:

```bash
pepe agent add support --slots memory:example_memory
```

ou diretamente no `config.json`:

```json
{
  "agents": {
    "support": { "slots": { "memory": "example_memory" } }
  }
}
```

Um projeto pode ter o seu próprio predefinido para todo o agente nele, no mesmo formato
que o `default_hooks` já usa:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

A resolução é: sobreposição do agente → predefinido do projeto → configuração da
instalação inteira → o incorporado. Um agente dentro de um projeto pode correr um backend
de memória diferente de todo o outro agente e projeto, sem uma mudança global que mais
ninguém pediu.

## Escrever um plugin de slot

Um plugin reivindica um slot exportando o conjunto de funções do slot **mais** `slot/0`,
devolvendo o nome exato do slot - esse é o desambiguador, tal como o `name/0` de uma
ferramenta evita que seja confundida com outra.

### Memória

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` pode transportar `:limit` e uma dica `:mode` (`:keyword | :vector | :hybrid`) - o
incorporado ignora `:mode`; um backend mais rico (um vector store) é livre de a usar.
`index/1` é opcional, para um backend que mantém o próprio armazenamento e precisa de o
reconstruir.

### Pesquisa web

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

`opts` já chega com o `:env` limpo de todo segredo que o Pepe guarda quando isto corre
(vê em [Segurança](/docs/security) "o shell do agente não herda os segredos do Pepe") -
válido para qualquer ocupante que responda. Este é o único slot onde o próprio
`timeout_ms` por chamada do `bash` (não o teto generoso de 5 minutos do slot) é o prazo
real para o incorporado; um ocupante de plugin deve continuar a responder depressa, já
que o teto do slot é uma rede de segurança, não um orçamento para gastar.

### Seleção de modelo

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

Chamado uma vez por turno (`Pepe.Agent.Runtime.do_run/3`), antes de a chain de modelo ser
percorrida - nunca por tool call. Devolver `[]` é uma resposta válida ("nenhum modelo
configurado"), não malformada. Um `:model` explícito passado pelo chamador (um teste
fixado, um harness) ignora este slot por completo - significa exatamente aquele modelo, não
o que uma política de ocupante aplicaria.

Um uso natural: trocar para um modelo mais barato quando a despesa de um projeto se
aproxima do teto. `Pepe.Usage.tier/1` devolve `:normal | :low_compute | :critical | :dead`
a partir da mesma proporção que o próprio teto de despesa usa (ver [Utilização e faturação](/docs/billing)),
para que um ocupante não precise de recalcular isso.

### Ritmo do heartbeat

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

Mais um veto em cima do próprio calendário estático de `heartbeat_minutes`/horário de um
bot do Telegram, que este slot nunca toca: chamado só depois de esse calendário já ter dito
que um pulso venceu, mesmo antes de disparar de facto. O incorporado permite sempre. Um
plugin aqui pode saltar um pulso que já venceu - `Pepe.Usage.tier/1` é o sinal óbvio, por
exemplo saltar enquanto um projeto está em `:critical` ou `:dead`.

### Compactação

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

Um plugin aqui decide como uma conversa longa é condensada para caber na janela de
contexto do modelo - uma estratégia de sumarização diferente, uma heurística sem LLM, o
que quiser. Deve devolver sempre `{:ok, messages}`, mesmo quando decide não condensar
nada (o incorporado nunca falha de forma definitiva; uma falha ou demora excessiva
continua a degradar-se para o incorporado nessa chamada).

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `name/0`, `slot/0` (devolvendo `"compaction"`), e
   `compact/4`. Abaixo está uma estratégia simples sem LLM: quando a conversa ultrapassa
   uma determinada contagem de mensagens, descarta tudo exceto o prompt de sistema e as
   trocas mais recentes, com um marcador de uma linha em vez de um resumo a sério - mais
   barato e instantâneo, ao custo de esquecer mesmo o meio em vez de o condensar.

   ```elixir
   defmodule TailOnlyCompaction do
     # Não existe um módulo @behaviour dedicado para este slot - name/0, slot/0, compact/4
     # são comparados pelo formato, tal como os plugins de memory/web_search.
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

2. Guarda-o como `~/.pepe/plugins/tail_only_compaction.exs` (ou instala-o de onde
   estiver: `pepe plugin install ./tail_only_compaction.exs`).
3. Aponta o slot `compaction` para ele - para toda a instalação, ou só para um
   agente/projeto:

   ```bash
   pepe slot set compaction tail_only_compaction   # todo agente
   pepe agent add support --slots compaction:tail_only_compaction  # só este
   ```

4. Confirma que está ativo: `pepe slot list` mostra o ocupante; uma falha ou demora
   excessiva volta ao incorporado para essa chamada, e isso também fica visível ali.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

Este é o único slot que não recebe o isolamento que todos os outros têm: um ocupante de
harness corre no próprio processo do turno, não numa `Task` supervisionada, porque
precisa de chamar de volta o gate de permissões do Pepe e a execução de ferramentas
exatamente como o ciclo incorporado faz - esses leem o estado do turno (se a execução já
recebeu conteúdo externo, o que já foi aprovado) a partir desse processo, algo que uma
`Task` isolada deliberadamente não consegue ver. Fixar um plugin aqui entrega-lhe o turno
*inteiro*: o gate de permissões, o loop-guard e a compactação de contexto são toda a
maquinaria do próprio ciclo incorporado, e nada disso se aplica automaticamente a um
turno que um plugin de harness esteja a conduzir - um bem-comportado invoca ele próprio
`opts[:on_event]` para que uma superfície de chat em direto continue a fazer streaming, e
pode invocar `Pepe.Trace.event/1`/`Pepe.Agent.RunObservers.notify/1` para fidelidade
completa de trace/observador se quiser. Um harness que falhe ou exceda o tempo limite
devolve um erro em vez de voltar a correr o turno silenciosamente no ciclo incorporado -
um harness que já tenha tomado uma ação real (enviado uma resposta, corrido uma
ferramenta) pelos seus próprios meios não deve arriscar fazê-lo duas vezes.

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `name/0`, `slot/0` (devolvendo `"harness"`), e
   `run/3`. O exemplo abaixo invoca um comando externo e devolve a sua saída como a
   resposta inteira - o harness real mais pequeno possível, representando "delegar
   para uma CLI de agente diferente":

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

   Invocar `opts[:on_event]` com `{:assistant_delta, content}` é o que faz uma
   superfície em direto (a CLI, o chat do painel) mostrar de facto a resposta à
   medida que chega - vê a nota do moduledoc acima. Omite-o e a resposta continua a
   ser devolvida corretamente, só não é apresentada em direto numa superfície com
   streaming.

2. Guarda-o como `~/.pepe/plugins/external_cli_harness.exs` e instala-o:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Fixa o slot `harness` a ele - é uma decisão maior do que a maioria dos slots, já
   que entrega ao plugin o turno inteiro (vê acima), por isso delimitá-lo a um agente
   enquanto testas costuma ser o primeiro passo certo:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # só este agente
   pepe slot set harness external_cli_harness                      # todo agente
   ```

4. Experimenta: `pepe run cli-backed "hello"` nunca chega sequer ao modelo - a
   resposta vem diretamente de `external_cli_harness`.

Um exemplo mínimo, guardado como `~/.pepe/plugins/example_memory.exs`:

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

A própria marcação de conteúdo não confiável da ferramenta `web_search` (veja
[Segurança](/docs/security)) fica na ferramenta, independentemente do backend que ocupe o
slot - um backend de slot devolve resultados estruturados simples, não texto; a fronteira
de confiança é traçada uma única vez, no núcleo.

## O que não é um slot

Dois outros pontos de extensão parecem-se, mas são aditivos, não exclusivos, porque mais
de um ocupante precisa mesmo de coexistir:

- **Um adaptador de protocolo de modelo** (um plugin que implementa `Pepe.LLM.Adapter` para
  um fornecedor cujo protocolo de chat não é compatível com OpenAI - o mesmo papel que os
  adaptadores incorporados Responses/Messages já desempenham) regista-se sob o seu próprio
  valor de `api`; vários protocolos funcionam ao mesmo tempo, um por ligação de modelo. Um
  plugin nunca consegue substituir `"openai-responses"` nem `"anthropic-messages"`.
- **Um canal de chat de ligação persistente** (um plugin que implementa
  `Pepe.Gateways.Channel` - para uma plataforma como Discord ou Matrix que precisa de um
  websocket de longa duração, não apenas um webhook de entrada) funciona a par de qualquer
  outro canal, incluindo o Telegram, no seu próprio domínio de falhas supervisionado, para
  que um que se comporte mal não consiga arrastar os outros consigo. Veja
  [Plugins](/docs/plugins) para o formato baseado em webhook `Pepe.Webhooks.Provider`, ao
  qual a maioria dos plugins de canal deve recorrer primeiro - um canal persistente é para
  as plataformas que um webhook genuinamente não consegue cobrir.
- **Um fornecedor de áudio em tempo real** (`Pepe.Realtime.Provider`) e **a rota HTTP
  própria de um plugin** (`Pepe.PluginRoute`) são também ambos aditivos, e ambos cobertos em
  [Plugins](/docs/plugins) - vários de qualquer um podem estar instalados ao mesmo tempo, e
  um cliente (ou o operador, no caso de uma rota) escolhe qual pelo nome, ao contrário do
  ocupante único de um slot.
