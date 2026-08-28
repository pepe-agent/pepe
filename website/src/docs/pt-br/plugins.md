---
title: Plugins
description: Dê ao Pepe ferramentas e canais próprios instalando plugins com a configuração deles.
---

Um plugin é um arquivo que você instala para ensinar algo novo ao Pepe, sem rebuild e sem reiniciar nada: solta o arquivo ali e já funciona. A grande maioria dos plugins faz uma de duas coisas, adiciona uma **ferramenta** que o modelo pode chamar, ou adiciona um **provedor de canal** (uma nova plataforma de mensagens baseada em webhook). Esta página cobre esses dois formatos em profundidade, de longe os mais comuns, e passa mais rápido pelos demais logo abaixo.

Um plugin também pode assumir outros formatos: um **canal de conexão persistente** (que precisa de um websocket de longa duração, não só um webhook, veja [Slots](/docs/slots)), uma **rota HTTP própria** (um callback de OAuth, um endpoint personalizado, veja abaixo), um **provedor de áudio em tempo real** (voz duplex, também abaixo), um **adaptador de protocolo de modelo**, um **hook** (reescreve o conteúdo da conversa de verdade, encadeado e em linha, veja abaixo), uma **policy** (veta uma chamada de ferramenta, ou uma execução inteira, antes que ela aconteça; uma checagem que não conseguiu rodar conta como recusa, então falha fechada), ou um **observador de execução** (observa o loop de fora, somente leitura, o único formato incapaz de afetar qualquer coisa). Um plugin ainda pode ocupar um [**slot**](/docs/slots): busca de memória, busca web, o sandbox onde um comando shell roda, a compactação de conversa, ou o loop de raciocínio inteiro.

Por trás disso, todo plugin é Elixir compilado em tempo de execução a partir de `~/.pepe/plugins/`, e cada módulo é comparado com o formato (ou formatos) que ele implementa.

## O behaviour Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Finalidade |
|---|---|
| `name/0` | O nome de função que o modelo chama, por exemplo `"read_file"`. Precisa ser único entre todas as ferramentas; numa colisão de nome com uma ferramenta embutida, a embutida sempre vence. |
| `spec/0` | A especificação de função no estilo OpenAI: nome, descrição em linguagem simples e um JSON Schema para os parâmetros. É isso que o modelo lê para decidir quando e como chamar a ferramenta. |
| `run/2` | Executa a chamada. `args` são os argumentos já decodificados (um mapa com chaves em string); `ctx` carrega o contexto da execução atual (veja abaixo). Devolva `{:ok, text}` ou `{:error, message}`: de qualquer forma o retorno vira uma string e volta para o modelo, então escreva pensando em quem vai ler do outro lado. |

`Pepe.Tools.Tool.function/3` monta o envelope da especificação para você; você só preenche nome, descrição e parâmetros.

Uma ferramenta completa e funcional, pronta para salvar como `.exs` e instalar (veja mais abaixo):

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

Vale a pena manter essa segunda cláusula de `run/2`: se o modelo esquecer de mandar um argumento obrigatório, é melhor devolver um erro claro do que deixar quebrar (uma quebra também é capturada, mas uma mensagem sob medida ajuda o modelo a se recuperar já no próximo turno).

O segundo argumento de `run/2`, **`ctx`**, carrega a execução atual: `ctx[:agent]` (o agente em execução, por exemplo `%{name: "assistant"}`), `ctx[:session_key]` (a conversa ao vivo, ausente quando é uma execução de um turno só) e `ctx[:cwd]` (o diretório de trabalho). Trate cada chave como opcional. Uma ferramenta que lê ou escreve arquivos resolve caminhos por `Pepe.Agent.Workspace`; já uma que chama uma API externa costuma ignorar `ctx` de vez e usar direto o cliente HTTP `Req`, que já vem incluso, sem precisar de nenhuma dependência a mais.

## O behaviour Channel provider

