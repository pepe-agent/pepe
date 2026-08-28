---
title: Plugins
description: Estende o Pepe com ferramentas e canais teus, instalando plugins com a configuração que cada um precisar.
---

Um plugin é um ficheiro que instalas para ensinar ao Pepe algo de novo, sem rebuild e sem reiniciar: basta largá-lo na pasta certa e já funciona. A maioria dos plugins faz uma de duas coisas: acrescenta uma **ferramenta** que o modelo pode invocar, ou acrescenta um **fornecedor de canal** (uma nova plataforma de mensagens assente em webhook). Esta página aprofunda estas duas formas, de longe as mais comuns, e depois passa mais rapidamente pelas restantes, mais abaixo.

Um plugin também pode assumir outras formas: um **canal de ligação persistente** (que precisa de um websocket de longa duração, não apenas de um webhook, ver [Slots](/docs/slots)), uma **rota HTTP própria** (um callback de redirecionamento OAuth, um endpoint personalizado, ver abaixo), um **fornecedor de áudio em tempo real** (voz duplex, ver abaixo), um **adaptador de protocolo de modelo**, um **hook** (reescreve de facto o conteúdo da conversa, encadeado e em linha, ver abaixo), uma **policy** (veta uma chamada de ferramenta, ou um turno inteiro, antes de acontecer; uma verificação que não conseguiu correr conta como recusa, por isso falha sempre fechada), ou um **observador de execução** (observa o ciclo a partir de fora, só de leitura, a única forma que não consegue afetar nada). Um plugin pode ainda ocupar um [**slot**](/docs/slots): a pesquisa de memória, a pesquisa web, a sandbox onde corre um comando de shell, a compactação da conversa, ou o próprio ciclo de raciocínio inteiro.

Por baixo do capô, todo o plugin é Elixir compilado em tempo de execução a partir de `~/.pepe/plugins/`, e cada módulo é comparado com a(s) forma(s) que implementa.

## O behaviour Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Finalidade |
|---|---|
| `name/0` | O nome de função que o modelo invoca, por exemplo `"read_file"`. Tem de ser único entre todas as ferramentas; um plugin nunca ganha um conflito de nome contra uma ferramenta incorporada. |
| `spec/0` | A especificação de função ao estilo OpenAI: nome, descrição em linguagem simples e um JSON Schema para os parâmetros. É isto que o modelo lê para decidir quando e como invocar a ferramenta. |
| `run/2` | Corre a chamada. `args` são os argumentos já descodificados (um mapa com chaves em texto); `ctx` transporta o contexto da execução em curso (ver abaixo). Devolve `{:ok, text}` ou `{:error, message}`; de qualquer forma isso é convertido em texto e volta para o modelo, por isso escreve a pensar em quem vai ler do outro lado. |

O `Pepe.Tools.Tool.function/3` já trata de montar o envelope da especificação por ti, bastando-te fornecer o nome, a descrição e os parâmetros.

Eis uma ferramenta completa e funcional, guardada como um `.exs` e depois instalada (ver mais abaixo):

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

Vale a pena manter essa segunda cláusula de `run/2`: se o modelo se esquecer de um argumento obrigatório, devolves um erro claro em vez de rebentar (um erro fatal também acaba por ser capturado, mas uma mensagem feita à medida ajuda o modelo a recuperar-se logo no turno seguinte).

O segundo argumento de `run/2`, **`ctx`**, transporta a execução em curso: `ctx[:agent]` (o agente em execução, por exemplo `%{name: "assistant"}`), `ctx[:session_key]` (a conversa em direto, que não existe em execuções de turno único), e `ctx[:cwd]` (o diretório de trabalho). Trata sempre cada uma destas chaves como opcional. As ferramentas que leem ou escrevem ficheiros resolvem os caminhos através de `Pepe.Agent.Workspace`; já as que chamam uma API externa costumam ignorar o `ctx` por completo e recorrer diretamente ao cliente HTTP `Req`, já incluído de origem, sem precisar de nenhuma dependência extra.

## O behaviour Channel provider

