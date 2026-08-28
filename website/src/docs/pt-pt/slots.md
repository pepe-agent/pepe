---
title: Slots
description: Deixa um plugin instalado assumir um ponto de extensão exclusivo, como a pesquisa de memória ou a pesquisa web, no lugar do predefinido, com recuperação automática caso se comporte mal.
---

Há trabalhos no Pepe que só podem ter um dono de cada vez: algo tem de ser *a* coisa
que responde a uma pesquisa de memória, ou *o* sítio onde um comando de shell corre.
Um **slot** é exatamente esse tipo de ponto de extensão, com um único ocupante de cada
vez, ao contrário de uma ferramenta ou canal de [plugin](/docs/plugins), onde vários
conseguem coexistir sem problema. A pesquisa de memória é um slot: ou responde a
pesquisa nativa, ou assume um plugin instalado que tenhas nomeado para isso. Nunca os
dois ao mesmo tempo, e nunca uma acumulação silenciosa de vários plugins a responder à
mesma pergunta.

O ocupante nativo não tem código especial nenhum: é só o que fica ativo quando nada
foi configurado. Trocar o ocupante de um slot é sempre uma mudança de configuração,
jamais de código. E se o ocupante configurado falhar, demorar demais, ou devolver
algo malformado, o Pepe recua para o nativo só naquela chamada e regista o que
aconteceu: um ocupante de plugin mal comportado pode baixar a qualidade de uma
resposta, mas nunca chega a partir uma conversa.

## Os slots que existem hoje

| Slot | Ocupante nativo | O que responde |
|---|---|---|
| `memory` | Pesquisa por substring, sem distinguir maiúsculas, em `MEMORY.md`/`USER.md`/`people.md` | A ferramenta `memory_search` |
| `web_search` | A API Instant Answer do DuckDuckGo | A ferramenta `web_search` |
| `sandbox` | Corre diretamente, ou através do script de invólucro configurado (ver [Segurança](/docs/security)) | As ferramentas `bash`/`run_script`: *onde* um comando de shell corre de facto |
| `model_select` | A cadeia estática de `Pepe.Config.model_chain_for_agent/1` | Que cadeia de modelo um turno usa |
| `heartbeat_interval` | Deixa sempre passar um pulso já vencido | Se um pulso de heartbeat do Telegram já vencido tem luz verde para disparar |
| `compaction` | Resume o meio de uma conversa longa com o próprio modelo | Como uma conversa longa é condensada para caber na janela de contexto |
| `harness` | O próprio ciclo de conversa do agente (`Pepe.Agent.Runtime`) | O turno *inteiro*, não uma chamada isolada, o ciclo de raciocínio completo |

Vale destacar um slot antes de fixares seja o que for nele: o `harness`. Um plugin
fixado ali assume a condução da tarefa toda, e age com as próprias permissões da
conversa, por isso só instala um vindo de uma fonte em que confies mesmo. Os detalhes
ficam na secção Harness, mais abaixo.

## Gerir slots

```bash
pepe slot list                 # cada slot, o seu ocupante atual e o seu predefinido
pepe slot set memory NOME      # fixa um slot ao próprio nome de um plugin instalado
pepe slot clear memory         # volta ao nativo
```

O `pepe slot list` assinala como "a usar o predefinido" um ocupante configurado que já
não consegue mesmo responder (foi removido, mudou de nome, ou nunca chegou a
reivindicar o slot). O `pepe doctor` verifica exatamente a mesma coisa, para que uma
definição de slot já obsoleta não passe despercebida.

## Delimitar um slot a um agente ou a um projeto

O `pepe slot set` visto acima fixa um slot para a instalação inteira: todo o agente
recebe o mesmo ocupante. Um agente consegue sobrepor isso só para si:

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

Um projeto também pode definir o seu próprio predefinido para todos os agentes que
tem, no mesmo formato que o `default_hooks` já usa:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

A ordem de resolução é: sobreposição do agente → predefinido do projeto →
configuração de toda a instalação → o nativo. Um agente dentro de um projeto consegue
assim correr um backend de memória diferente de qualquer outro agente ou projeto, sem
forçar uma mudança global que mais ninguém pediu.

## Escrever um plugin de slot

Um plugin reivindica um slot exportando o conjunto de funções desse slot **mais** um
`slot/0`, que devolve o nome exato do slot; é esse o desambiguador, tal como o
`name/0` de uma ferramenta evita que ela seja confundida com outra.

