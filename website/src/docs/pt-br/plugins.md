---
title: Plugins
description: Estenda o Pepe com ferramentas e canais próprios instalando plugins com sua própria configuração.
---

Um plugin é um arquivo que você instala para ensinar algo novo ao Pepe, sem
rebuild e sem reiniciar: solte o arquivo lá e ele funciona. A maioria dos
plugins faz uma de duas coisas: adiciona uma **ferramenta** que o modelo pode
chamar, ou adiciona um **provedor de canal** (uma nova plataforma de mensagens
baseada em webhook). Esta página cobre esses dois formatos em profundidade, de
longe os mais comuns, além de olhares mais breves sobre os demais abaixo.

Um plugin também pode tomar outros formatos: um **canal de conexão
persistente** (um que precisa de um websocket de longa duração, não só um
webhook, veja [Slots](/docs/slots)), uma **rota HTTP própria** (um callback de
OAuth, um endpoint personalizado, veja abaixo), um **provedor de áudio em tempo
real** (voz duplex, veja abaixo), um **adaptador de protocolo de modelo**, um
**hook** (reescreve o conteúdo da conversa de verdade, encadeado e inline, veja
abaixo), uma **policy** (veta uma chamada de tool, ou uma execução inteira,
antes de acontecer; uma checagem que não conseguiu rodar conta como recusa,
então falha fechada), ou um **observador de execução** (observa o loop de fora,
somente leitura, o único formato que não pode afetar nada). Um plugin também
pode ocupar um [**slot**](/docs/slots): busca de memória, busca web, o sandbox
onde um comando shell roda, a compactação de conversa, ou o loop de raciocínio
inteiro.

Por baixo dos panos, todo plugin é Elixir compilado em tempo de execução a
partir de `~/.pepe/plugins/`, e um módulo é comparado com o(s) formato(s) que
ele implementa.

## O behaviour Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Finalidade |
|---|---|
| `name/0` | O nome de função que o modelo chama, por exemplo `"read_file"`. Precisa ser único entre todas as ferramentas; em caso de conflito de nome com uma ferramenta embutida, a embutida sempre prevalece. |
| `spec/0` | A especificação de função no estilo OpenAI: nome, descrição em linguagem simples e um JSON Schema para os parâmetros. É isso que o modelo lê para decidir quando e como chamar a ferramenta. |
| `run/2` | Executa a chamada. `args` são os argumentos decodificados (um mapa com chaves em string); `ctx` carrega o contexto da execução atual (abaixo). Devolva `{:ok, text}` ou `{:error, message}`; de qualquer forma vira uma string e volta ao modelo, então escreva para que o modelo leia. |

`Pepe.Tools.Tool.function/3` monta o envelope da especificação para você, então
você só preenche o nome, a descrição e os parâmetros.

Uma ferramenta completa e funcional. Salve como um `.exs` e instale (veja
abaixo):

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

A segunda cláusula de `run/2` é uma boa prática: se o modelo omitir um
argumento obrigatório, devolva um erro claro em vez de quebrar (uma quebra
também é capturada, mas uma mensagem sob medida ajuda o modelo a se recuperar
na próxima rodada).

**`ctx`**, o segundo argumento de `run/2`, carrega a execução atual:
`ctx[:agent]` (o agente em execução, por exemplo `%{name: "assistant"}`),
`ctx[:session_key]` (a conversa ao vivo, ausente em execuções de um turno só),
`ctx[:cwd]` (o diretório de trabalho). Trate cada chave como opcional.
Ferramentas que leem/escrevem arquivos resolvem caminhos via
`Pepe.Agent.Workspace`; ferramentas que chamam uma API externa costumam
ignorar `ctx` por completo e usar direto o cliente HTTP `Req` já incluso, sem
dependência extra.

## O behaviour Channel provider

Um provedor de canal ensina o Pepe a falar uma nova plataforma de mensagens
sobre o webhook de entrada genérico já existente: nenhuma rota nova, só um
módulo novo no registro.

```elixir
@callback name() :: String.t()
@callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error
@callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error
@callback parse(payload :: map()) :: {:ok, [inbound]} | :ignore
@callback deliver(config :: map(), to :: String.t(), text :: String.t()) :: :ok | {:error, term()}
```

