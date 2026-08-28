---
title: Slots
description: Deixe um plugin instalado assumir um ponto de extensão exclusivo, como a busca de memória ou a busca web, no lugar do padrão embutido, com fallback automático caso ele se comporte mal.
---

Existem trabalhos no Pepe que só admitem um dono por vez: algo precisa ser *o*
responsável por responder uma busca de memória, ou *o* lugar onde um comando de shell
roda. Um **slot** é justamente esse tipo de ponto de extensão, com exatamente um
ocupante de cada vez, ao contrário de uma tool ou canal de [plugin](/docs/plugins),
onde vários convivem sem problema. A busca de memória é um slot: ou responde a busca
embutida, ou assume um plugin instalado que você indicou. Nunca os dois juntos, e
nunca um empilhamento silencioso de vários plugins tentando responder a mesma
pergunta.

O ocupante embutido não é um caso especial no código, é simplesmente o padrão quando
nada foi configurado. Trocar o ocupante de um slot é sempre reconfiguração, jamais
mudança de código, e se o ocupante configurado travar, demorar demais ou devolver algo
malformado, o Pepe volta para o embutido naquela chamada específica e registra o
ocorrido. Um ocupante de plugin com mau comportamento pode piorar a qualidade de uma
resposta pontual, mas nunca chega a quebrar uma conversa inteira.

## Os slots de hoje

| Slot | Ocupante embutido | O que ele responde |
|---|---|---|
| `memory` | Busca por substring, sem diferenciar maiúsculas, em `MEMORY.md`/`USER.md`/`people.md` | A tool `memory_search` |
| `web_search` | API Instant Answer do DuckDuckGo | A tool `web_search` |
| `sandbox` | Roda direto, ou pelo script wrapper configurado (veja [Segurança](/docs/security)) | As tools `bash`/`run_script`: *onde* um comando shell de fato roda |
| `model_select` | A chain estática de `Pepe.Config.model_chain_for_agent/1` | Qual chain de modelo um turno usa |
| `heartbeat_interval` | Sempre permite um pulso já vencido | Se um pulso de heartbeat do Telegram já vencido pode disparar |
| `compaction` | Resume o meio de uma conversa longa usando o próprio modelo | Como uma conversa longa é condensada para caber na janela de contexto |
| `harness` | O próprio loop de conversa do agente (`Pepe.Agent.Runtime`) | O turno *inteiro*, não uma chamada isolada, o loop de raciocínio completo |

Antes de fixar qualquer coisa nele, vale um parágrafo à parte sobre um slot em
específico: `harness`. Um plugin fixado ali passa a conduzir a tarefa inteira, e age
com as permissões da própria conversa, então só instale um vindo de uma fonte em que
você realmente confia. Os detalhes vêm na seção Harness, mais abaixo.

## Gerenciando slots

```bash
pepe slot list                 # todo slot, seu ocupante atual e seu padrão
pepe slot set memory NOME      # fixa um slot num plugin instalado, pelo próprio nome dele
pepe slot clear memory         # volta pro embutido
```

Quando um ocupante configurado não consegue mais responder de verdade (foi removido,
renomeado, ou nunca chegou a reivindicar o slot), `pepe slot list` sinaliza isso como
"usando o padrão em vez disso". O `pepe doctor` verifica exatamente a mesma coisa, o
que evita que um slot preso a algo obsoleto passe despercebido por muito tempo.

## Restringindo um slot a um agente ou projeto

O `pepe slot set` visto acima fixa um slot para a instalação inteira: todo agente
passa a ter o mesmo ocupante. Um agente específico pode sobrescrever isso para si:

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

Um projeto também pode definir seu próprio padrão para todos os agentes dentro dele,
no mesmo formato que `default_hooks` já usa:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

A ordem de resolução é: sobrescrita do agente, depois padrão do projeto, depois a
configuração da instalação inteira, e por fim o embutido. Isso permite que um único
agente dentro de um projeto rode um backend de memória diferente de todo o resto, sem
forçar uma mudança global que ninguém mais pediu.

## Escrevendo um plugin de slot

Um plugin reivindica um slot exportando o conjunto de funções daquele slot **mais** a
função `slot/0`, que devolve o nome exato do slot: é esse o desambiguador, no mesmo
papel que o `name/0` de uma tool cumpre para evitar confusão com outra.