### Memória

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` pode trazer `:limit` e uma dica `:mode` (`:keyword | :vector | :hybrid`); o
nativo ignora `:mode`, mas um backend mais elaborado (um armazém vetorial) fica livre
para a usar. O `index/1` é opcional, pensado para um backend que mantém o seu próprio
armazenamento e precisa de o reconstruir.

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

O `opts` já chega aqui com o `:env` limpo de todo o segredo que o Pepe guarda (vê em
[Segurança](/docs/security) a parte sobre "a shell do agente não herda os segredos do
Pepe"); isto vale seja qual for o ocupante que responder. Este é o único slot em que o
próprio `timeout_ms` por chamada do `bash` (e não o teto generoso de 5 minutos do
slot) é o prazo real para o nativo; um ocupante de plugin deve continuar a responder
depressa mesmo assim, já que o teto do slot é uma rede de segurança, não um orçamento
para gastar até ao fim.

### Seleção de modelo

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

É chamado uma vez por turno (`Pepe.Agent.Runtime.do_run/3`), antes de a cadeia de
modelo ser percorrida, nunca por cada chamada de ferramenta. Devolver `[]` é uma
resposta válida ("nenhum modelo configurado"), não um erro. Um `:model` explícito
passado por quem chamou (um teste fixado, um harness) ignora este slot por completo:
significa exatamente aquele modelo, e não o que uma política de ocupante decidiria
aplicar.

Um uso natural: trocar para um modelo mais barato quando a despesa de um projeto se
aproxima do teto. O `Pepe.Usage.tier/1` devolve `:normal | :low_compute | :critical |
:dead` a partir da mesma proporção que o próprio teto de despesa usa (vê [Utilização e
faturação](/docs/billing)), poupando o ocupante de ter de recalcular isso por conta
própria.

### Ritmo do heartbeat

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

Funciona como mais um veto por cima do calendário estático de `heartbeat_minutes`/hora
de um bot do Telegram, que este slot nunca chega a tocar: só é chamado depois de esse
calendário já ter decidido que um pulso venceu, mesmo antes de ele disparar de facto.
O nativo deixa sempre passar. Um plugin aqui consegue saltar um pulso que já venceu, e
o `Pepe.Usage.tier/1` é o sinal óbvio para isso, por exemplo saltando enquanto um
projeto está em `:critical` ou `:dead`.

### Compactação

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

Um plugin aqui decide como uma conversa longa é condensada para caber na janela de
contexto do modelo, seja uma estratégia de resumo diferente, uma heurística sem LLM
nenhum, o que fizer sentido. Deve devolver sempre `{:ok, messages}`, até quando decide
não condensar nada (o nativo nunca falha de vez; uma falha ou demora excessiva continua
a recuar para o nativo nessa chamada específica).

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `name/0`, `slot/0` (devolvendo `"compaction"`), e
   `compact/4`. O exemplo abaixo é uma estratégia simples, sem LLM: assim que a
   conversa ultrapassa uma certa contagem de mensagens, descarta tudo menos o prompt
   de sistema e as trocas mais recentes, deixando um marcador de uma linha em vez de
   um resumo a sério. Sai mais barato e é instantâneo, ao custo de esquecer mesmo o
   meio da conversa em vez de o condensar.

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
3. Aponta o slot `compaction` para ele, para toda a instalação, ou só para um
   agente ou projeto:

   ```bash
   pepe slot set compaction tail_only_compaction   # todo agente
   pepe agent add support --slots compaction:tail_only_compaction  # só este
   ```

4. Confirma que ficou ativo: o `pepe slot list` mostra o ocupante; uma falha ou demora
   excessiva recua para o nativo nessa chamada, e isso também fica visível ali.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

Este é o único slot que fica sem o isolamento que todos os outros têm: um ocupante de
harness corre no próprio processo do turno, e não numa `Task` supervisionada, porque
precisa de chamar de volta o gate de permissões do Pepe e a execução de ferramentas,
exatamente como o ciclo nativo faz. Esses mecanismos leem o estado do turno (se a
execução já recebeu conteúdo externo, o que já foi aprovado) a partir desse mesmo
processo, algo que uma `Task` isolada, de propósito, não consegue ver. Fixar um
plugin aqui entrega-lhe o turno *inteiro*: o gate de permissões, o loop-guard e a
compactação de contexto são toda a maquinaria do próprio ciclo nativo, e nada disso se
aplica sozinho a um turno que um plugin de harness esteja a conduzir. Um harness
bem-comportado chama ele próprio o `opts[:on_event]`, para que uma superfície de chat
ao vivo continue a fazer streaming, e pode chamar
`Pepe.Trace.event/1`/`Pepe.Agent.RunObservers.notify/1` para ter fidelidade completa
de trace e de observador, se quiser. Um harness que falhe ou exceda o tempo devolve um
erro em vez de voltar a correr o turno silenciosamente no ciclo nativo: um harness que
já tenha tomado uma ação real (enviado uma resposta, corrido uma ferramenta) pelos
seus próprios meios não deve arriscar repeti-la.

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `name/0`, `slot/0` (devolvendo `"harness"`), e
   `run/3`. O exemplo abaixo chama um comando externo e devolve a sua saída como a
   resposta inteira, o harness real mais pequeno possível, e serve de suporte para a
   ideia de "delegar a uma CLI de agente diferente":

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

   Chamar `opts[:on_event]` com `{:assistant_delta, content}` é o que faz uma
   superfície ao vivo (a CLI, o chat do painel) mostrar a resposta de facto à medida
   que ela chega, vê a nota do moduledoc acima. Se saltares esse passo, a resposta
   continua a ser devolvida corretamente, só não aparece em direto numa superfície com
   streaming.

2. Guarda-o como `~/.pepe/plugins/external_cli_harness.exs` e instala-o:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Fixa o slot `harness` a ele. É uma decisão maior do que a maioria dos slots, já
   que entrega ao plugin o turno inteiro (vê acima), por isso limitá-lo a um agente
   enquanto testas costuma ser o primeiro passo certo:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # só este agente
   pepe slot set harness external_cli_harness                      # todo agente
   ```