Um provedor de canal ensina o Pepe a falar uma plataforma de mensagens nova, por cima do webhook de entrada genérico que já existe: nenhuma rota nova, só mais um módulo no registro.

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
| `verify/2` | sim | Responde o handshake `GET` da plataforma no momento em que você registra a URL do webhook. `{:ok, challenge}` ou `:error` se o provedor não tiver esse handshake. |
| `authenticate/3` | sim | Confere a assinatura de um `POST` de entrada contra o segredo da conexão. `:ok` aceita, `:error` descarta. |
| `parse/1` | sim | Normaliza um payload decodificado em zero ou mais mensagens `%{from, text, id}`, ou devolve `:ignore` quando não há nada ali para agir (recibos, atualizações de status). |
| `deliver/3` | sim | Envia uma resposta em texto para `to` (um endereço no formato do provedor: número de telefone, id de canal etc). |
| `label/0` | não | Rótulo legível para o painel (usa `name/0` quando ausente). |
| `config_schema/0` | não | Campos que o painel renderiza para configurar uma conexão, no mesmo formato do array `config` de um manifesto de plugin (mais abaixo). |
| `respond/3` | não | Uma resposta HTTP **síncrona** ao `POST` bruto, para protocolos que exigem uma antes de qualquer trabalho do agente (o desafio de verificação de URL do Slack, o `PING` do Discord). `{:reply, status, content_type, body}`, ou `:cont` para cair em `parse/1`. |
| `deliver_file/4` | não | Envia um arquivo como anexo. Sem essa implementação, o `send_file` simplesmente avisa que o canal não recebe arquivos. |
| `addressed?/2` | não | Esse payload se dirige ao bot, então merece resposta? Permite que um provedor honre `require_mention` em grupos (o padrão sem essa função é considerar sempre endereçado). |
| `deliver_blocks/3` | não | Renderiza conteúdo estruturado (veja [Blocos de apresentação](#blocos-de-apresentação) logo abaixo) na UI nativa da plataforma. Sem ela, a ferramenta `send_presentation` ainda entrega o conteúdo, só que achatado em texto simples via `deliver/3`. |

### Blocos de apresentação

Uma ferramenta pode mandar conteúdo mais rico que texto simples, uma tabela, uma fileira de botões, através da ferramenta `send_presentation` e do schema de bloco compartilhado `Pepe.Presentation`:

```
%{"type" => "text", "text" => "..."}
%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}
%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}
```

Hoje o Slack já renderiza isso como Block Kit de verdade (uma `section` por bloco de texto ou tabela, um bloco `actions` com botões reais). Um provedor que ainda não implementou `deliver_blocks/3` continua recebendo o conteúdo mesmo assim: `Pepe.Presentation.to_text/1` achata tudo em texto simples e legível, entregue pelo `deliver/3` normal do provedor. Resultado prático: uma ferramenta que manda blocos funciona em qualquer canal desde já, e só ganha riqueza visual onde um provedor se deu ao trabalho de renderizar.

## O behaviour PluginRoute: uma rota HTTP própria de um plugin

O contrato de evento de entrada do `Pepe.Webhooks.Provider` é fixo, um único formato, pensado para plataformas de chat. O `Pepe.PluginRoute` existe para o que precisa de rota própria: um callback de redirecionamento OAuth que tem que cair no domínio público do próprio Pepe, um endpoint REST/RPC sob medida.

```elixir
@callback route_prefix() :: String.t()
@callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()
```

`call/2` recebe o `Plug.Conn` bruto (já passado pelo parsing de corpo do próprio endpoint) e os segmentos de caminho depois do seu prefixo: controle total, igual a qualquer Plug escrito à mão, já que o Pepe não tem como prever todo formato que o protocolo de um plugin possa exigir. Um `call/2` que quebra responde `500` e não derruba nem o processo da requisição nem mais nada junto com ele.

**Construindo uma rota, passo a passo:**

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
3. **Habilite a rota explicitamente.** Reivindicar um prefixo no código não expõe nada sozinho; é preciso um segundo opt-in, deliberado, porque uma rota, ao contrário de uma ferramenta, responde a qualquer requisição de entrada, não só àquelas que o próprio modelo do agente decidiu fazer:

   ```bash
   pepe plugin route list                 # todo plugin instalado que reivindica rota, habilitado ou não
   pepe plugin route enable weather_oauth # agora acessível em /plugin-routes/weather_oauth/...
   pepe plugin route disable weather_oauth
   ```

4. Aponte o que precisar chegar até ela, a URL de redirecionamento de um app OAuth, um remetente de webhook, para `https://seu-dominio/plugin-routes/weather_oauth/...`. Os segmentos de caminho depois do prefixo chegam no segundo argumento de `call/2`.

## O behaviour Realtime provider: áudio duplex

Nenhum outro ponto de extensão do Pepe mantém um stream contínuo e de mão dupla, uma chamada de ferramenta, um webhook, um ocupante de slot, todos são request/response ou disparo único. O `Pepe.Realtime.Provider` é essa peça que faltava: um plugin fica dono de tudo sobre como o áudio de entrada vira uma resposta de saída (um modelo de tempo real hospedado, um pipeline de STT em streaming seguido de TTS), e um canal WebSocket novo carrega os bytes.

```elixir
@callback name() :: String.t()
@callback start(agent :: map(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}
@callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}
@callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}   # opcional
@callback stop(session :: term()) :: :ok
```

Um cliente entra em `realtime:<agent_name>` (`realtime:default` para o agente padrão) com `{"provider": "your_provider_name"}` no payload de entrada, e a partir daí manda pedaços binários pelo evento `"audio"`. O `sink` de `start/3` é o pid para onde os eventos voltam enquanto a sessão durar: `{:realtime_audio, chunk}`, `{:realtime_text, text}` ou, se o provedor encerrar a sessão por conta própria, `{:realtime_stopped, reason}`. É aditivo, não um slot: dá para ter vários provedores instalados ao mesmo tempo, e cada cliente escolhe um pelo nome, por conexão; nada precisa ser habilitado globalmente do jeito que o `Pepe.PluginRoute` exige. O Pepe não traz nenhum provedor de tempo real de fábrica, esse é justamente o ponto de extensão que cabe a um plugin preencher.

**Construindo um, passo a passo:**

1. Escreva um módulo implementando `name/0`, `start/3`, `push_audio/2`, `stop/1` e, opcionalmente, `push_text/2`. O exemplo abaixo é um provedor eco: ele devolve qualquer áudio que recebe, mais uma legenda a cada pedaço. Já serve para desenvolver um cliente contra ele antes mesmo de existir um backend real de STT/TTS ou de modelo hospedado:

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

   Aqui, o próprio argumento `sink` de `start/3` faz as vezes de termo de sessão, já que esse provedor não tem nenhuma conexão ou processo real para rastrear. Um provedor que fala de verdade com um upstream (um modelo hospedado, um pipeline local de STT/TTS) devolveria algo que identifica *esse* upstream, e usaria o `sink` só para mandar eventos de volta.

2. Salve como `~/.pepe/plugins/echo_realtime.exs` e instale:
   `pepe plugin install ~/.pepe/plugins/echo_realtime.exs`. Não há mais nada para habilitar: um provedor de tempo real não tem slot para fixar nem rota para ligar, fica ativo assim que é instalado, só esperando um cliente pedir por ele pelo nome.
3. No cliente, entre em `realtime:<agent_name>` usando o WebSocket já existente (`/socket/websocket`), nomeando o provedor no payload:

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

4. Depois de entrar, mande pedaços binários pelo evento `"audio"`; os eventos `{:realtime_audio, ...}`/`{:realtime_text, ...}` voltam do mesmo jeito que qualquer outro push de canal.

## O behaviour Hook: mutação de verdade no conteúdo

Um hook reescreve o conteúdo da conversa de fato, de forma síncrona e em linha, no mesmo caminho onde `pii_redact`, `llm_redact`, `http_redact` e `presidio` já rodam. É assim que um plugin de compactação de contexto ou de censura de conteúdo faz trabalho de verdade, e não deve ser confundido com um run observer (mais abaixo), que só consegue observar.

```elixir
@callback name() :: String.t()
@callback stages() :: [:inbound | :outbound | :learn | :tool_result]
@callback run(stage, text :: String.t(), settings :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:ok, String.t(), [%{"fake" => String.t(), "real" => String.t()}]}
```

`:inbound` roda no texto do usuário antes de o modelo vê-lo; `:outbound`, na resposta antes de ela voltar; `:tool_result`, na saída bruta de uma ferramenta antes de ela entrar na conversa. Um agente adere a hooks pelo nome (`mix pepe agent add NOME --hooks seu_hook,pii_redact`); um hook de plugin soma-se aos quatro que já vêm embutidos, e num empate de nome o embutido sempre ganha, então escolha um nome diferente de `pii_redact`, `llm_redact`, `http_redact` e `presidio`.

Hooks se encadeiam: com `--hooks bracket,exclaim`, `exclaim` recebe o texto já alterado por `bracket`, em ordem, sequencialmente, cada um vendo a saída do anterior, nunca um fan-out. Devolva o texto (mudado ou não) e, se quiser que os valores voltem restaurados na saída, uma lista de entradas de mapa reversível (`fake` para o token, `real` para o valor que ele substituiu).

**É fail-open, de propósito**: um hook que levanta uma exceção cai de volta para o texto de entrada em vez de quebrar o turno inteiro. Um hook muta ou censura, nunca bloqueia. Para vetar uma chamada de vez, existe o `Pepe.Permissions.Policy` logo abaixo, um mecanismo deliberadamente diferente e mais estreito.

## O behaviour Policy: vetando uma chamada de ferramenta

Um plugin de policy pode recusar uma chamada de ferramenta antes que ela rode, por um motivo que só o seu plugin conhece (uma regra da empresa, um serviço externo de allowlist, um limitador de taxa).

```elixir
@callback name() :: String.t()
@callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

Toda policy instalada é consultada em **cada** chamada de gate, para todo agente ao qual ela se aplica. Diferente de um hook, não é opt-in, já que instalar uma policy só pode adicionar restrição, nunca tirar. Ela é checada antes da própria lógica de pré-aprovação do Pepe, então uma policy consegue vetar até uma chamada que o operador já tinha marcado como `:always`-aprovada. Sem chegar a uma recusa total, `:ask` (ou `{:ask, reason}`) obriga um humano a olhar para uma chamada que, de outro jeito, teria sido pré-aprovada em silêncio, com o motivo aparecendo junto do prompt. Entre todas as policies instaladas, vale sempre a mais restritiva: `:deny` supera `:ask`, que supera `:allow`.

O alcance de "se aplica a" ainda pode ser restringido, mas só pelo operador, nunca pelo próprio agente, o que anularia todo o propósito:

```bash
pepe policy list                                      # toda policy instalada + seu escopo
pepe policy scope no_bash_policy --agents support --projects acme
pepe policy scope no_bash_policy --clear              # volta a aplicar em todo lugar
```

ou direto no `config.json`, em `"policy_scope"`, pelo nome da policy. Sem uma entrada para o nome de uma policy, ela fica sem escopo definido, valendo para todo agente: o padrão original, e o comportamento de sempre. Um agente nunca consegue se excluir sozinho de uma policy; só quem configura o escopo decide onde ela é de fato consultada.

**Fail-closed: a única exceção deliberada em todo esse sistema de plugins.** Qualquer outra superfície de plugin do Pepe degrada para "como se não estivesse instalada" numa falha ou timeout. Um plugin de policy funciona ao contrário: um `check/3` que levanta exceção, trava além do timeout, ou devolve qualquer coisa que não seja um `:allow` explícito, **nega a chamada**. Uma checagem de segurança que não conseguiu rodar não é a mesma coisa que uma que passou.

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

Adicione um `check_run/3` opcional para vetar uma execução inteira, antes de qualquer chamada de ferramenta e antes até da primeira chamada ao modelo. É a única forma de dizer "não processe essa mensagem de jeito nenhum" (um remetente banido, um limite de taxa por mensagem), já que `check/3` nunca dispara num turno que não chega a chamar nenhuma ferramenta:

```elixir
@callback check_run(agent :: map(), first_message :: String.t(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

## O behaviour RunObserver

Um observador de execução acompanha o turno de um agente de fora, útil para logging, métricas ou alertas sobre o que um agente faz, sem tocar no que ele de fato faz. É estritamente observacional: nunca vê o histórico de mensagens da conversa, não consegue bloquear um turno nem mudar nada nele, só descobrir o que já aconteceu, depois do fato.

```elixir
@callback name() :: String.t()
@callback subscriptions() :: [atom()]
@callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
```

`subscriptions/0` nomeia os tipos de evento que você quer receber, qualquer um entre `:run_start`, `:tool_call`, `:tool_denied`, `:tool_result`, `:assistant`, `:assistant_delta`, `:failover`, `:output_cap`, `:usage`, `:inline`, `:done`, `:error` e `:run_end`. `handle_event/3` é chamado uma vez para cada evento assinado, na mesma ordem em que o turno os produziu. `payload` é a própria tupla do evento (por exemplo, `{:tool_result, "web_search", "..."}`), com uma exceção: `:tool_call` chega como `{:tool_call, name}`, sem os argumentos, porque eles ainda não passaram pela redação e podem carregar segredos.

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

O despacho é assíncrono e isolado: um observador travado ou que quebra jamais deixa a conversa observada mais lenta, muito menos a derruba. Um que falhe 3 vezes seguidas é desabilitado, e não só naquela execução que disparou o problema, mas em todas as futuras, então um observador quebrado nunca fica pagando o próprio custo de detecção para sempre, nem enche seus logs repetindo a mesma falha. E não há nada para conceder a um agente aqui: instalado já é habilitado.

## O registro

`Pepe.Tools.all/0` devolve as ferramentas embutidas seguidas de cada ferramenta de plugin carregada; `Pepe.Webhooks` faz o mesmo para provedores de canal. Embutidos e plugins acabam unidos num único registro, e os dois formatos resolvem uma colisão de nome de jeitos opostos. Para ferramentas, a embutida sempre prevalece, então escolha um nome diferente de `read_file`, `web_search` e do resto de `pepe tools`. Para provedores de canal é o contrário: quem prevalece é o plugin de mesmo nome, e é assim que você troca um provedor que já vem junto pela sua própria versão dele.

### Concedendo uma ferramenta a um agente

Instalar um plugin não entrega as ferramentas dele a todo agente de uma vez; só ficam expostas as ferramentas que estão listadas naquele agente específico, sob o mesmo controle de uma embutida.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Painel:** abra o agente em Agentes e marque a ferramenta; ferramentas de plugin aparecem lado a lado com as embutidas.

**Pela conversa:** um agente com `enable_tool` consegue ligar uma ferramenta para si mesmo:

> Você: ative a ferramenta reverse_text
>
> Agente: reverse_text ativada; você já pode usar a partir da sua próxima mensagem

Para conceder uma ferramenta a um agente *diferente*, a ação `add_tool` de `manage_agent` resolve (limitada aos agentes que quem pede tem permissão de gerenciar, e sempre confirma com você antes):

> Você: dê ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirma?

## Onde os plugins ficam e como eles carregam

Os plugins moram em `~/.pepe/plugins/` (respeitando `PEPE_HOME`). O Pepe varre essa pasta recursivamente atrás de arquivos `.exs`, compila cada um uma vez, e só recompila quando o arquivo muda no disco. Solte um arquivo lá e ele já funciona, sem reiniciar nada; edite, e a mudança entra em vigor já na próxima chamada de ferramenta. Um único arquivo pode definir vários módulos (o exemplo do Google logo abaixo traz quatro).

Um plugin tem um de dois formatos: um `.exs` solto, ou um **pacote** (um diretório com `manifest.json` e um ou mais arquivos `.exs`).

Compilar em tempo de execução carrega uma limitação honesta: **um plugin não pode trazer junto uma dependência externa nova.** O Elixir resolve e compila dependências em tempo de build, então um plugin só pode contar com as bibliotecas que o Pepe já traz (`Req`, `Jason`, a biblioteca padrão e o resto do que já vem embutido). Um plugin que precisa de uma biblioteca inédita não é mais um drop-in, ele exigiria recompilar o próprio Pepe. Na prática isso quase nunca pesa, porque uma ferramenta que chama uma API HTTP e um provedor de canal como o Chatwoot não precisam de nada além do que já está incluso, e é justamente por isso que instalam sem drama.

## Instalando um plugin

A fonte pode ser um arquivo local, um diretório local, um `.tar.gz`, uma URL para qualquer um desses, ou uma referência do [PepeHub](https://hub.pepe-agent.com); o `install` desempacota o que você der na pasta de plugins. Uma URL de repositório do GitHub é baixada como o pacote de código-fonte e extraída, usando a branch padrão (`main`, depois `master`) quando nenhuma é indicada; acrescente `/tree/<branch>` na URL para escolher outra. Um `.tar.gz`, local ou remoto, é extraído e colocado sob o `name` do próprio manifesto. Um diretório é copiado do jeito que está, e um `.exs` solto é copiado direto.

Uma referência do PepeHub pode vir na forma curta `@handle/nome`, ou como a própria URL da página do pacote copiada de `hub.pepe-agent.com`: as duas resolvem para o mesmo pacote, então qualquer uma serve. Se você apontar `plugin install` para um nome que na verdade é uma skill no PepeHub, e não um plugin, a instalação falha com uma mensagem clara pedindo para usar `skill install` em vez disso.

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin install @jhonathas/backup-tool
pepe plugin list
pepe plugin remove google
```

**Painel:** a página de Plugins aceita uma URL do GitHub, uma URL `.tar.gz` ou um caminho local; você marca uma caixa confirmando que confia na fonte e clica em Instalar. Plugins instalados aparecem com um botão Remover e, quando declaram configurações, também um botão Configurar.

**Pela conversa, com `manage_plugin`:** um agente que tenha essa ferramenta pode instalar em seu nome: primeiro faz `scan` de uma fonte para ver o que ela faz, depois `install`, `list`, `remove`. Passa pela mesma varredura de segurança da CLI, mas sem a válvula de escape `--force`: um veredito perigoso é sempre recusado quando vem da conversa, e o agente vai te orientar a revisar o código e rodar `--force` você mesmo, direto do terminal, se ainda assim quiser seguir em frente.

## A varredura de segurança

Um plugin é Elixir comum, com acesso total ao aplicativo em execução; instalar um é uma decisão de confiança, igual à de instalar qualquer outro software na sua máquina. Instale só de uma fonte em que você confia, e sempre que possível fixe uma versão ou um commit específico.

Antes de o plugin ser gravado em disco, o `Pepe.Skills.Sentinel` varre o código. Ele lê a **estrutura** do código, a árvore sintática, não só o texto cru, o que permite sinalizar chamadas perigosas com precisão:

- lançar shells (`System.cmd`, `:os.cmd`),
- eval dinâmico (`Code.eval_string`),
- desserialização insegura (`:erlang.binary_to_term`),
- chamadas destrutivas no sistema de arquivos (`File.rm_rf`),
- exaustão de átomos (`String.to_atom`),
- leitura do ambiente ou de caminhos com segredos (`~/.ssh`, a configuração do Pepe),
- acesso à rede.

Como a análise é pela estrutura, e não pelas palavras, ela também pega as formas com alias e as formas Erlang dessas mesmas chamadas, e não se confunde quando as mesmas palavras aparecem dentro de um comentário ou de uma string. Ela nunca chega a executar o código, e sempre devolve um de três vereditos:

- **limpo**: nenhum achado.
- **cautela**: sinalizado, mas com frequência legítimo (um plugin de canal *deveria mesmo* fazer chamadas de rede); é exibido, mas não bloqueia.
- **perigo**: nenhum bom motivo para aquilo estar ali; bloqueia a instalação.

```bash
pepe plugin scan ./my_plugin.exs        # varre sem instalar
pepe plugin install ./risky.exs --force # prossegue mesmo assim, depois de você já ter revisado
```

<div class="note"><strong>Um plugin roda com acesso total.</strong> A varredura é uma rede de segurança, não um substituto para ler o código você mesmo.</div>

## O manifesto e o diálogo de Configurar

O `manifest.json` de um pacote dá nome e descrição a ele e, o mais útil de tudo, declara as configurações de que precisa. Do exemplo do Google que já vem incluso:

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

Cada entrada de `config` descreve um campo: `key` (o nome que o seu código lê), `label` (mostrado no formulário), `type` (`"text"`, `"secret"` para uma entrada mascarada, ou `"select"` com uma lista `"options"`), e um `hint` opcional. O painel lê esse array e monta o diálogo de Configurar sozinho; um plugin novo não exige nenhuma tela nova. Um valor pode ser uma referência `${ENV_VAR}`, guardada literalmente e resolvida a partir do ambiente só na hora da leitura, então segredos nunca ficam expandidos dentro do arquivo de configuração.

Leia uma configuração salva de dentro do código do seu plugin com `Pepe.Plugins.config/3` (o primeiro argumento é o nome do pacote no manifesto; o terceiro é um valor padrão):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

Um padrão bem comum: preferir o valor do painel e só recorrer a uma variável de ambiente se ele faltar, assim o plugin funciona tanto para quem preenche o formulário quanto para quem prefere exportar uma variável (é exatamente isso que o exemplo do Google logo abaixo faz).

## Exemplo: o plugin de ferramentas Google Workspace

`examples/plugins/google/google.exs` traz quatro ferramentas dentro de um único arquivo:

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

Ele se autentica com um token bearer OAuth2 resolvido na hora da chamada, nada sensível fica embutido no código. Dá para exportar um token de acesso já pronto (o caminho mais rápido, mas expira em cerca de uma hora):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

ou, para sobreviver à expiração, um refresh token (o plugin gera um token de acesso novo a cada chamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Você consegue esses valores criando um cliente OAuth (do tipo "Desktop app") num projeto do Google Cloud, com as APIs de Calendar e Gmail habilitadas, depois de rodar o fluxo de consentimento uma vez para os escopos que você vai usar. Ou então preenche os mesmos campos direto no diálogo de Configurar do plugin, guardando os segredos como referências `${ENV_VAR}`.

O código completo de uma dessas ferramentas, mostrando o padrão do começo ao fim:

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

> Você: o que tenho na agenda amanhã, e manda um resumo por e-mail para sam@example.com
>
> Agente: (chama gcal_upcoming, depois gmail_send) Você tem 3 eventos amanhã. Enviei o resumo por e-mail para sam@example.com.

## Exemplo: o plugin de canal Chatwoot

`examples/plugins/chatwoot/` mostra o outro formato: um **canal**, não uma ferramenta. Ele registra um provedor `chatwoot` para o Pepe atuar como o agente de IA por trás de uma caixa de entrada do [Chatwoot](https://www.chatwoot.com), em qualquer canal que o Chatwoot já cubra (WhatsApp, widget web, Instagram, e por aí vai).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Transferência para um humano de forma nativa, sem nenhuma integração extra.** O Chatwoot já carrega o sinal de transferência em todo webhook: o `status` da conversa. O plugin implementa `parse/1` para responder só às conversas marcadas como `pending` (sob controle do bot); no instante em que um atendente humano assume (`open`), o Pepe fica quieto, e só volta a falar quando a conversa retorna para `pending`.

**Configurando no Chatwoot:** crie um AgentBot e aponte o webhook de saída dele para `https://SEU_HOST/webhooks/<project>/chatwoot/<slug>`. A conexão guarda `base_url`, `account_id` e um `api_token` (como `${ENV_VAR}`) via `config_schema/0`, preenchidos pelo painel, no mesmo padrão de Configurar de qualquer outro plugin.

> Essa é uma de duas formas mutuamente exclusivas de rodar WhatsApp: **ou** WhatsApp direto no Pepe (o provedor embutido `whatsapp`) **ou** WhatsApp no Chatwoot com o Pepe atrás dele (este plugin). Nunca conecte o mesmo número às duas ao mesmo tempo.

## Entregando um arquivo, não só texto

O `run/2` de uma ferramenta só devolve texto. Para entregar um arquivo de verdade (uma planilha, um PDF) para a pessoa do outro lado da conversa, não vale a pena reinventar a entrega: basta chamar a ferramenta embutida `send_file` com um caminho, e o Pepe resolve o canal a partir da sessão e entrega o arquivo lá. Conceda `send_file` a um agente e ele simplesmente passa a funcionar pela conversa, em qualquer canal cujo provedor implemente `deliver_file/4`.

## Checklist

**Escrevendo uma ferramenta:**

1. Implemente `name/0`, `spec/0`, `run/2`, com um nome diferente de toda ferramenta embutida.
2. Devolva `{:ok, text}` ou `{:error, message}` de `run/2`, escrito pensando em quem vai ler do outro lado, o modelo.
3. Precisa de credenciais ou opções? Inclua um `manifest.json` com um array `config`, e leia os valores com `Pepe.Plugins.config/3`.

**Escrevendo um canal:**

1. Implemente `name/0`, `verify/2`, `authenticate/3`, `parse/1`, `deliver/3`; some `config_schema/0` se precisar de credenciais configuradas pelo painel.
2. Adicione `respond/3` só se o protocolo da plataforma exigir uma resposta síncrona antes de qualquer trabalho do agente; `deliver_file/4`, só se ela conseguir receber anexos.

**De um jeito ou de outro:** rode a varredura (`pepe plugin scan SRC` ou `manage_plugin scan`), instale, revise o que ela encontrou, e só então conceda a ferramenta a um agente (pela CLI, pelo painel, ou por `enable_tool`/`manage_agent` na conversa). Um canal não precisa dessa concessão: fica ativo assim que é instalado.