Um fornecedor de canal ensina o Pepe a falar uma nova plataforma de mensagens através do webhook de entrada genérico que já existe: sem rota nova nenhuma, só um módulo novo no registo.

```elixir
@callback name() :: String.t()
@callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error
@callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error
@callback parse(payload :: map()) :: {:ok, [inbound]} | :ignore
@callback deliver(config :: map(), to :: String.t(), text :: String.t()) :: :ok | {:error, term()}
```

| Callback | Obrigatório? | Finalidade |
|---|---|---|
| `name/0` | sim | A chave de registo, e também o segmento `:provider` do URL do webhook, por exemplo `"whatsapp"`. |
| `verify/2` | sim | Responde ao handshake `GET` da plataforma no momento em que registas o URL do webhook. `{:ok, challenge}`, ou `:error` se o fornecedor não tiver nenhum desafio deste tipo. |
| `authenticate/3` | sim | Confere a assinatura de um `POST` de entrada face ao segredo da ligação. `:ok` para aceitar, `:error` para descartar. |
| `parse/1` | sim | Normaliza um payload já descodificado em zero ou mais mensagens `%{from, text, id}`, ou devolve `:ignore` quando não há nada a fazer com aquilo (recibos, atualizações de estado). |
| `deliver/3` | sim | Envia uma resposta em texto para `to` (um endereço próprio do fornecedor: número de telefone, id de canal, e por aí fora). |
| `label/0` | não | O rótulo humano usado no painel (por omissão usa `name/0`). |
| `config_schema/0` | não | Os campos que o painel mostra para configurar uma ligação, no mesmo formato do array `config` de um manifesto de plugin (ver abaixo). |
| `respond/3` | não | Uma resposta HTTP **síncrona** ao `POST` em bruto, para os protocolos que exigem uma antes de qualquer trabalho do agente (o desafio de verificação de URL do Slack, o `PING` do Discord). `{:reply, status, content_type, body}`, ou `:cont` para cair para `parse/1`. |
| `deliver_file/4` | não | Envia um ficheiro como anexo. Se o omitires, o `send_file` limita-se a avisar que o canal não recebe ficheiros. |
| `addressed?/2` | não | Este payload dirige-se ao bot, e por isso merece resposta? Deixa um fornecedor respeitar o `require_mention` em conversas de grupo (a predefinição, quando omitido, é considerar sempre dirigido ao bot). |
| `deliver_blocks/3` | não | Renderiza conteúdo estruturado (ver [Blocos de apresentação](#blocos-de-apresentação) abaixo) na própria UI nativa da plataforma. Se o omitires, a ferramenta `send_presentation` continua na mesma a entregar conteúdo, só que achatado em texto simples através do `deliver/3`. |

### Blocos de apresentação

Uma ferramenta pode mandar conteúdo mais rico do que texto simples, como uma tabela ou uma fila de botões, através da ferramenta `send_presentation` e do esquema de blocos partilhado `Pepe.Presentation`:

```
%{"type" => "text", "text" => "..."}
%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}
%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}
```

O Slack já renderiza isto hoje como Block Kit a sério (uma `section` por bloco de texto ou tabela, um bloco `actions` com botões de verdade). Um fornecedor que ainda não tenha implementado `deliver_blocks/3` continua a receber o conteúdo na mesma: o `Pepe.Presentation.to_text/1` achata-o em texto simples e legível, enviado pelo `deliver/3` habitual do fornecedor. Assim, uma ferramenta que envia blocos funciona logo em qualquer canal, e de forma rica só onde algum fornecedor se deu ao trabalho de os desenhar.

## O behaviour PluginRoute: a rota HTTP própria de um plugin

O contrato de evento de entrada do `Pepe.Webhooks.Provider` é fixo, um único formato pensado para plataformas de chat. O `Pepe.PluginRoute` serve para tudo o que precisa do seu próprio formato: um callback de redirecionamento OAuth que tem mesmo de aterrar no domínio público do Pepe, ou um endpoint REST/RPC feito por medida.

```elixir
@callback route_prefix() :: String.t()
@callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()
```

O `call/2` recebe o `Plug.Conn` em bruto (já depois do próprio parsing do corpo pelo endpoint) e os segmentos do caminho a seguir ao teu prefixo, com controlo total, tal como qualquer Plug escrito à mão, porque o Pepe não tem como antecipar todos os formatos que o protocolo próprio de um plugin possa exigir. Se um `call/2` rebentar, responde com `500`, mas nunca arrasta consigo o processo do pedido, nem nada mais.

**Construir uma, passo a passo:**

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
3. **Ativa a rota de forma explícita.** Reivindicar um prefixo no código não expõe nada por si só; é preciso um **segundo opt-in, deliberado**, porque uma rota, ao contrário de uma ferramenta, responde a qualquer pedido que entre, e não só ao que o próprio modelo do agente decidiu fazer:

   ```bash
   pepe plugin route list                 # todo o plugin instalado que reivindica uma rota, ativado ou não
   pepe plugin route enable weather_oauth # já acessível em /plugin-routes/weather_oauth/...
   pepe plugin route disable weather_oauth
   ```

4. Aponta o que precisar de lá chegar (o URL de redirecionamento de uma app OAuth, quem envia um webhook) para `https://o-teu-dominio/plugin-routes/weather_oauth/...`; os segmentos do caminho a seguir ao prefixo chegam-te no segundo argumento de `call/2`.

## O behaviour Realtime provider: áudio duplex

Nenhum dos outros pontos de extensão do Pepe mantém um fluxo contínuo e bidirecional: uma chamada de ferramenta, um webhook, um ocupante de slot, são todos de pedido e resposta ou de uma única vez. O `Pepe.Realtime.Provider` é essa peça em falta: um plugin fica encarregado de tudo o que transforma áudio de entrada numa resposta de saída (um modelo realtime alojado, um pipeline de streaming que passa por STT e depois TTS), e um canal WebSocket novo é que transporta os bytes.

```elixir
@callback name() :: String.t()
@callback start(agent :: map(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}
@callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}
@callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}   # opcional
@callback stop(session :: term()) :: :ok
```

Um cliente junta-se a `realtime:<agent_name>` (`realtime:default` para o agente predefinido) com `{"provider": "your_provider_name"}` no payload de adesão, e a partir daí envia blocos binários no evento `"audio"`. O `sink` que `start/3` recebe é o pid para onde mandar eventos de volta enquanto a sessão durar: `{:realtime_audio, chunk}`, `{:realtime_text, text}`, ou `{:realtime_stopped, reason}` se for o próprio fornecedor a terminar a sessão. É algo aditivo, não um slot: podes ter vários fornecedores instalados ao mesmo tempo, e cada cliente escolhe um pelo nome, por ligação; não há nada para ativar globalmente, ao contrário do que acontece com um `Pepe.PluginRoute`. O Pepe não traz nenhum fornecedor realtime de origem: este é justamente o ponto de extensão que um plugin vem preencher.

**Construir um, passo a passo:**

1. Escreve um módulo que implemente `name/0`, `start/3`, `push_audio/2`, `stop/1`, e opcionalmente `push_text/2`. O exemplo abaixo é um fornecedor de eco: devolve o mesmo áudio que recebeu, mais uma legenda para cada bloco. Já chega para desenvolveres um cliente contra ele antes de teres um backend real de STT/TTS ou um modelo alojado:

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

   Aqui, o próprio argumento `sink` de `start/3` faz também de termo de sessão, já que este fornecedor não tem nenhuma ligação ou processo real seu para seguir; um fornecedor a falar com um upstream verdadeiro (um modelo alojado, um pipeline local de STT/TTS) devolveria algo que identificasse esse upstream, e usaria o `sink` só para mandar eventos de volta.

2. Guarda-o como `~/.pepe/plugins/echo_realtime.exs` e instala-o:
   `pepe plugin install ~/.pepe/plugins/echo_realtime.exs`. Não há mais nada para ativar: um fornecedor realtime não tem slot para fixar nem rota para ligar, fica ativo assim que é instalado, à espera de um cliente que o peça pelo nome.
3. A partir de um cliente, junta-te a `realtime:<agent_name>` no WebSocket já existente (`/socket/websocket`), nomeando o fornecedor no payload:

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

4. Depois de te juntares, envia blocos binários no evento `"audio"`; os eventos `{:realtime_audio, ...}` e `{:realtime_text, ...}` voltam da mesma forma que qualquer outro push num canal.

## O behaviour Hook: mutação real de conteúdo

Um hook reescreve mesmo o conteúdo da conversa, em linha, no mesmo caminho síncrono onde já correm o `pii_redact`, o `llm_redact`, o `http_redact` e o `presidio`. É assim que um plugin de compactação de contexto ou de censura de conteúdo faz o seu trabalho a sério, o que não é de confundir com um observador de execução (ver abaixo), que só pode observar.

```elixir
@callback name() :: String.t()
@callback stages() :: [:inbound | :outbound | :learn | :tool_result]
@callback run(stage, text :: String.t(), settings :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:ok, String.t(), [%{"fake" => String.t(), "real" => String.t()}]}
```

O estágio `:inbound` corre sobre o texto do utilizador antes de o modelo o ver; o `:outbound`, sobre a resposta antes de ser enviada de volta; o `:tool_result`, sobre a saída em bruto de uma ferramenta antes de ela entrar na conversa. Um agente adere a hooks pelo nome (`mix pepe agent add NOME --hooks o_teu_hook,pii_redact`); um hook de plugin soma-se aos quatro incorporados, sem os substituir, e num conflito de nome é sempre o incorporado que ganha, por isso escolhe um nome diferente de `pii_redact`, `llm_redact`, `http_redact` e `presidio`.

Os hooks encadeiam-se: com `--hooks bracket,exclaim`, o `exclaim` vê o texto já mutado pelo `bracket`, pela ordem indicada. É sequencial, cada um a ver a saída do anterior, nunca um fan-out. Devolve o texto (mudado ou não) e, se quiseres que sejam restaurados na saída, também uma lista de entradas de mapa reversível (`fake` para o token, `real` para o valor que ele substituiu).

**É fail-open, de propósito:** um hook que levanta uma exceção cai de volta para o texto de entrada em vez de partir o turno inteiro. Um hook muta ou censura, nunca bloqueia. Para vetares uma chamada por completo, é para isso que serve o `Pepe.Permissions.Policy`, descrito abaixo, um mecanismo deliberadamente diferente e mais restrito.

## O behaviour Policy: vetar uma chamada de ferramenta

Um plugin de policy pode recusar uma chamada de ferramenta antes de ela chegar a correr, por uma razão que só o teu plugin conhece (uma regra da empresa, um serviço externo de lista de permissões, um limitador de taxa).

```elixir
@callback name() :: String.t()
@callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

Toda a policy instalada é consultada em **todas** as chamadas à barreira de permissão, para todos os agentes a que se aplica; não é opt-in como um hook, porque instalar uma policy só pode acrescentar restrição, nunca tirar. É verificada antes da própria lógica de pré-aprovação do Pepe, e por isso uma policy consegue vetar até uma chamada que o operador já tenha marcado como sempre aprovada (`:always`). Sem chegar a uma recusa total, `:ask` ou `{:ask, reason}` obriga um humano a olhar para uma chamada que de outro modo teria sido pré-aprovada em silêncio, mostrando o motivo junto ao pedido. Entre todas as policies instaladas, vence sempre a mais restritiva: `:deny` bate `:ask`, que por sua vez bate `:allow`.

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

**Fail-closed: a única exceção deliberada em todo este sistema de plugins.** Todas as outras superfícies de plugin do Pepe, ao falharem ou ultrapassarem o tempo limite, degradam-se para "como se não estivessem instaladas". Uma policy é exatamente o oposto: se um `check/3` levantar exceção, ficar preso além do tempo limite, ou devolver qualquer coisa que não seja um `:allow` explícito, **a chamada é negada**. Uma verificação de segurança que não conseguiu correr não é o mesmo que uma que correu e passou.

Onde se aplica ainda pode ser delimitado, mas só pelo operador, nunca pelo próprio agente, o que anularia todo o sentido disto:

```bash
pepe policy list                                      # toda a policy instalada, e o seu âmbito
pepe policy scope no_bash_policy --agents support --projects acme
pepe policy scope no_bash_policy --clear              # volta a aplicar-se em todo o lado
```

ou diretamente no `config.json`, em `"policy_scope"`, pelo nome da policy. Não haver entrada para o nome de uma policy quer dizer sem âmbito definido, ou seja, aplica-se a todo o agente: a predefinição, e o comportamento original. Um agente nunca consegue excluir-se a si próprio; só quem configura o âmbito é que decide onde uma dada policy chega sequer a ser consultada.

Podes ainda acrescentar um `check_run/3` opcional para vetar um turno inteiro, antes de qualquer chamada de ferramenta e antes da primeira chamada ao modelo, a única forma de dizeres "não processes esta mensagem de todo" (um remetente banido, um limite de taxa ao nível da própria mensagem), já que o `check/3` nunca dispara para um turno que não chega a invocar nenhuma ferramenta:

```elixir
@callback check_run(agent :: map(), first_message :: String.t(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

## O behaviour RunObserver

Um observador de execução vê o turno de um agente a partir de fora, útil para registos, métricas ou alertas sobre o que um agente anda a fazer, sem nunca lhe tocar. É estritamente de observação: nunca vê o histórico de mensagens da conversa, não consegue bloquear um turno nem mudar nada nele, só fica a saber o que já aconteceu, depois do facto consumado.

```elixir
@callback name() :: String.t()
@callback subscriptions() :: [atom()]
@callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
```

O `subscriptions/0` indica que tipos de evento queres receber, de entre `:run_start`, `:tool_call`, `:tool_denied`, `:tool_result`, `:assistant`, `:assistant_delta`, `:failover`, `:output_cap`, `:usage`, `:inline`, `:done` e `:error`, `:run_end`. O `handle_event/3` é chamado uma vez por cada evento a que estiveres subscrito, pela ordem em que o turno os foi produzindo. O `payload` é o próprio tuplo do evento (por exemplo, `{:tool_result, "web_search", "..."}`), com uma única exceção: o `:tool_call` chega como `{:tool_call, name}`, sem os seus argumentos, porque estes ainda não passaram pela censura e podem transportar segredos.

Eis um exemplo mínimo que regista cada chamada a uma ferramenta e a resposta final:

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

O despacho é assíncrono e isolado: um observador preso ou que rebenta nunca torna a conversa observada mais lenta, nem a quebra. Um que falhe três vezes seguidas fica desativado, em todas as execuções futuras e não só naquela que causou o problema, para que um observador avariado nunca continue a pagar o seu próprio custo de deteção para sempre, nem inunde os teus registos com a mesma falha repetida. Aqui não há nada para conceder a um agente: estar instalado já é estar ativo.

## O registo

O `Pepe.Tools.all/0` devolve as ferramentas incorporadas seguidas de cada ferramenta de plugin já carregada; o `Pepe.Webhooks` faz o mesmo para os fornecedores de canal. Incorporados e plugins juntam-se num único registo, e as duas formas resolvem um conflito de nome de maneiras opostas. Nas ferramentas, ganha sempre a incorporada, por isso escolhe para a tua um nome diferente de `read_file`, `web_search` e do resto de `pepe tools`. Nos fornecedores de canal é ao contrário: ganha o plugin com o mesmo nome, e é assim que substituis um fornecedor já incluído pela tua própria versão dele.

### Conceder uma ferramenta a um agente

Instalar um plugin não entrega logo as suas ferramentas a todos os agentes: só as ferramentas explicitamente listadas num agente ficam expostas a ele, com o mesmo controlo de uma ferramenta incorporada.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Painel:** abre o agente em Agentes e assinala a ferramenta; as ferramentas de plugin aparecem lado a lado com as incorporadas.

**Pela conversa:** um agente com `enable_tool` consegue ativar uma ferramenta para si próprio:

> Tu: ativa a ferramenta reverse_text
>
> Agente: reverse_text ativada; já podes usá-la a partir da tua próxima mensagem

Para concederes uma ferramenta a um agente *diferente*, é a ação `add_tool` do `manage_agent` que trata disso, limitada aos agentes que quem pede tem permissão para gerir, e sempre a confirmar contigo antes:

> Tu: dá ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirma?

## Onde os plugins vivem e como carregam

Os plugins vivem em `~/.pepe/plugins/` (segue a variável `PEPE_HOME`). O Pepe percorre essa pasta de forma recursiva à procura de ficheiros `.exs`, compila cada um uma única vez e só volta a compilar quando o ficheiro muda em disco: larga um ficheiro lá dentro e já funciona, sem precisares de reiniciar nada; edita-o, e a alteração entra em vigor logo na próxima chamada de ferramenta. Um único ficheiro pode definir vários módulos (o exemplo do Google, mais abaixo, traz quatro de uma vez).

Um plugin assume sempre uma de duas formas: um ficheiro `.exs` solto, ou um **pacote** (uma pasta com um `manifest.json` e um ou mais ficheiros `.exs`).

Compilar em tempo de execução traz consigo um limite honesto: **um plugin não pode trazer uma dependência externa nova.** O Elixir resolve e compila as dependências em tempo de compilação, por isso um plugin só consegue usar as bibliotecas que o Pepe já traz de fábrica (`Req`, `Jason`, a biblioteca padrão e o resto das suas próprias dependências). Um plugin que precise de uma biblioteca inédita já não é um simples drop-in, implicaria reconstruir o próprio Pepe. Na prática isto raramente pesa, já que uma ferramenta que chama uma API HTTP, ou um fornecedor de canal como o Chatwoot, não precisam de nada além do que já vem incluído, e é por isso que se instalam sem qualquer atrito.

## Instalar um plugin

A fonte pode ser um ficheiro local, uma pasta local, um `.tar.gz`, um URL para qualquer um destes, ou uma referência do [PepeHub](https://hub.pepe-agent.com), e o `install` desempacota o que lhe deres para dentro da pasta de plugins. Um URL de repositório do GitHub é obtido como o seu arquivo de código-fonte e depois extraído, usando o ramo predefinido (`main`, e só depois `master`) quando nenhum ramo é indicado; acrescenta `/tree/<branch>` ao URL se quiseres um diferente. Um `.tar.gz`, local ou remoto, é extraído e o pacote fica colocado sob o `name` do seu manifesto. Uma pasta é copiada tal como está, e um `.exs` solto é simplesmente copiado na íntegra.

Uma referência do PepeHub tanto pode ser a forma curta `@handle/nome` como o próprio URL da página do pacote, copiado diretamente de `hub.pepe-agent.com`; qualquer uma das duas resolve para o mesmo pacote. Apontar o `plugin install` a um nome que afinal é uma skill no PepeHub, e não um plugin, falha com uma mensagem clara a indicar-te para usares antes `skill install`.

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin install @jhonathas/backup-tool
pepe plugin list
pepe plugin remove google
```

**Painel:** a página de Plugins aceita um URL do GitHub, um URL de `.tar.gz` ou um caminho local; assinalas uma caixa a confirmar que confias na fonte, e depois clicas em Instalar. Os plugins instalados aparecem com um botão Remover e, quando o plugin declara alguma configuração, também um botão Configurar.

**Pela conversa, com `manage_plugin`:** um agente com esta ferramenta consegue instalar em teu nome: primeiro faz `scan` a uma fonte para ver o que ela faz, depois `install`, `list` ou `remove`. Corre a mesma verificação de segurança da CLI, só que sem a saída de emergência `--force`: um veredito de perigo é sempre recusado quando vem da conversa, e o agente diz-te para reveres o código e correres o `--force` tu mesmo, num terminal, se ainda assim quiseres avançar.

## A verificação de segurança

Um plugin é Elixir comum, com acesso total à aplicação em execução; instalar um é uma decisão de confiança, exatamente como instalar qualquer outro software na tua máquina. Instala só a partir de fontes em que confies, e prefere sempre fixar uma versão ou um commit em concreto.

Antes de ser colocado em disco, o `Pepe.Skills.Sentinel` analisa o código. Lê a **estrutura** do código, a sua árvore sintática, e não apenas o texto em bruto, por isso assinala com precisão as chamadas perigosas:

- lançar processos de shell (`System.cmd`, `:os.cmd`),
- avaliação dinâmica (`Code.eval_string`),
- desserialização insegura (`:erlang.binary_to_term`),
- chamadas destrutivas ao sistema de ficheiros (`File.rm_rf`),
- exaustão de átomos (`String.to_atom`),
- leitura do ambiente ou de caminhos com segredos (`~/.ssh`, a configuração do Pepe),
- acesso à rede.

Como lê a estrutura e não as palavras, apanha também as formas com alias e as formas equivalentes em Erlang dessas mesmas chamadas, e não se deixa enganar pelas mesmas palavras quando aparecem apenas num comentário ou numa string. Nunca chega a executar o código, e devolve sempre um de três veredictos:

- **limpo**: sem nada a assinalar.
- **cautela**: algo foi assinalado, mas é muitas vezes legítimo (um plugin de canal *devia mesmo* fazer chamadas de rede); é mostrado, mas não bloqueia nada.
- **perigo**: não há boa razão para aquilo lá estar; a instalação é bloqueada.

```bash
pepe plugin scan ./my_plugin.exs        # analisa sem instalar
pepe plugin install ./risky.exs --force # avança na mesma, depois de reveres
```

<div class="note"><strong>Um plugin corre com acesso total.</strong> A verificação é uma rede de segurança, não um substituto para leres o código tu mesmo.</div>

## O manifesto e a janela de Configurar

O `manifest.json` de um pacote dá-lhe nome, descreve-o e, o mais útil de tudo, declara as configurações de que precisa. Do exemplo do Google, incluído de origem:

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

Cada entrada de `config` corresponde a um campo: `key` (o nome que o teu código vai ler), `label` (o que aparece no formulário), `type` (`"text"`, `"secret"` para uma entrada mascarada, ou `"select"` com uma lista de `"options"`), e um `hint` opcional. O painel lê este array e monta a janela de Configurar sozinho; um plugin novo não precisa de nenhum ecrã à parte. Um valor pode muito bem ser uma referência `${ENV_VAR}`, guardada tal como está e só resolvida a partir do ambiente no momento da leitura, o que garante que nenhum segredo fica expandido dentro do ficheiro de configuração.

Lê uma configuração já guardada, a partir do código do teu plugin, com `Pepe.Plugins.config/3` (o nome é o nome do pacote no manifesto, e o terceiro argumento é um valor por omissão):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

Um padrão comum é preferir o valor vindo do painel e só recuar para uma variável de ambiente se ele não existir, de forma a que o plugin funcione tanto se o operador preencher o formulário como se preferir exportar uma variável (é exatamente o que faz o exemplo do Google, a seguir).

## Exemplo: o plugin de ferramentas do Google Workspace

O `examples/plugins/google/google.exs` traz quatro ferramentas dentro de um único ficheiro:

| Ferramenta | O que faz |
|------|--------------|
| `gcal_upcoming` | Lista os próximos eventos do Google Calendar principal |
| `gcal_create_event` | Cria um evento (resumo, início, fim, descrição) |
| `gmail_search` | Pesquisa no Gmail e devolve o remetente e o assunto de cada correspondência |
| `gmail_send` | Envia um email em texto simples |

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

A autenticação usa um token bearer OAuth2 resolvido no momento da chamada, sem nada sensível embutido no código. Ou exportas um token de acesso já pronto (a via mais rápida, mas expira ao fim de cerca de uma hora):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

ou então um refresh token (sobrevive à expiração, e o plugin gera um token de acesso novo a cada chamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Consegues estes valores criando um cliente OAuth (do tipo "Desktop app") num projeto do Google Cloud, com as APIs de Calendar e Gmail ativadas, depois de correres o fluxo de consentimento uma vez para os âmbitos que vais usar. Ou, em alternativa, preenches os mesmos campos na janela de Configurar do próprio plugin, guardando sempre os segredos como referências `${ENV_VAR}`.

Eis o código completo de uma das ferramentas, para veres o padrão de ponta a ponta:

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

> Tu: o que tenho na agenda amanhã, e envia um resumo por email para sam@example.com
>
> Agente: (invoca gcal_upcoming, depois gmail_send) Tens 3 eventos amanhã. Enviei o resumo por email para sam@example.com.

## Exemplo: o plugin de canal Chatwoot

`examples/plugins/chatwoot/` mostra a outra forma possível: um **canal**, não uma ferramenta. Regista um fornecedor `chatwoot` para o Pepe conseguir ficar atrás de uma caixa de entrada do [Chatwoot](https://www.chatwoot.com), a fazer de agente de IA, em todos os canais que o Chatwoot já cobre (WhatsApp, widget web, Instagram, e por aí fora).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Transferência nativa para um humano, sem nenhuma colagem extra.** O Chatwoot já transporta o sinal de transferência em todo o webhook: o `status` da própria conversa. O plugin implementa o `parse/1` para só responder a conversas marcadas como `pending` (ainda a cargo do bot); no instante em que um atendente humano assume a conversa (`open`), o Pepe fica em silêncio, e só volta a falar quando ela regressa a `pending`.

**Como configurar, do lado do Chatwoot:** cria um AgentBot e aponta o seu webhook de saída para `https://O_TEU_HOST/webhooks/<project>/chatwoot/<slug>`. A ligação guarda `base_url`, `account_id` e um `api_token` (como `${ENV_VAR}`) através de `config_schema/0`, tudo preenchido a partir do painel, no mesmo padrão de Configurar de qualquer outro plugin.

> Esta é uma de duas formas mutuamente exclusivas de operar o WhatsApp: **ou** o WhatsApp direto no Pepe (o fornecedor incorporado `whatsapp`), **ou** o WhatsApp através do Chatwoot com o Pepe por trás dele (este plugin). Nunca ligues o mesmo número às duas ao mesmo tempo.

## Entregar um ficheiro, e não só texto

O `run/2` de uma ferramenta só devolve texto, sempre. Para entregares um ficheiro a sério (uma folha de cálculo, um PDF) à pessoa do outro lado da conversa, não vale a pena reinventar a entrega: chama a ferramenta incorporada `send_file` com um caminho, e o Pepe trata de resolver o canal a partir da sessão e de o entregar lá. Concede `send_file` a um agente e a funcionalidade fica pronta a usar pela conversa, em qualquer canal cujo fornecedor já tenha implementado `deliver_file/4`.

## Checklist

**Ao escrever uma ferramenta:**

1. Implementa `name/0`, `spec/0` e `run/2`; dá-lhe um nome diferente de todas as incorporadas.
2. Devolve `{:ok, text}` ou `{:error, message}` a partir de `run/2`, escrito a pensar em quem o modelo vai ler.
3. Precisas de credenciais ou de opções? Inclui um `manifest.json` com um array `config`, e lê-as depois com `Pepe.Plugins.config/3`.

**Ao escrever um canal:**

1. Implementa `name/0`, `verify/2`, `authenticate/3`, `parse/1` e `deliver/3`; acrescenta `config_schema/0` se precisares de credenciais configuradas pelo painel.
2. Só acrescentes `respond/3` se o protocolo da plataforma exigir mesmo uma resposta síncrona antes de qualquer trabalho do agente; e só `deliver_file/4` se conseguir receber anexos.

**Seja qual for o caso:** analisa-o primeiro (`pepe plugin scan SRC` ou `manage_plugin scan`), instala-o, revê o que a verificação encontrou, e só depois concede a ferramenta a um agente (pela CLI, pelo painel, ou por `enable_tool`/`manage_agent` na conversa); um canal não precisa de nenhuma concessão especial, fica ativo assim que é instalado.