### Memória

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` pode trazer `:limit` e uma dica `:mode` (`:keyword | :vector | :hybrid`). O
embutido simplesmente ignora `:mode`, mas um backend mais sofisticado, como um vector
store, é livre para levá-la em conta. `index/1` é opcional, reservada para um backend
que mantém o próprio armazenamento e precisa reconstruí-lo de tempos em tempos.

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

Quando isso roda, `opts` já chega com o `:env` limpo de todo segredo que o Pepe
guarda (veja em [Segurança](/docs/security) o trecho sobre "o shell do agente não
herda os segredos do Pepe"); isso vale para qualquer ocupante que assuma o slot. Este
é o único slot em que o próprio `timeout_ms` por chamada do `bash` (e não o teto
generoso de 5 minutos do slot) funciona como o prazo real para o embutido; um
ocupante de plugin também deve responder rápido, já que o teto do slot é uma rede de
segurança, não um orçamento de tempo para gastar.

### Seleção de modelo

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

É chamado uma vez por turno (`Pepe.Agent.Runtime.do_run/3`), antes de a chain de
modelo ser percorrida, nunca a cada chamada de tool. Devolver `[]` é uma resposta
válida ("nenhum modelo configurado"), não uma resposta malformada. Um `:model`
explícito passado pelo chamador (um teste fixado, um harness) ignora esse slot por
completo: significa exatamente aquele modelo, não o que a política de algum ocupante
decidiria aplicar.

Um uso natural para isso: trocar para um modelo mais barato assim que o gasto de um
projeto se aproxima do teto. `Pepe.Usage.tier/1` já informa `:normal | :low_compute |
:critical | :dead`, a partir da mesma proporção usada pelo próprio teto de gasto (veja
[Uso e cobrança](/docs/billing)), então um ocupante não precisa recalcular nada disso
por conta própria.

### Ritmo do heartbeat

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

Funciona como mais um veto por cima do próprio calendário estático de
`heartbeat_minutes`/horário de um bot do Telegram, calendário esse que esse slot nunca
chega a tocar: ele só é chamado depois que esse calendário já decidiu que um pulso
venceu, um instante antes de ele de fato disparar. O embutido sempre permite. Já um
plugin aqui pode pular um pulso mesmo já vencido; `Pepe.Usage.tier/1` é o sinal mais
óbvio para isso, por exemplo pulando enquanto um projeto está em `:critical` ou
`:dead`.

### Compactação

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

Um plugin nesse slot decide como uma conversa longa é condensada para caber na janela
de contexto do modelo: pode ser uma estratégia de resumo diferente, uma heurística sem
LLM nenhum, o que fizer sentido. Deve sempre devolver `{:ok, messages}`, mesmo quando
decide não condensar nada (o embutido nunca falha de vez; uma quebra ou timeout ainda
faz o sistema recorrer ao embutido só naquela chamada).

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `name/0`, `slot/0` (devolvendo `"compaction"`) e
   `compact/4`. O exemplo abaixo é uma estratégia simples, sem LLM: assim que a
   conversa ultrapassa uma certa contagem de mensagens, descarta tudo menos o system
   prompt e as trocas mais recentes, deixando só um marcador de uma linha no lugar de
   um resumo de verdade. Mais barato e instantâneo, ao custo de esquecer o meio da
   conversa de fato, em vez de condensá-lo.

   ```elixir
   defmodule TailOnlyCompaction do
     # Nenhum módulo @behaviour dedicado é distribuído para esse slot: name/0, slot/0 e
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

2. Salve como `~/.pepe/plugins/tail_only_compaction.exs` (ou instale de onde ele
   estiver: `pepe plugin install ./tail_only_compaction.exs`).
3. Aponte o slot `compaction` para ele, seja para a instalação inteira ou só para um
   agente ou projeto específico:

   ```bash
   pepe slot set compaction tail_only_compaction   # todo agente
   pepe agent add support --slots compaction:tail_only_compaction  # só esse aqui
   ```

4. Confirme que está no ar: `pepe slot list` mostra o ocupante em uso; uma quebra ou
   timeout faz o sistema voltar ao embutido naquela chamada, e isso também fica
   visível ali.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # sempre "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