4. Experimenta: `pepe run cli-backed "hello"` nunca chega sequer ao modelo, a resposta
   vem diretamente do `external_cli_harness`.

Um exemplo mínimo de plugin de slot, guardado como
`~/.pepe/plugins/example_memory.exs`:

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

O próprio envolvimento de conteúdo não fiável que a ferramenta `web_search` já faz
(vê [Segurança](/docs/security)) continua a residir na ferramenta, seja qual for o
backend a ocupar o slot: um backend de slot devolve resultados estruturados simples,
não texto; a fronteira de confiança fica traçada uma única vez, no núcleo.

## O que não é um slot

Há outros dois pontos de extensão parecidos, mas que são aditivos, e não exclusivos,
porque ali faz mesmo sentido ter mais do que um ocupante ao mesmo tempo:

- **Um adaptador de protocolo de modelo** (um plugin que implementa `Pepe.LLM.Adapter`
  para um fornecedor cujo protocolo de chat não é compatível com o da OpenAI, o mesmo
  papel que já cumprem os adaptadores nativos Responses/Messages) regista-se sob o seu
  próprio valor de `api`; vários protocolos funcionam ao mesmo tempo, um por cada
  ligação de modelo. Um plugin nunca consegue substituir `"openai-responses"` nem
  `"anthropic-messages"`.
- **Um canal de chat de ligação persistente** (um plugin que implementa
  `Pepe.Gateways.Channel`, pensado para uma plataforma como Discord ou Matrix que
  precisa de um websocket de longa duração, e não só de um webhook de entrada) corre a
  par de qualquer outro canal, incluindo o Telegram, no seu próprio domínio de falhas
  supervisionado, para que um que se comporte mal não arraste os outros consigo. Vê
  [Plugins](/docs/plugins) para o formato baseado em webhook `Pepe.Webhooks.Provider`,
  que a maioria dos plugins de canal deve preferir à partida; um canal persistente é
  para as plataformas que um webhook genuinamente não consegue cobrir.
- **Um fornecedor de áudio em tempo real** (`Pepe.Realtime.Provider`) e **a rota HTTP
  própria de um plugin** (`Pepe.PluginRoute`) também são ambos aditivos, e ambos ficam
  cobertos em [Plugins](/docs/plugins): dá para instalar vários de qualquer um ao
  mesmo tempo, e é um cliente (ou o operador, no caso de uma rota) quem escolhe qual,
  pelo nome, ao contrário do ocupante único de um slot.
