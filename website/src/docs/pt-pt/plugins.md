---
title: Plugins
description: Amplia o Pepe com ferramentas e canais próprios instalando plugins com a sua própria configuração.
---

Um plugin acrescenta uma **ferramenta** que o modelo pode invocar, um
**fornecedor de canal** (uma nova plataforma de mensagens baseada em
webhook), um **canal de ligação persistente** (um que precisa de um websocket
de longa duração, não apenas um webhook - veja [Slots](/docs/slots)), um
**adaptador de protocolo de modelo**, um **observador de execução** (observa
o ciclo de chamadas a ferramentas de um agente a partir de fora, apenas de
leitura), ou ocupa um [**slot**](/docs/slots) (pesquisa de memória, pesquisa
web) - tudo Elixir compilado em tempo de execução a partir de
`~/.pepe/plugins/`, sem rebuild. Um módulo é comparado com o(s) formato(s)
que implementa; esta página cobre em profundidade os dois primeiros, de
longe os mais comuns, mais um olhar mais breve sobre o observador de
execução mais abaixo.

## O behaviour Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Finalidade |
|---|---|
| `name/0` | O nome de função que o modelo invoca, por exemplo `"read_file"`. Tem de ser único entre todas as ferramentas: em caso de conflito de nome, a ferramenta incorporada prevalece sempre. |
| `spec/0` | A especificação de função ao estilo OpenAI: nome, descrição em linguagem simples e um JSON Schema para os parâmetros. É isto que o modelo lê para decidir quando e como invocar a ferramenta. |
| `run/2` | Executa a chamada. `args` são os argumentos descodificados (um mapa com chaves em texto); `ctx` transporta o contexto da execução atual (abaixo). Devolve `{:ok, text}` ou `{:error, message}`; em qualquer caso é convertido em texto e volta ao modelo, por isso escreve para que o modelo leia. |

O auxiliar `Pepe.Tools.Tool.function/3` constrói o envelope da especificação
por ti, de modo que só preenches o nome, a descrição e os parâmetros.

Uma ferramenta completa e funcional, guarda-a como um `.exs` e instala-a
(ver abaixo):

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

A segunda cláusula de `run/2` é boa prática: se o modelo omitir um argumento
obrigatório, devolve um erro claro em vez de rebentar (um erro fatal também é
capturado, mas uma mensagem à medida ajuda o modelo a recuperar na volta
seguinte).

**`ctx`**, o segundo argumento de `run/2`, transporta a execução atual:
`ctx[:agent]` (o agente em execução, por exemplo `%{name: "assistant"}`),
`ctx[:session_key]` (a conversa em direto, ausente em execuções de um só
turno), `ctx[:cwd]` (o diretório de trabalho). Trata cada chave como
opcional. Ferramentas que leem/escrevem ficheiros resolvem caminhos através
de `Pepe.Agent.Workspace`; as que chamam uma API externa costumam ignorar o
`ctx` por completo e usar diretamente o cliente HTTP `Req` já incluído, sem
dependência extra.

## O behaviour Channel provider

Um fornecedor de canal ensina o Pepe a falar com uma nova plataforma de
mensagens através do webhook de entrada genérico já existente: nenhuma rota
nova, apenas um módulo novo no registo.

```elixir
@callback name() :: String.t()
@callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error
@callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error
@callback parse(payload :: map()) :: {:ok, [inbound]} | :ignore
@callback deliver(config :: map(), to :: String.t(), text :: String.t()) :: :ok | {:error, term()}
```