Esse é o único slot que fica sem o isolamento que todos os outros ganham: um ocupante
de harness roda dentro do próprio processo do turno, não numa `Task` supervisionada,
porque ele precisa chamar de volta a barreira de permissão e a execução de
ferramentas do próprio Pepe, exatamente como o loop embutido faz. Isso porque essas
duas coisas leem o estado do turno (se a execução recebeu conteúdo externo, o que já
foi aprovado) diretamente daquele processo, algo que uma `Task` isolada
deliberadamente não teria como enxergar. Fixar um plugin aqui entrega a ele o turno
*inteiro*: a barreira de permissão, a trava contra loops e a compactação de contexto
são todos maquinário do próprio loop embutido, e nada disso vale automaticamente para
um turno que um plugin de harness está conduzindo. Um harness bem-comportado chama
`opts[:on_event]` por conta própria, para que uma superfície de chat ao vivo continue
transmitindo normalmente, e pode chamar `Pepe.Trace.event/1`/
`Pepe.Agent.RunObservers.notify/1` se quiser fidelidade completa de trace e
observadores. Um harness que quebra ou estoura o tempo devolve um erro em vez de
silenciosamente rodar o turno de novo pelo loop embutido; afinal, um harness que já
tomou uma ação real por conta própria (mandou uma resposta, rodou uma tool) não
deveria correr o risco de fazer isso duas vezes.

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `name/0`, `slot/0` (devolvendo `"harness"`) e
   `run/3`. O exemplo abaixo chama um comando externo via shell e devolve a saída dele
   como a resposta inteira, o menor harness real possível, no papel de "delegar para
   uma CLI de agente diferente":

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
   superfície ao vivo (a CLI, o chat do painel) mostrar a resposta de fato conforme
   ela chega, exatamente como diz a nota do moduledoc acima. Pular esse passo não
   quebra nada, a resposta ainda volta corretamente, só que deixa de renderizar ao
   vivo numa superfície com streaming.

2. Salve como `~/.pepe/plugins/external_cli_harness.exs` e instale:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Fixe o slot `harness` nesse plugin. Essa é uma decisão mais pesada que a maioria
   dos slots, já que entrega o turno inteiro ao plugin (como visto acima), então
   restringir a um único agente enquanto se testa costuma ser o primeiro passo mais
   sensato:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # só esse agente
   pepe slot set harness external_cli_harness                      # todo agente
   ```

4. Teste: `pepe run cli-backed "hello"` nunca chega a alcançar o modelo, a resposta
   vem direto de `external_cli_harness`.

Um exemplo mínimo de plugin de slot, salvo como `~/.pepe/plugins/example_memory.exs`:

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
[Segurança](/docs/security)) continua residindo na tool, não importa qual backend
esteja ocupando o slot: um backend de slot devolve resultados estruturados simples,
não texto pronto, então a fronteira de confiança é traçada uma única vez, no core.

## O que não é um slot

Existem outros dois pontos de extensão parecidos na superfície, mas que funcionam de
forma aditiva, não exclusiva, justamente porque mais de um ocupante precisa mesmo
conviver ao mesmo tempo:

- **Um adaptador de protocolo de modelo** (um plugin que implementa `Pepe.LLM.Adapter` para um provedor cujo protocolo de chat não é compatível com OpenAI, cumprindo o mesmo papel que os adaptadores embutidos Responses/Messages já cumprem) se registra sob seu próprio valor de `api`, e vários protocolos rodam ao mesmo tempo, um por conexão de modelo. Um plugin nunca consegue substituir `"openai-responses"` nem `"anthropic-messages"`.
- **Um canal de chat com conexão persistente** (um plugin que implementa `Pepe.Gateways.Channel`, pensado para uma plataforma como Discord ou Matrix, que precisa de um websocket de longa duração em vez de um simples webhook de entrada) roda junto de qualquer outro canal, incluindo o Telegram, dentro do próprio domínio de falha supervisionado, de modo que um canal com problema não derruba os demais junto. Veja [Plugins](/docs/plugins) para o formato baseado em webhook, `Pepe.Webhooks.Provider`, que deveria ser a primeira opção da maioria dos plugins de canal; um canal persistente serve para as plataformas que um webhook realmente não consegue cobrir.
- **Um provedor de áudio em tempo real** (`Pepe.Realtime.Provider`) e **uma rota HTTP própria de um plugin** (`Pepe.PluginRoute`) também são aditivos, e ambos estão detalhados em [Plugins](/docs/plugins): dá para ter vários de qualquer um dos dois instalados ao mesmo tempo, e quem escolhe qual usar, pelo nome, é o próprio cliente (ou o operador, no caso de uma rota), diferente do ocupante único e exclusivo de um slot.