| Callback | Obrigatório? | Finalidade |
|---|---|---|
| `name/0` | sim | Chave de registro e o segmento `:provider` da URL do webhook, ex. `"whatsapp"`. |
| `verify/2` | sim | Responde o handshake `GET` da plataforma quando você registra a URL do webhook. `{:ok, challenge}` ou `:error` se o provedor não tiver um. |
| `authenticate/3` | sim | Confere a assinatura de um `POST` de entrada contra o segredo da conexão. `:ok` para aceitar, `:error` para descartar. |
| `parse/1` | sim | Normaliza um payload decodificado em zero ou mais mensagens `%{from, text, id}`, ou `:ignore` para o que não exige nenhuma ação (recibos, atualizações de status). |
| `deliver/3` | sim | Envia uma resposta em texto para `to` (um endereço do provedor: número de telefone, id de canal, ...). |
| `label/0` | não | Rótulo humano para o painel (usa `name/0` por padrão). |
| `config_schema/0` | não | Campos que o painel renderiza para configurar uma conexão, mesmo formato do array `config` de um manifesto de plugin (abaixo). |
| `respond/3` | não | Uma resposta HTTP **síncrona** ao `POST` bruto, para protocolos que precisam de uma antes de qualquer trabalho do agente (o desafio de verificação de URL do Slack, o `PING` do Discord). `{:reply, status, content_type, body}` ou `:cont` para cair em `parse/1`. |
| `deliver_file/4` | não | Envia um arquivo como anexo. Omita e o `send_file` simplesmente reporta que o canal não recebe arquivos. |
| `addressed?/2` | não | Esse payload se dirige ao bot, então deve receber resposta? Permite que um provedor honre `require_mention` em grupos (padrão quando omitido: sempre endereçado). |
| `deliver_blocks/3` | não | Renderiza conteúdo estruturado (veja [Blocos de apresentação](#blocos-de-apresentacao) abaixo) na UI nativa da plataforma. Omita e a tool `send_presentation` ainda entrega - achatado pra texto simples via `deliver/3`. |

### Blocos de apresentação

Uma tool pode mandar conteúdo mais rico que texto simples - uma tabela, uma fileira de
botões - via a tool `send_presentation` e o schema de bloco compartilhado `Pepe.Presentation`:

```
%{"type" => "text", "text" => "..."}
%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}
%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}
```

O Slack renderiza isso como Block Kit de verdade hoje (uma `section` por bloco de
texto/tabela, um bloco `actions` com botões reais). Um provedor que ainda não adicionou
`deliver_blocks/3` continua recebendo o conteúdo - `Pepe.Presentation.to_text/1` achata
pra texto simples legível, enviado pelo `deliver/3` normal do provedor - então uma tool
que manda blocos funciona em todo canal imediatamente, de forma rica só onde um provedor
se deu ao trabalho de renderizar.

## O behaviour PluginRoute - uma rota HTTP própria de um plugin

O contrato de evento de entrada do `Pepe.Webhooks.Provider` é fixo - um único formato, pra
plataformas de chat. O `Pepe.PluginRoute` é pra qualquer coisa que precise da própria rota:
um callback de redirecionamento OAuth que precisa cair no domínio público do próprio Pepe,
um endpoint REST/RPC personalizado.

```elixir
@callback route_prefix() :: String.t()
@callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()
```

`call/2` recebe o `Plug.Conn` bruto (já passado pelo parsing de corpo do próprio endpoint) e
os segmentos de caminho depois do seu prefixo - controle total, igual a qualquer Plug escrito
à mão, já que o Pepe não tem como antecipar todo formato que o protocolo de um plugin possa
precisar. Um `call/2` que quebra responde `500`, nunca derruba o processo da requisição (nem
mais nada) junto.

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `route_prefix/0` e `call/2`:

   ```elixir
   defmodule MyPlugin.OAuthCallback do
     @behaviour Pepe.PluginRoute

     @impl true
     def route_prefix, do: "weather_oauth"

     @impl true
     def call(conn, _path) do
       # trata o redirecionamento do provedor, troca o código, etc.
       Plug.Conn.send_resp(conn, 200, "connected")
     end
   end
   ```

2. Salve como `~/.pepe/plugins/weather_oauth.exs` e instale:
   `pepe plugin install ~/.pepe/plugins/weather_oauth.exs`.
3. **Habilite a rota explicitamente** - reivindicar um prefixo no código não expõe nada
   sozinho; é preciso um **segundo** opt-in, deliberado, porque uma rota (diferente de uma
   tool) responde a qualquer requisição de entrada, não só a uma que o próprio modelo do
   agente decidiu fazer:

   ```bash
   pepe plugin route list                 # todo plugin instalado que reivindica rota, habilitado ou não
   pepe plugin route enable weather_oauth # agora acessível em /plugin-routes/weather_oauth/...
   pepe plugin route disable weather_oauth
   ```

4. Aponte o que precisar chegar até ela (a URL de redirecionamento de um app OAuth, um
   remetente de webhook) para `https://seu-dominio/plugin-routes/weather_oauth/...` - os
   segmentos de caminho depois do prefixo chegam no segundo argumento de `call/2`.

## O behaviour Realtime provider - áudio duplex

Nenhum dos outros pontos de extensão do Pepe mantém um stream contínuo e de mão dupla - uma
chamada de tool, um webhook, um ocupante de slot são todos request/response ou de uma vez só.
O `Pepe.Realtime.Provider` é essa primitiva: um plugin é dono de tudo sobre como o áudio de
entrada vira uma resposta de saída (um modelo de tempo real hospedado, um pipeline de
STT-em-streaming-depois-TTS), e um novo canal WebSocket carrega os bytes.

```elixir
@callback name() :: String.t()
@callback start(agent :: map(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}
@callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}
@callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}   # opcional
@callback stop(session :: term()) :: :ok
```

Um cliente entra em `realtime:<agent_name>` (`realtime:default` pro agente padrão) com
`{"provider": "your_provider_name"}` no payload de entrada, e então manda pedaços binários no
evento `"audio"`. O `sink` de `start/3` é o pid pra onde mandar eventos de volta enquanto a
sessão durar: `{:realtime_audio, chunk}`, `{:realtime_text, text}`, ou
`{:realtime_stopped, reason}` se o provedor encerrar a sessão por conta própria. Aditivo, não
um slot - vários provedores podem estar instalados, e um cliente escolhe um pelo nome por
conexão; nada precisa ser habilitado globalmente do jeito que o `Pepe.PluginRoute` exige. O
Pepe não traz nenhum provedor de tempo real embutido - esse é o ponto de extensão que um
plugin preenche.

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `name/0`, `start/3`, `push_audio/2`, `stop/1`, e
   opcionalmente `push_text/2`. O exemplo abaixo é um provedor eco - ele manda de volta
   qualquer áudio que recebe, mais uma legenda pra cada pedaço. Bom o suficiente pra
   desenvolver um cliente contra ele antes de existir um backend real de STT/TTS ou de
   modelo hospedado:

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

   O próprio argumento `sink` de `start/3` faz as vezes do termo de sessão aqui, já que
   esse provedor não tem nenhuma conexão/processo real próprio pra rastrear - um provedor
   que fala com um upstream de verdade (um modelo hospedado, um pipeline local de STT/TTS)
   devolveria algo que identifica *isso*, e usaria o `sink` só pra mandar eventos de volta.

2. Salve como `~/.pepe/plugins/echo_realtime.exs` e instale:
   `pepe plugin install ~/.pepe/plugins/echo_realtime.exs`. Nada mais pra habilitar - um
   provedor de tempo real não tem slot pra fixar nem rota pra ligar; fica ativo assim que
   é instalado, esperando um cliente pedir por ele pelo nome.
3. De um cliente, entre em `realtime:<agent_name>` no WebSocket já existente
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

4. Mande pedaços binários no evento `"audio"` depois de entrar; os eventos
   `{:realtime_audio, ...}`/`{:realtime_text, ...}` voltam do mesmo jeito que qualquer
   outro push de canal.

## O behaviour Hook - mutação real de conteúdo

Um hook reescreve conteúdo da conversa de verdade, no mesmo caminho síncrono e inline em
que `pii_redact`/`llm_redact`/`http_redact`/`presidio` já rodam. É assim que um plugin de
compactação de contexto ou redação de conteúdo faz trabalho real - não confundir com um
run observer (abaixo), que só consegue observar.

```elixir
@callback name() :: String.t()
@callback stages() :: [:inbound | :outbound | :learn | :tool_result]
@callback run(stage, text :: String.t(), settings :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:ok, String.t(), [%{"fake" => String.t(), "real" => String.t()}]}
```

`:inbound` roda no texto do usuário antes do modelo vê-lo; `:outbound` na resposta antes
de ser enviada de volta; `:tool_result` na saída bruta de uma tool antes dela entrar na
conversa. Um agente adere a hooks pelo nome (`mix pepe agent add NOME --hooks
seu_hook,pii_redact`) - um hook de plugin é aditivo junto aos quatro builtins, e um
builtin sempre ganha em caso de colisão de nome, então escolha um nome distinto de
`pii_redact`/`llm_redact`/`http_redact`/`presidio`.

Hooks encadeiam: com `--hooks bracket,exclaim`, `exclaim` vê o texto já mutado por
`bracket`, em ordem - sequencial, cada um vendo a saída do anterior, não um fan-out.
Retorne o texto (possivelmente inalterado) e, opcionalmente, uma lista de entradas de mapa
reversível (`fake` um token, `real` o valor que ele substituiu) se quiser que sejam
restauradas na saída.

**Fail-open, de propósito**: um hook que levanta uma exceção cai de volta pro texto de
entrada em vez de quebrar o turno. Um hook muta ou redige - nunca bloqueia. Para vetar
uma chamada de vez, veja `Pepe.Permissions.Policy` abaixo, um mecanismo deliberadamente
diferente e mais estreito.

## O behaviour Policy - vetando uma chamada de tool

Um plugin de policy pode recusar uma chamada de tool antes dela rodar, por uma razão que
só o seu plugin conhece (uma regra da empresa, um serviço de allowlist externo, um
limitador de taxa).

```elixir
@callback name() :: String.t()
@callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

Toda policy instalada é consultada em **toda** chamada de gate, para todo agente - não é
opt-in como um hook, já que instalar uma só adiciona restrição. É checada antes da
própria lógica de pré-aprovação do Pepe, então uma policy pode vetar até uma chamada que
o operador já marcou como aprovada com `:always`. Sem chegar a uma recusa total,
`:ask`/`{:ask, reason}` força um humano a olhar uma chamada que de outra forma teria sido
pré-aprovada silenciosamente - o motivo aparece junto do prompt. O mais restritivo vence
entre todas as policies instaladas: `:deny` vence `:ask` vence `:allow`.

**Fail-closed - a única exceção deliberada em todo esse sistema de plugin.** Toda outra
superfície de plugin no Pepe degrada para "como se não estivesse instalada" numa falha ou
timeout. Um plugin de policy é o oposto: um `check/3` que levanta exceção, trava além do
timeout, ou retorna qualquer coisa diferente de um `:allow` explícito **nega a chamada**.
Uma checagem de segurança que não conseguiu rodar não é a mesma coisa que uma que passou.

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

Adicione um `check_run/3` opcional pra vetar uma execução inteira, antes de qualquer chamada
de tool e antes da primeira chamada ao modelo - a única forma de dizer "não processe essa
mensagem de jeito nenhum" (um remetente banido, um limitador de taxa por mensagem), já que o
`check/3` nunca dispara pra um turno que não chama nenhuma tool:

```elixir
@callback check_run(agent :: map(), first_message :: String.t(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

"Aplica a" ainda pode ser restringido - pelo operador, nunca pelo próprio agente, o que
anularia o propósito:

```bash
pepe policy list                                      # toda policy instalada + seu escopo
pepe policy scope no_bash_policy --agents support --projects acme
pepe policy scope no_bash_policy --clear              # volta a aplicar em todo lugar
```

ou direto no `config.json` (`"policy_scope"`, pelo nome da policy). Nenhuma entrada pro
nome de uma policy significa sem escopo - todo agente, o padrão e o comportamento
original. Um agente nunca consegue se excluir sozinho; só quem configura o escopo decide
onde uma policy é consultada.

## O behaviour RunObserver

Um observador de execução observa o turno de um agente de fora - útil para logging,
métricas ou alertas sobre o que um agente faz, sem tocar no que ele faz. É estritamente
de observação: nunca vê o histórico de mensagens da conversa, não pode bloquear um
turno e não pode mudar nada nele, só descobrir o que já aconteceu, depois do fato.

```elixir
@callback name() :: String.t()
@callback subscriptions() :: [atom()]
@callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
```

`subscriptions/0` nomeia quais tipos de evento você quer - qualquer um de
`:run_start`, `:tool_call`, `:tool_denied`, `:tool_result`, `:assistant`,
`:assistant_delta`, `:failover`, `:output_cap`, `:usage`, `:inline`, `:done`,
`:error`, `:run_end`. `handle_event/3` é chamado uma vez por evento que você
assinou, na ordem em que o turno os produziu. `payload` é a própria tupla do
evento (ex.: `{:tool_result, "web_search", "..."}`) - com uma exceção:
`:tool_call` chega como `{:tool_call, name}`, sem seus argumentos, já que
esses ainda não passaram pela redação e podem carregar segredos.

Um exemplo mínimo que registra cada chamada de ferramenta e a resposta final:

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

O despacho é assíncrono e isolado: um observador travado ou que quebra nunca deixa a
conversa observada mais lenta nem a quebra. Um que falha 3 vezes seguidas é
desabilitado - em todas as execuções futuras, não só na que disparou o problema -
para que um observador quebrado nunca continue pagando seu próprio custo de detecção
para sempre, nem lote seus logs com a mesma falha. Não há nada para conceder a um
agente aqui: instalado é habilitado.

## O registro

`Pepe.Tools.all/0` devolve as ferramentas embutidas seguidas de cada
ferramenta de plugin carregada; `Pepe.Webhooks` faz o mesmo para provedores de
canal. Embutidos e plugins são unidos em um único registro, e os dois formatos
resolvem um conflito de nome de maneiras opostas. Em ferramentas, a embutida
sempre prevalece, então escolha um nome de ferramenta diferente de `read_file`,
`web_search` e do resto de `pepe tools`. Em provedores de canal, um plugin de
mesmo nome é que prevalece, e é assim que você substitui um provedor que já vem
junto pela sua própria versão dele.

### Conceder uma ferramenta a um agente

Instalar um plugin não entrega suas ferramentas a todo agente; só as
ferramentas listadas em um agente ficam expostas a ele, com o mesmo controle
de uma embutida.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Painel:** abra o agente em Agentes e marque a ferramenta; as ferramentas de
plugin aparecem ao lado das embutidas.

**Pela conversa:** um agente com `enable_tool` pode ligar uma ferramenta para
si mesmo:

> Você: ative a ferramenta reverse_text
>
> Agente: reverse_text ativada; você já pode usar a partir da sua próxima mensagem

Para conceder uma ferramenta a um agente *diferente*, a ação `add_tool` do
`manage_agent` faz isso (limitada aos agentes que quem pede tem permissão de
gerenciar, e confirma com você antes):

> Você: dê ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirma?

## Onde os plugins ficam e como carregam

Os plugins ficam em `~/.pepe/plugins/` (segue `PEPE_HOME`). O Pepe varre essa
pasta recursivamente atrás de arquivos `.exs`, compila cada um uma vez e só
recompila quando a data de modificação muda: solte um arquivo e funciona sem
reiniciar; edite e a mudança vale na próxima chamada de ferramenta. Um arquivo
pode definir vários módulos (o exemplo do Google abaixo traz quatro).

Um plugin tem um de dois formatos: um arquivo `.exs` solto, ou um **pacote**,
um diretório com um `manifest.json` e um ou mais arquivos `.exs`.

Compilar em tempo de execução traz um limite honesto: **um plugin não pode
trazer uma dependência externa nova junto com ele.** O Elixir resolve e compila
dependências em tempo de build, então um plugin só pode usar as bibliotecas que
o Pepe já traz (`Req`, `Jason`, a biblioteca padrão e o resto das dependências
dele). Um plugin que precisa de uma biblioteca inédita não é um drop-in; isso
exigiria recompilar o Pepe. Na prática isso raramente atrapalha, porque uma
ferramenta que chama uma API HTTP e um provedor de canal como o Chatwoot não
precisam de nada além do que já vem junto, e por isso instalam sem problema.

## Instalar um plugin

A fonte é um arquivo local, um diretório local, um `.tar.gz`, ou uma URL para
qualquer um desses, e o `install` desempacota o que você der na pasta de
plugins. Uma URL de repositório do GitHub é baixada como seu pacote de
código-fonte e extraída, pegando a branch padrão (`main`, depois `master`)
quando nenhuma branch é indicada; acrescente `/tree/<branch>` à URL para pegar
outra. Um `.tar.gz`, local ou remoto, é extraído e o pacote é colocado sob o
`name` do manifesto dele. Um diretório é copiado como está, e um `.exs` solto é
copiado direto.

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin list
pepe plugin remove google
```

**Painel:** a página de Plugins aceita uma URL do GitHub, uma URL `.tar.gz` ou
um caminho local; você marca uma caixa confirmando que confia na fonte e
clica em Instalar. Plugins instalados aparecem com um botão Remover e, quando
o plugin declara configurações, um botão Configurar.

**Pela conversa, com `manage_plugin`:** um agente com essa ferramenta pode
instalar em seu nome: faça `scan` de uma fonte primeiro para ver o que ela
faz, depois `install`, `list`, `remove`. Passa pela mesma varredura de
segurança da CLI, mas sem a válvula de escape `--force`: um veredito
perigoso é sempre recusado pela conversa, e o agente vai te dizer para
revisar o código e rodar `--force` você mesmo em um terminal se ainda assim
quiser.

## A varredura de segurança

Um plugin é Elixir comum com acesso total ao aplicativo em execução:
instalar um é uma decisão de confiança, igual a instalar qualquer outro
software na sua máquina. Instale só a partir de uma fonte em que você confia,
e prefira fixar uma versão ou um commit específico.

Antes de ser colocado em disco, o `Pepe.Skills.Sentinel` varre o código. Ele
lê a **estrutura** do código (a árvore sintática), não só o texto cru, então
sinaliza chamadas perigosas com precisão:

- lançar shells (`System.cmd`, `:os.cmd`),
- eval dinâmico (`Code.eval_string`),
- desserialização insegura (`:erlang.binary_to_term`),
- chamadas destrutivas no sistema de arquivos (`File.rm_rf`),
- exaustão de átomos (`String.to_atom`),
- leitura do ambiente ou de caminhos com segredos (`~/.ssh`, a configuração do
  Pepe),
- acesso à rede.

Como ele lê a estrutura, e não as palavras, também pega as formas com alias e
as formas Erlang dessas chamadas, e não tropeça nas mesmas palavras quando elas
aparecem em um comentário ou em uma string. Ele nunca executa o código, e
devolve um de três vereditos:

- **limpo**: nenhum achado.
- **cautela**: sinalizado mas muitas vezes legítimo (um plugin de canal
  *deveria* fazer chamadas de rede); é mostrado, mas não bloqueia.
- **perigo**: nenhum bom motivo para estar ali; bloqueia a instalação.

```bash
pepe plugin scan ./my_plugin.exs        # varre sem instalar
pepe plugin install ./risky.exs --force # prossiga mesmo assim, depois de revisar
```

<div class="note"><strong>Um plugin roda com acesso total.</strong> A
varredura é uma rede de segurança, não um substituto para ler o código você
mesmo.</div>

## O manifesto e o diálogo de Configurar

O `manifest.json` de um pacote o nomeia, o descreve e, o mais útil, declara
as configurações de que precisa. Do exemplo do Google, incluso:

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

Cada entrada de `config` é um campo: `key` (o nome que seu código lê),
`label` (mostrado no formulário), `type` (`"text"`, `"secret"` para uma
entrada mascarada, ou `"select"` com uma lista `"options"`), e um `hint`
opcional. O painel lê esse array e renderiza o diálogo de Configurar; um
plugin novo não precisa de tela nova. Um valor pode ser uma referência
`${ENV_VAR}`, guardada literalmente e resolvida a partir do ambiente só na
leitura, então segredos nunca ficam expandidos no arquivo de configuração.

Leia uma configuração salva do código do seu plugin com
`Pepe.Plugins.config/3` (o nome é o nome do pacote no manifesto; o terceiro
argumento é um padrão):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

Um padrão comum: prefira o valor do painel, recorra a uma variável de
ambiente, para que o plugin funcione tanto se o operador preencher o
formulário quanto se exportar uma variável (é exatamente o que o exemplo do
Google abaixo faz).

## Exemplo: o plugin de ferramenta Google Workspace

`examples/plugins/google/google.exs` traz quatro ferramentas em um único
arquivo:

| Ferramenta | O que faz |
|------|--------------|
| `gcal_upcoming` | Lista os próximos eventos do Google Calendar principal |
| `gcal_create_event` | Cria um evento (resumo, início, fim, descrição) |
| `gmail_search` | Busca no Gmail e devolve remetente e assunto das correspondências |
| `gmail_send` | Envia um e-mail em texto simples |

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

Ele se autentica com um token bearer OAuth2 resolvido na hora da chamada:
nada sensível embutido no código. Exporte um token de acesso pronto (mais
rápido, expira em ~1h):

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

Obtenha esses valores criando um cliente OAuth (tipo "Desktop app") em um
projeto do Google Cloud, com as APIs de Calendar e Gmail habilitadas, depois
de rodar o fluxo de consentimento uma vez para os escopos que você usa. Ou
preencha os mesmos campos no diálogo de Configurar do plugin, guardando
segredos como referências `${ENV_VAR}`.

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

> Você: o que tenho na agenda amanhã, e mande um resumo por e-mail para sam@example.com
>
> Agente: (chama gcal_upcoming, depois gmail_send) Você tem 3 eventos amanhã. Enviei o resumo por e-mail para sam@example.com.

## Exemplo: o plugin de canal Chatwoot

`examples/plugins/chatwoot/` mostra o outro formato: um **canal**, não uma
ferramenta. Ele registra um provedor `chatwoot` para que o Pepe fique atrás
de uma caixa de entrada do [Chatwoot](https://www.chatwoot.com) como o agente
de IA, em todo canal que o Chatwoot já cobre (WhatsApp, widget web,
Instagram, ...).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Transferência nativa para humano, sem nenhuma integração extra.** O Chatwoot carrega o
sinal de transferência em todo webhook: o `status` da conversa. O plugin
implementa `parse/1` para responder só conversas marcadas como `pending`
(controladas pelo bot); no momento em que um atendente humano assume
(`open`), o Pepe fica quieto, e volta quando a conversa retorna a `pending`.

**Configuração, no Chatwoot:** crie um AgentBot, aponte o webhook de saída
dele para `https://SEU_HOST/webhooks/<project>/chatwoot/<slug>`. A conexão
guarda `base_url`, `account_id` e um `api_token` (como `${ENV_VAR}`) via
`config_schema/0`, preenchidos pelo painel, o mesmo padrão de Configurar de
qualquer plugin.

> Essa é uma de duas formas mutuamente exclusivas de rodar o WhatsApp: **ou**
> WhatsApp direto no Pepe (o provedor embutido `whatsapp`) **ou** WhatsApp no
> Chatwoot com o Pepe atrás dele (este plugin). Nunca conecte o mesmo número
> aos dois.

## Entregar um arquivo, não só texto

O `run/2` de uma ferramenta só devolve texto. Para entregar um arquivo de
verdade (uma planilha, um PDF) para a pessoa na conversa, não reinvente a
entrega: chame a ferramenta embutida `send_file` com um caminho; o Pepe
resolve o canal a partir da sessão e entrega o arquivo lá. Conceda `send_file`
a um agente e ele simplesmente funciona pela conversa, em qualquer canal cujo
provedor implemente `deliver_file/4`.

## Checklist

**Escrever uma ferramenta:**

1. Implemente `name/0`, `spec/0`, `run/2`; dê a ela um nome diferente de toda
   embutida.
2. Devolva `{:ok, text}` / `{:error, message}` do `run/2`, escrito para o
   modelo ler.
3. Precisa de credenciais ou opções? Inclua um `manifest.json` com um array
   `config`, leia com `Pepe.Plugins.config/3`.

**Escrever um canal:**

1. Implemente `name/0`, `verify/2`, `authenticate/3`, `parse/1`, `deliver/3`;
   adicione `config_schema/0` se precisar de credenciais configuradas pelo
   painel.
2. Adicione `respond/3` só se o protocolo da plataforma exigir uma resposta
   síncrona antes de qualquer trabalho do agente; `deliver_file/4` só se ela
   puder receber anexos.

**De qualquer forma:** faça a varredura (`pepe plugin scan SRC` ou
`manage_plugin scan`), instale, revise o que a varredura encontrou, e então
conceda a ferramenta a um agente (CLI, painel, ou `enable_tool`/`manage_agent`
pela conversa); um canal não precisa de concessão, fica ativo assim que é
instalado.