| Callback | Obrigatório? | Finalidade |
|---|---|---|
| `name/0` | sim | Chave de registo e o segmento `:provider` do URL do webhook, ex. `"whatsapp"`. |
| `verify/2` | sim | Responde ao handshake `GET` da plataforma quando regista o URL do webhook. `{:ok, challenge}` ou `:error` se o fornecedor não tiver nenhum. |
| `authenticate/3` | sim | Verifica a assinatura de um `POST` de entrada face ao segredo da ligação. `:ok` para aceitar, `:error` para descartar. |
| `parse/1` | sim | Normaliza um payload descodificado em zero ou mais mensagens `%{from, text, id}`, ou `:ignore` para o que não tem nada a fazer (recibos, atualizações de estado). |
| `deliver/3` | sim | Envia uma resposta em texto para `to` (um endereço do fornecedor: número de telefone, id de canal, ...). |
| `label/0` | não | Etiqueta humana para o painel (usa `name/0` por predefinição). |
| `config_schema/0` | não | Campos que o painel apresenta para configurar uma ligação, o mesmo formato do array `config` de um manifesto de plugin (abaixo). |
| `respond/3` | não | Uma resposta HTTP **síncrona** ao `POST` em bruto, para protocolos que precisam de uma antes de qualquer trabalho do agente (o desafio de verificação de URL do Slack, o `PING` do Discord). `{:reply, status, content_type, body}` ou `:cont` para cair em `parse/1`. |
| `deliver_file/4` | não | Envia um ficheiro como anexo. Omite-o e o `send_file` simplesmente reporta que o canal não recebe ficheiros. |
| `addressed?/2` | não | Este payload dirige-se ao bot, logo deve receber resposta? Permite que um fornecedor respeite `require_mention` em grupos (predefinição quando omitido: sempre dirigido). |
| `deliver_blocks/3` | não | Renderiza conteúdo estruturado (vê [Blocos de apresentação](#blocos-de-apresentacao) abaixo) na UI nativa da plataforma. Omite-o e a tool `send_presentation` continua a entregar - achatado para texto simples via `deliver/3`. |

### Blocos de apresentação

Uma tool pode enviar conteúdo mais rico que texto simples - uma tabela, uma fila de
botões - através da tool `send_presentation` e do schema de bloco partilhado
`Pepe.Presentation`:

```
%{"type" => "text", "text" => "..."}
%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}
%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}
```

O Slack renderiza isto como Block Kit a sério hoje (uma `section` por bloco de
texto/tabela, um bloco `actions` com botões reais). Um fornecedor que ainda não
adicionou `deliver_blocks/3` continua a receber o conteúdo - `Pepe.Presentation.to_text/1`
achata para texto simples legível, enviado pelo `deliver/3` normal do fornecedor - por
isso uma tool que envia blocos funciona em todo o canal de imediato, de forma rica só
onde um fornecedor se deu ao trabalho de os renderizar.

## O behaviour PluginRoute - a rota HTTP própria de um plugin

O contrato de evento de entrada do `Pepe.Webhooks.Provider` é fixo - um único formato,
para plataformas de chat. O `Pepe.PluginRoute` é para o que precisa do seu próprio: um
callback de redirecionamento OAuth que tem de aterrar no domínio público do próprio Pepe,
um endpoint REST/RPC personalizado.

```elixir
@callback route_prefix() :: String.t()
@callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()
```

`call/2` recebe o `Plug.Conn` em bruto (já passado pelo próprio parsing do corpo do
endpoint) e os segmentos do caminho a seguir ao teu prefixo - controlo total, tal como
qualquer Plug escrito à mão, já que o Pepe não consegue antecipar todos os formatos de
que o protocolo próprio de um plugin possa precisar. Um `call/2` que rebenta responde
`500`, nunca leva consigo o processo do pedido (nem mais nada).

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `route_prefix/0` e `call/2`:

   ```elixir
   defmodule MyPlugin.OAuthCallback do
     @behaviour Pepe.PluginRoute

     @impl true
     def route_prefix, do: "weather_oauth"

     @impl true
     def call(conn, _path) do
       # trata o redirecionamento do fornecedor, troca o código, etc.
       Plug.Conn.send_resp(conn, 200, "connected")
     end
   end
   ```

2. Guarda-o como `~/.pepe/plugins/weather_oauth.exs` e instala-o:
   `pepe plugin install ~/.pepe/plugins/weather_oauth.exs`.
3. **Ativa a rota explicitamente** - reivindicar um prefixo no código não expõe nada
   por si só, é exigido um **segundo opt-in, deliberado**, porque uma rota (ao
   contrário de uma tool) responde a qualquer pedido de entrada, não apenas ao que o
   próprio modelo do agente decidiu fazer:

   ```bash
   pepe plugin route list                 # todo plugin instalado que reivindica uma rota, ativado ou não
   pepe plugin route enable weather_oauth # agora acessível em /plugin-routes/weather_oauth/...
   pepe plugin route disable weather_oauth
   ```

4. Aponta o que precisar de lá chegar (o URL de redirecionamento de uma app OAuth, um
   emissor de webhook) para `https://o-teu-dominio/plugin-routes/weather_oauth/...` -
   os segmentos do caminho a seguir ao prefixo chegam no segundo argumento de `call/2`.

## O behaviour Realtime provider - áudio duplex

Nenhum dos outros pontos de extensão do Pepe mantém um fluxo contínuo e bidirecional -
uma chamada de tool, um webhook, um ocupante de slot são todos de pedido/resposta ou de
uma única vez. O `Pepe.Realtime.Provider` é essa primitiva: um plugin fica responsável
por tudo sobre como o áudio de entrada se torna numa resposta de saída (um modelo
realtime alojado, um pipeline de streaming-STT-depois-TTS), e um novo canal WebSocket
transporta os bytes.

```elixir
@callback name() :: String.t()
@callback start(agent :: map(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}
@callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}
@callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}   # opcional
@callback stop(session :: term()) :: :ok
```

Um cliente junta-se a `realtime:<agent_name>` (`realtime:default` para o agente
predefinido) com `{"provider": "your_provider_name"}` no payload de join, e depois envia
blocos binários no evento `"audio"`. O `sink` de `start/3` é o pid para onde enviar
eventos de volta enquanto a sessão durar: `{:realtime_audio, chunk}`,
`{:realtime_text, text}`, ou `{:realtime_stopped, reason}` se o fornecedor terminar a
sessão por conta própria. Aditivo, não um slot - vários fornecedores podem estar
instalados, e um cliente escolhe um pelo nome por ligação; nada precisa de ser ativado
globalmente como acontece com o `Pepe.PluginRoute`. O Pepe não traz nenhum fornecedor
realtime próprio - este é o ponto de extensão que um plugin preenche.

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `name/0`, `start/3`, `push_audio/2`, `stop/1`, e
   opcionalmente `push_text/2`. O exemplo abaixo é um fornecedor de eco - devolve
   qualquer áudio que receba, mais uma legenda para cada bloco. Suficiente para
   desenvolver um cliente contra ele antes de existir um backend real de STT/TTS ou de
   modelo alojado:

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

   O próprio argumento `sink` de `start/3` serve aqui também como o termo de sessão, já
   que este fornecedor não tem uma ligação/processo real próprio para seguir - um
   fornecedor a falar com um upstream real (um modelo alojado, um pipeline local de
   STT/TTS) devolveria algo que identificasse *isso*, e usaria o `sink` só para enviar
   eventos de volta.

2. Guarda-o como `~/.pepe/plugins/echo_realtime.exs` e instala-o:
   `pepe plugin install ~/.pepe/plugins/echo_realtime.exs`. Nada mais a ativar - um
   fornecedor realtime não tem slot para fixar nem rota para ligar; fica ativo assim
   que é instalado, à espera que um cliente o peça pelo nome.
3. A partir de um cliente, junta-te a `realtime:<agent_name>` no WebSocket já existente
   (`/socket/websocket`), nomeando-o no payload:

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

4. Envia blocos binários no evento `"audio"` assim que estiveres ligado; os eventos
   `{:realtime_audio, ...}`/`{:realtime_text, ...}` voltam da mesma forma que qualquer
   outro push de canal.

## O behaviour Hook - mutação real de conteúdo

Um hook reescreve conteúdo da conversa a sério, no mesmo caminho síncrono e em linha em
que `pii_redact`/`llm_redact`/`http_redact`/`presidio` já correm. É assim que um plugin
de compactação de contexto ou redação de conteúdo faz trabalho real - não confundir com
um run observer (abaixo), que só consegue observar.

```elixir
@callback name() :: String.t()
@callback stages() :: [:inbound | :outbound | :learn | :tool_result]
@callback run(stage, text :: String.t(), settings :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:ok, String.t(), [%{"fake" => String.t(), "real" => String.t()}]}
```

`:inbound` corre no texto do utilizador antes do modelo o ver; `:outbound` na resposta
antes de ser enviada de volta; `:tool_result` na saída em bruto de uma tool antes de
entrar na conversa. Um agente adere a hooks pelo nome (`mix pepe agent add NOME --hooks
o_teu_hook,pii_redact`) - um hook de plugin é aditivo junto aos quatro builtins, e um
builtin ganha sempre num conflito de nome, por isso escolhe um nome distinto de
`pii_redact`/`llm_redact`/`http_redact`/`presidio`.

Os hooks encadeiam: com `--hooks bracket,exclaim`, `exclaim` vê o texto já mutado por
`bracket`, por ordem - sequencial, cada um a ver a saída do anterior, não um fan-out.
Devolve o texto (possivelmente inalterado) e, opcionalmente, uma lista de entradas de mapa
reversível (`fake` um token, `real` o valor que substituiu) se quiseres que sejam
restauradas na saída.

**Fail-open, de propósito**: um hook que levanta uma exceção cai de volta para o texto de
entrada em vez de quebrar o turno. Um hook muta ou redige - nunca bloqueia. Para vetar
uma chamada por completo, vê `Pepe.Permissions.Policy` abaixo, um mecanismo
deliberadamente diferente e mais restrito.

## O behaviour Policy - vetar uma chamada de tool

Um plugin de policy pode recusar uma chamada de tool antes de correr, por uma razão que
só o teu plugin conhece (uma regra da empresa, um serviço de allowlist externo, um
limitador de taxa).

```elixir
@callback name() :: String.t()
@callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

Toda a policy instalada é consultada em **todas** as chamadas de gate, para todos os
agentes - não é opt-in como um hook, já que instalar uma só acrescenta restrição. É
verificada antes da própria lógica de pré-aprovação do Pepe, por isso uma policy pode
vetar até uma chamada que o operador já marcou como aprovada com `:always`. Sem chegar a
uma recusa total, `:ask`/`{:ask, reason}` obriga um humano a olhar para uma chamada que
de outra forma teria sido pré-aprovada silenciosamente - o motivo aparece junto ao
prompt. O mais restritivo vence entre todas as policies instaladas: `:deny` vence `:ask`
vence `:allow`.

**Fail-closed - a única exceção deliberada em todo este sistema de plugins.** Todas as
outras superfícies de plugin no Pepe degradam para "como se não estivesse instalado" num
erro ou timeout. Um plugin de policy é o oposto: um `check/3` que levanta exceção, fica
preso além do timeout, ou devolve qualquer coisa diferente de um `:allow` explícito
**nega a chamada**. Uma verificação de segurança que não conseguiu correr não é a mesma
coisa que uma que passou.

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

"Aplica-se a" ainda pode ser delimitado - pelo operador, nunca pelo próprio agente, o que
anularia o propósito:

```bash
pepe policy list                                      # toda policy instalada + o seu âmbito
pepe policy scope no_bash_policy --agents support --projects acme
pepe policy scope no_bash_policy --clear              # volta a aplicar-se em todo o lado
```

ou diretamente no `config.json` (`"policy_scope"`, pelo nome da policy). Nenhuma entrada
para o nome de uma policy significa sem âmbito - todo o agente, a predefinição e o
comportamento original. Um agente nunca consegue excluir-se a si próprio; só quem
configura o âmbito decide onde uma policy é consultada.

Acrescenta um `check_run/3` opcional para vetar um turno inteiro, antes de qualquer
chamada de tool e antes da primeira chamada ao modelo - a única forma de dizer "não
processes esta mensagem de todo" (um remetente banido, um limite de taxa ao nível da
mensagem), já que `check/3` nunca dispara para um turno que nunca invoca uma tool:

```elixir
@callback check_run(agent :: map(), first_message :: String.t(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

## O behaviour RunObserver

Um observador de execução observa o turno de um agente a partir de fora - útil para
registo, métricas ou alertas sobre o que um agente faz, sem tocar no que faz. É
estritamente de observação: nunca vê o histórico de mensagens da conversa, não pode
bloquear um turno e não pode alterar nada nele, só ficar a saber o que já aconteceu,
depois do facto.

```elixir
@callback name() :: String.t()
@callback subscriptions() :: [atom()]
@callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
```

`subscriptions/0` indica que tipos de evento quer - qualquer um de `:run_start`,
`:tool_call`, `:tool_denied`, `:tool_result`, `:assistant`, `:assistant_delta`,
`:failover`, `:output_cap`, `:usage`, `:inline`, `:done`, `:error`, `:run_end`.
`handle_event/3` é chamado uma vez por cada evento subscrito, pela ordem em que o
turno os produziu. `payload` é o próprio tuplo do evento (ex.: `{:tool_result,
"web_search", "..."}`) - com uma exceção: `:tool_call` chega como `{:tool_call,
name}`, sem os seus argumentos, já que ainda não passaram pela redação e podem
transportar segredos.

Um exemplo mínimo que regista cada chamada a ferramenta e a resposta final:

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

O despacho é assíncrono e isolado: um observador preso ou que rebenta nunca torna a
conversa observada mais lenta nem a quebra. Um que falhe 3 vezes seguidas fica
desativado - em todas as execuções futuras, não apenas na que despoletou o problema -
para que um observador avariado nunca continue a pagar o seu próprio custo de
deteção para sempre, nem inunde os seus registos com a mesma falha. Não há nada para
conceder a um agente aqui: instalado é ativado.

## O registo

`Pepe.Tools.all/0` devolve as ferramentas incorporadas seguidas de cada
ferramenta de plugin carregada; `Pepe.Webhooks` faz o mesmo para fornecedores
de canal. Incorporados e plugins são reunidos num único registo, e os dois
formatos resolvem um conflito de nome de formas opostas. Nas ferramentas, a
incorporada prevalece sempre, por isso escolhe um nome de ferramenta diferente
de `read_file`, `web_search` e do resto de `pepe tools`. Nos fornecedores de
canal, é o plugin com o mesmo nome que prevalece, e é assim que substituis um
fornecedor já incluído pela tua própria versão dele.

### Conceder uma ferramenta a um agente

Instalar um plugin não entrega as suas ferramentas a todos os agentes:
apenas as ferramentas listadas num agente ficam expostas a ele, com o mesmo
controlo de uma incorporada.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Painel:** abre o agente em Agentes e assinala a ferramenta; as ferramentas
de plugin aparecem junto das incorporadas.

**Pela conversa:** um agente com `enable_tool` pode ativar uma ferramenta
para si próprio:

> Tu: ativa a ferramenta reverse_text
>
> Agente: reverse_text ativada; já podes usá-la a partir da tua próxima mensagem

Para conceder uma ferramenta a um agente *diferente*, a ação `add_tool` do
`manage_agent` faz isso (limitada aos agentes que quem pede tem permissão
para gerir, e confirma contigo antes):

> Tu: dá ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirma?

## Onde os plugins vivem e como carregam

Os plugins vivem em `~/.pepe/plugins/` (segue `PEPE_HOME`). O Pepe percorre
essa pasta recursivamente à procura de ficheiros `.exs`, compila cada um uma
vez e só recompila quando a data de modificação muda: larga um ficheiro e
funciona sem reiniciar; edita-o e a alteração aplica-se na chamada de
ferramenta seguinte. Um ficheiro pode definir vários módulos (o exemplo do
Google abaixo traz quatro).

Um plugin tem um de dois formatos: um ficheiro `.exs` solto, ou um
**pacote**: um diretório com um `manifest.json` e um ou mais ficheiros
`.exs`.

Compilar em tempo de execução traz um limite honesto: **um plugin não pode
trazer consigo uma dependência externa nova.** O Elixir resolve e compila as
dependências em tempo de compilação, por isso um plugin só pode usar as
bibliotecas que o Pepe já inclui (`Req`, `Jason`, a biblioteca padrão e o resto
das suas dependências). Um plugin que precise de uma biblioteca inédita não é um
drop-in; isso obrigaria a recompilar o Pepe. Na prática raramente é um entrave,
porque uma ferramenta que chama uma API HTTP e um fornecedor de canal como o
Chatwoot não precisam de nada além do que já vem incluído, e por isso instalam-se
sem problema.

## Instalar um plugin

A fonte é um ficheiro local, um diretório local, um `.tar.gz`, ou um URL para
qualquer um destes, e o `install` desempacota o que lhe deres na pasta de
plugins. Um URL de repositório do GitHub é obtido como o seu arquivo de
código-fonte e extraído, usando o ramo predefinido (`main`, depois `master`)
quando não é indicado nenhum ramo; acrescenta `/tree/<branch>` ao URL para usar
outro. Um `.tar.gz`, local ou remoto, é extraído e o pacote é colocado sob o
`name` do seu manifesto. Um diretório é copiado tal como está, e um `.exs` solto
é copiado diretamente.

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin list
pepe plugin remove google
```

**Painel:** a página de Plugins aceita um URL do GitHub, um URL `.tar.gz` ou
um caminho local; assinala uma caixa a confirmar que confias na fonte e clica
em Instalar. Os plugins instalados aparecem com um botão Remover e, quando o
plugin declara configurações, um botão Configurar.

**Pela conversa, com `manage_plugin`:** um agente com esta ferramenta pode
instalar em teu nome: faz `scan` a uma fonte primeiro para ver o que faz,
depois `install`, `list`, `remove`. Passa pela mesma verificação de segurança
da CLI, mas sem a saída de emergência `--force`: um veredito perigoso é
sempre recusado a partir da conversa, e o agente vai dizer-te para rever o
código e executar `--force` tu mesmo num terminal se ainda assim o
quiseres.

## A verificação de segurança

Um plugin é Elixir comum com acesso total à aplicação em execução; instalar
um é uma decisão de confiança, tal como acrescentar qualquer dependência.
Instala apenas a partir de uma fonte em que confias, e prefere fixar uma versão
ou um commit específico.

Antes de ser colocado em disco, o `Pepe.Skills.Sentinel` verifica o código de
forma estática. Percorre a **árvore sintática** em vez do texto em bruto, por
isso assinala chamadas perigosas com precisão:

- lançar shells (`System.cmd`, `:os.cmd`),
- eval dinâmico (`Code.eval_string`),
- desserialização insegura (`:erlang.binary_to_term`),
- chamadas destrutivas ao sistema de ficheiros (`File.rm_rf`),
- exaustão de átomos (`String.to_atom`),
- leitura do ambiente ou de caminhos com segredos (`~/.ssh`, a configuração do
  Pepe),
- acesso à rede.

Como lê a AST, apanha também as formas com alias e as formas Erlang dessas
chamadas, e não tropeça nas mesmas palavras quando elas aparecem num comentário
ou numa string. Nunca executa o código, e devolve um de três veredictos:

- **limpo**: sem ocorrências.
- **cautela**: assinalado mas muitas vezes legítimo (um plugin de canal
  *deve* fazer chamadas de rede); é mostrado, não bloqueia.
- **perigo**: nenhuma boa razão para lá estar; bloqueia a instalação.

```bash
pepe plugin scan ./my_plugin.exs        # verifica sem instalar
pepe plugin install ./risky.exs --force # avança na mesma, depois de rever
```

<div class="note"><strong>Um plugin corre com acesso total.</strong> A
verificação é uma rede de segurança, não um substituto para ler o código tu
mesmo.</div>

## O manifesto e o diálogo de Configurar

O `manifest.json` de um pacote nomeia-o, descreve-o e, o mais útil,
declara as configurações de que precisa. Do exemplo do Google incluído:

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

Cada entrada de `config` é um campo: `key` (o nome que o teu código lê),
`label` (mostrado no formulário), `type` (`"text"`, `"secret"` para uma
entrada mascarada, ou `"select"` com uma lista `"options"`), e um `hint`
opcional. O painel lê este array e apresenta o diálogo de Configurar; um
plugin novo não precisa de um ecrã novo. Um valor pode ser uma referência
`${ENV_VAR}`, guardada tal como está e resolvida a partir do ambiente só na
leitura, por isso os segredos nunca ficam expandidos no ficheiro de
configuração.

Lê uma configuração guardada a partir do código do teu plugin com
`Pepe.Plugins.config/3` (o nome é o nome do pacote no manifesto; o terceiro
argumento é um valor por omissão):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

Um padrão comum: preferir o valor do painel, recorrendo a uma variável de
ambiente, para que o plugin funcione quer o operador preencha o formulário
quer exporte uma variável (é exatamente o que o exemplo do Google abaixo
faz).

## Exemplo: o plugin de ferramentas Google Workspace

`examples/plugins/google/google.exs` traz quatro ferramentas num único
ficheiro:

| Ferramenta | O que faz |
|------|--------------|
| `gcal_upcoming` | Lista os próximos eventos do Google Calendar principal |
| `gcal_create_event` | Cria um evento (resumo, início, fim, descrição) |
| `gmail_search` | Pesquisa no Gmail e devolve remetente e assunto das correspondências |
| `gmail_send` | Envia um e-mail em texto simples |

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

Autentica-se com um token bearer OAuth2 resolvido no momento da chamada:
nada sensível embutido no código. Exporta um token de acesso pronto (mais
rápido, expira em cerca de 1h):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

ou um refresh token (sobrevive à expiração; o plugin gera um token de acesso
por chamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Obtém estes valores criando um cliente OAuth (tipo "Desktop app") num
projeto do Google Cloud, com as APIs de Calendar e Gmail ativadas, depois de
correr o fluxo de consentimento uma vez para os âmbitos que usas. Ou preenche
os mesmos campos no diálogo de Configurar do plugin, guardando os segredos
como referências `${ENV_VAR}`.

O código completo de uma das ferramentas, mostrando o padrão de ponta a
ponta:

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

> Tu: o que tenho na agenda amanhã, e envia um resumo por e-mail para sam@example.com
>
> Agente: (invoca gcal_upcoming, depois gmail_send) Tens 3 eventos amanhã. Enviei o resumo por e-mail para sam@example.com.

## Exemplo: o plugin de canal Chatwoot

`examples/plugins/chatwoot/` mostra o outro formato: um **canal**, não uma
ferramenta. Regista um fornecedor `chatwoot` para que o Pepe fique atrás de
uma caixa de entrada do [Chatwoot](https://www.chatwoot.com) como o agente de
IA, em todos os canais que o Chatwoot já cobre (WhatsApp, widget web,
Instagram, ...).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Transferência nativa para um humano, sem colagem extra.** O Chatwoot
transporta o sinal de transferência em cada webhook: o `status` da conversa.
O plugin implementa `parse/1` para responder apenas a conversas marcadas
`pending` (controladas pelo bot); no momento em que um atendente humano a
assume (`open`), o Pepe fica em silêncio, e retoma quando volta a `pending`.

**Configuração, no Chatwoot:** cria um AgentBot, aponta o teu webhook de
saída para `https://O_TEU_HOST/webhooks/<project>/chatwoot/<slug>`. A ligação
guarda `base_url`, `account_id` e um `api_token` (como `${ENV_VAR}`) via
`config_schema/0`, preenchidos a partir do painel, o mesmo padrão de
Configurar de qualquer plugin.

> Esta é uma de duas formas mutuamente exclusivas de operar o WhatsApp:
> **ou** WhatsApp direto no Pepe (o fornecedor incorporado `whatsapp`) **ou**
> WhatsApp no Chatwoot com o Pepe por trás (este plugin). Nunca ligues o
> mesmo número a ambos.

## Entregar um ficheiro, não só texto

O `run/2` de uma ferramenta só devolve texto. Para entregar um ficheiro a
sério (uma folha de cálculo, um PDF) à pessoa na conversa, não reinventes a
entrega: invoca a ferramenta incorporada `send_file` com um caminho; o
Pepe resolve o canal a partir da sessão e entrega-o aí. Concede `send_file` a
um agente e simplesmente funciona pela conversa, em qualquer canal cujo
fornecedor implemente `deliver_file/4`.

## Checklist

**Escrever uma ferramenta:**

1. Implementa `name/0`, `spec/0`, `run/2`; dá-lhe um nome diferente de toda
   incorporada.
2. Devolve `{:ok, text}` / `{:error, message}` a partir de `run/2`, escrito
   para o modelo ler.
3. Precisas de credenciais ou opções? Inclui um `manifest.json` com um array
   `config`, lê-as com `Pepe.Plugins.config/3`.

**Escrever um canal:**

1. Implementa `name/0`, `verify/2`, `authenticate/3`, `parse/1`, `deliver/3`;
   acrescenta `config_schema/0` se precisares de credenciais configuradas pelo
   painel.
2. Acrescenta `respond/3` só se o protocolo da plataforma exigir uma resposta
   síncrona antes de qualquer trabalho do agente; `deliver_file/4` só se
   puder receber anexos.

**De qualquer forma:** verifica-o (`pepe plugin scan SRC` ou `manage_plugin
scan`), instala, revê o que a verificação encontrou, e depois concede a
ferramenta a um agente (CLI, painel, ou `enable_tool`/`manage_agent` pela
conversa); um canal não precisa de concessão, fica ativo assim que é
instalado.
