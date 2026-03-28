---
title: Plugins
description: Estenda o Pepe com suas proprias ferramentas (e canais) em tempo de execucao colocando um arquivo Elixir na pasta de plugins. Sem recompilar, sem mexer no nucleo.
---

O Pepe ja vem com um conjunto de ferramentas embutidas: rodar um comando de
shell, ler e escrever arquivos, buscar uma URL, pesquisar na web, enviar um
arquivo para o chat atual e mais. Um plugin permite adicionar as suas proprias
sem tocar no nucleo nem recompilar o aplicativo. Coloque um arquivo na pasta de
plugins e ele funciona na proxima chamada de ferramenta.

Um plugin pode adicionar dois tipos de coisa:

- Uma **ferramenta**. Um modulo pequeno que o modelo pode chamar durante o loop
  do agente. Esse e o caso comum e o foco desta pagina.
- Um **provedor de canal**. Um modulo que ensina o Pepe a conversar com uma nova
  plataforma de mensagens pelo webhook de entrada generico. O mesmo carregador,
  um formato diferente.

## Como uma ferramenta funciona

Um agente roda um loop. Ele chama o modelo, o modelo pode pedir para chamar uma
ou mais ferramentas, o Pepe as executa, devolve os resultados e repete ate o
modelo entregar uma resposta final. Uma ferramenta e uma funcao nomeada que o
modelo tem permissao para chamar. Voce a descreve com uma especificacao JSON
(nome, descricao, parametros) para que o modelo saiba quando e como chama-la, e
voce fornece o codigo que roda quando isso acontece.

Cada ferramenta, embutida ou de plugin, implementa o mesmo contrato de tres
funcoes.

### O comportamento Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

- `name/0` e o nome de funcao que o modelo chama, por exemplo `"read_file"`. Ele
  precisa ser unico entre todas as ferramentas.
- `spec/0` devolve a especificacao de funcao no estilo da OpenAI: um nome, uma
  descricao em linguagem simples e um JSON Schema para os parametros. O modelo le
  isso para decidir quando chamar a ferramenta e quais argumentos passar.
- `run/2` recebe os `args` decodificados (um mapa simples com chaves em string,
  ja parseados a partir do JSON do modelo) e um mapa `ctx` com informacoes sobre
  a execucao atual. Devolve `{:ok, text}` em caso de sucesso ou
  `{:error, message}` em caso de falha. De qualquer forma o resultado vira uma
  string e volta ao modelo como resposta da ferramenta, entao escreva para que o
  modelo leia.

Um auxiliar, `Pepe.Tools.Tool.function/3`, monta para voce o envelope padrao da
especificacao, de modo que voce so preenche o nome, a descricao e os parametros.

### Uma ferramenta minima

Aqui esta uma ferramenta completa e funcional que inverte uma string. Salve como
um arquivo `.exs` e instale (veja abaixo).

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

Esse e o padrao inteiro. A segunda clausula de `run/2` e um bom habito. Se o
modelo chamar a ferramenta sem o argumento obrigatorio, voce devolve um erro
claro em vez de quebrar. Uma quebra tambem e capturada e reportada, mas uma
mensagem sob medida ajuda o modelo a se recuperar na proxima rodada.

### O que tem no ctx

O mapa `ctx` carrega o contexto da execucao atual. As chaves que voce tem mais
chance de usar:

- `ctx[:agent]` e o agente que esta rodando, por exemplo `%{name: "assistant"}`.
- `ctx[:session_key]` identifica a conversa ao vivo quando ha uma (um chat em um
  canal de mensagens, uma sessao WebSocket). Fica ausente em execucoes de um
  turno so.
- `ctx[:cwd]` e o diretorio de trabalho da execucao.

As ferramentas que leem ou escrevem arquivos usam `Pepe.Agent.Workspace` para
resolver caminhos contra o espaco de trabalho persistente do agente. As
ferramentas que falam com o mundo externo (uma API HTTP, um banco de dados)
costumam ignorar o `ctx` por completo. Trate cada chave como opcional e faca a
comparacao de forma defensiva.

<div class="note"><strong>Use o Req incluso para HTTP.</strong> O Pepe ja depende
do cliente HTTP Req, entao seu plugin pode chamar qualquer API web sem uma
dependencia extra. Veja como a ferramenta embutida <code>web_search</code> e o
exemplo do Google mais abaixo fazem isso.</div>

## O registro: como as ferramentas sao encontradas

`Pepe.Tools` e o registro unico. Ele combina duas fontes.

- O conjunto **embutido**, uma lista fixa em `Pepe.Tools`. Inclui `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file` e as ferramentas de gestao que um agente
  usa para operar o runtime por chat (`manage_agent`, `manage_channel`,
  `enable_tool`, `schedule_task` e outras).
- Os **plugins**, descobertos em tempo de execucao a partir da pasta de plugins.

`Pepe.Tools.all/0` devolve as embutidas seguidas de cada ferramenta de plugin
carregada. Quando voce lista as ferramentas de um agente, cada nome e procurado
aqui. Ha uma regra que vale conhecer: em uma colisao de nomes, a embutida ganha.
Voce nao consegue sobrepor `read_file` com um plugin de mesmo nome, entao escolha
um nome distinto para a sua ferramenta.

### Conceder uma ferramenta a um agente

Um plugin instalado nao entrega automaticamente suas ferramentas a todo agente.
So as ferramentas que voce lista em um agente ficam expostas a ele, e cada
chamada ainda passa pela mesma porteira de permissao de uma ferramenta embutida.
Voce concede uma ferramenta de tres maneiras.

**Com a CLI do pepe.** Liste a ferramenta no `--tools` do agente:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**No painel.** Abra o agente em Agentes e marque a ferramenta na lista de
ferramentas dele. As ferramentas do plugin aparecem ao lado das embutidas.

#### Faça por chat

Um agente que tem a ferramenta embutida `enable_tool` pode ligar uma ferramenta
para si mesmo depois que voce instala um plugin, sem que voce mexa na CLI ou no
painel.

> Voce: ative a ferramenta reverse_text
>
> Agente: reverse_text ativada; voce ja pode usar a partir da sua proxima mensagem

`enable_tool` so aceita uma ferramenta que ja existe como embutida ou como plugin
carregado, e a mudanca vale a partir da proxima mensagem do agente. Para conceder
uma ferramenta a um agente *diferente*, um agente com a ferramenta `manage_agent`
pode fazer isso com a acao `add_tool`. Essa ferramenta e limitada aos agentes que
o agente que age tem permissao para gerenciar, e as instrucoes dele mandam
confirmar a mudanca com voce antes de aplicar.

> Voce: de ao agente de suporte a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirma?
>
> Voce: sim
>
> Agente: gmail_search adicionada ao support.

## Onde os plugins ficam e como carregam

Os plugins ficam em `~/.pepe/plugins/` (a pasta base segue `PEPE_HOME` se voce
definir). O Pepe varre essa pasta de forma recursiva atras de arquivos `.exs`,
compila cada um uma vez e faz cache. Quando a data de modificacao de um arquivo
muda, ele e recompilado na chamada seguinte. Coloque um arquivo e ele funciona
sem reiniciar. Edite e a mudanca vale na proxima chamada de ferramenta.

Cada modulo carregado e comparado com o formato que um consumidor espera. Um
modulo que exporta `name/0`, `spec/0` e `run/2` e tratado como uma ferramenta. Um
modulo que exporta `name/0` mais os callbacks de provedor de canal e tratado como
um canal. Um arquivo pode definir varios modulos, entao um unico plugin pode
trazer um punhado de ferramentas relacionadas (o exemplo do Google traz quatro).

## Instalar um plugin

A fonte pode ser um arquivo local, um diretorio local, um arquivo compactado ou
uma URL para qualquer um desses. A URL de um repositorio do GitHub e baixada como
o arquivo de codigo-fonte dele (quando nenhuma branch e indicada, tenta-se `main`
e depois `master`).

**Com a CLI do pepe:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install ./examples/plugins/google
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin install https://example.com/pepe-myplugin.tar.gz
```

Liste o que esta instalado e remova pelo nome:

```bash
pepe plugin list
pepe plugin remove google
```

**No painel.** A pagina de Plugins tem um campo de instalacao que aceita a URL de
um repositorio do GitHub, uma URL `.tar.gz` ou um caminho local. Voce marca uma
caixa confirmando que confia na fonte e entao clica em Instalar. Os plugins
instalados sao listados com um botao Remover e, quando o plugin declara
configuracoes, um botao Configurar (veja abaixo).

Um arquivo `.exs` solto e copiado direto para a pasta de plugins. Um **pacote** e
copiado como pasta. Um pacote e um diretorio que contem um `manifest.json` e um
ou mais arquivos `.exs`.

## A varredura de seguranca

Um plugin e Elixir comum com acesso total ao aplicativo em execucao. Instalar um
e uma decisao de confianca, igual a adicionar qualquer dependencia. Para tornar
essa decisao informada, o Pepe varre o codigo de forma estatica antes de coloca-
lo em disco. A varredura le a arvore de sintaxe procurando padroes perigosos
(lancar shells, chamadas de rede, ofuscacao, ler segredos). Ela nunca executa o
codigo e devolve um de tres vereditos: limpo, cautela ou perigo.

Um veredito de perigo bloqueia a instalacao. Voce pode prosseguir mesmo assim,
depois de revisar o codigo, passando `--force` na CLI (ou o botao "Instalar
mesmo assim" no painel, que aparece apenas apos um veredito de perigo):

```bash
pepe plugin install ./risky_plugin.exs --force
```

Voce tambem pode varrer uma fonte sem instalar:

```bash
pepe plugin scan ./my_plugin.exs
```

<div class="note"><strong>Um plugin roda com acesso total.</strong> E codigo de
nivel administrador. Instale apenas de uma fonte que voce conhece e confia, e leia
antes. A varredura e uma rede de seguranca, nao um substituto para a revisao.</div>

## O manifesto e o dialogo de Configurar

Um pacote pode carregar um `manifest.json`. Ele nomeia o pacote, o descreve,
lista o que fornece e, o mais util, declara as configuracoes de que precisa. Aqui
esta o manifesto do exemplo do Google:

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

O array `config` e a parte interessante. Cada entrada descreve um campo:

- `key` e o nome da configuracao que o seu codigo le.
- `label` e o rotulo humano mostrado no formulario.
- `type` e `"text"`, `"secret"` (entrada mascarada) ou `"select"` (adicione uma
  lista `"options"`).
- `hint` e um texto de ajuda opcional mostrado abaixo do campo.

O painel le esse array e renderiza um dialogo de Configurar para o plugin, entao
um plugin novo nao precisa de uma tela nova. Um valor que voce digita pode ser uma
referencia `${ENV_VAR}`. Ele e guardado como a referencia literal e resolvido a
partir do ambiente apenas na leitura, de modo que os segredos nunca ficam
expandidos no arquivo de configuracao.

### Ler suas configuracoes pelo codigo

Dentro do plugin, leia uma configuracao salva com `Pepe.Plugins.config/3`. Ela
devolve o valor salvo com qualquer referencia `${ENV_VAR}` ja resolvida, ou o
valor padrao quando nao definido:

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

O primeiro argumento e o nome do plugin (o nome do pacote no manifesto). Essa e a
ponte entre o formulario do painel e o seu codigo em execucao. Um padrao comum e
preferir o valor do painel e recorrer a uma variavel de ambiente, de modo que o
plugin funcione tanto se o operador preencher o formulario quanto se exportar uma
variavel.

## Enviar um arquivo de volta ao chat

As ferramentas devolvem texto ao modelo. Quando voce quer entregar um arquivo de
verdade para a pessoa na conversa (uma planilha, um PDF, uma imagem), a
ferramenta embutida `send_file` faz isso. Seu agente produz o arquivo do jeito
que preferir, por exemplo um comando `bash` que consulta um banco de dados e
escreve um `.xlsx`, e entao chama `send_file` com o caminho. O Pepe descobre em
qual canal a conversa esta a partir da sessao e entrega o arquivo la, entao o
agente nunca precisa saber ids de chat nem tokens.

`send_file` recebe um `path` (absoluto, ou relativo ao diretorio de trabalho da
execucao) e um `caption` opcional. Funciona em qualquer canal cujo provedor
suporte anexos (Telegram, WhatsApp, Slack, Discord e outros). Se o canal nao
pode receber arquivos, ou a execucao nao e um chat ao vivo, a ferramenta reporta
isso com clareza ao modelo. Por ser embutida, voce ganha de graca: basta conceder
a ferramenta `send_file` ao agente.

Isso tambem e uma capacidade de chat. Um agente que tem `send_file` vai usa-la
quando voce pedir um arquivo na conversa.

> Voce: exporte os pedidos do mes passado como planilha e me envie aqui
>
> Agente: (roda uma consulta, escreve orders.xlsx, chama send_file) Enviei orders.xlsx para a conversa.

## Exemplo: o plugin do Google Workspace

O Pepe inclui um exemplo completo de plugin em `examples/plugins/google`. Um
unico arquivo `google.exs` define quatro ferramentas:

| Ferramenta | O que faz |
|------|--------------|
| `gcal_upcoming` | Lista os proximos eventos do Google Calendar principal |
| `gcal_create_event` | Cria um evento (resumo, inicio, fim, descricao) |
| `gmail_search` | Busca no Gmail e devolve remetente e assunto das correspondencias |
| `gmail_send` | Envia um e-mail em texto simples |

Instale e conceda as ferramentas a um agente:

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

O plugin mostra o padrao inteiro em um so arquivo: varios modulos de ferramenta
que cada um implementa o comportamento, um pequeno modulo auxiliar compartilhado
para a autenticacao e o HTTP, e um manifesto que impulsiona o dialogo de
Configurar.

### Como ele se autentica

As APIs do Google usam tokens bearer OAuth2. O plugin resolve um token na hora da
chamada, entao nada sensivel fica embutido no codigo. Ele le suas configuracoes
primeiro da configuracao do painel e recorre a variaveis de ambiente, o que
significa que funciona tanto se voce preencher o formulario de Configurar quanto
se exportar variaveis. Ha duas maneiras de fornecer credenciais.

**A. Um token de acesso pronto** (mais rapido; expira em cerca de uma hora):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

**B. Um refresh token** (sobrevive a expiracao; o plugin gera um token de acesso
por chamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Para obter esses valores, crie um cliente OAuth (tipo "Desktop app") em um
projeto do Google Cloud, habilite as APIs do Calendar e do Gmail, e rode o fluxo
de consentimento uma vez para os scopes que voce usa
(`https://www.googleapis.com/auth/calendar` e
`https://www.googleapis.com/auth/gmail.modify`). Voce tambem pode digitar os
mesmos valores no dialogo de Configurar do plugin no painel, guardando os
segredos como referencias `${ENV_VAR}` para mante-los fora do arquivo.

Aqui esta o formato de uma das ferramentas, para voce ver o padrao da API de
ponta a ponta:

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

Uma vez concedidas as ferramentas e configuradas as credenciais, o agente as usa
em conversa normal.

> Voce: o que tenho na agenda amanha, e mande um resumo por e-mail para sam@example.com
>
> Agente: (chama gcal_upcoming, depois gmail_send) Voce tem 3 eventos amanha. Enviei o resumo por e-mail para sam@example.com.

## Provedores de canal, em resumo

O mesmo carregador impulsiona os canais de mensagens. Um plugin de canal e um
modulo que exporta `name/0` mais os callbacks de provedor do webhook de entrada
(`verify`, `authenticate`, `parse`, `deliver` e, opcionalmente, `respond`,
`deliver_file` e um `config_schema` para o proprio dialogo de Configurar). Uma
vez instalado, o provedor fica acessivel na rota do webhook de entrada generico
sem adicionar uma nova URL, e aparece entre os provedores de canal em
`pepe plugin list`. O exemplo incluso do Chatwoot em `examples/plugins/chatwoot`
roda o Pepe atras de uma caixa de entrada do Chatwoot com transferencia nativa
para um humano. A pagina de canais de mensagens cobre o contrato do provedor por
completo.

## Checklist para escrever a sua propria ferramenta

1. Escreva um modulo que implemente `name/0`, `spec/0` e `run/2`.
2. De a ela um nome unico (as embutidas ganham uma colisao, entao evite os nomes
   delas).
3. Devolva `{:ok, text}` ou `{:error, message}` no `run/2`, escrito para o modelo
   ler.
4. Se ela precisa de credenciais ou opcoes, inclua um `manifest.json` com um
   array `config` e leia com `Pepe.Plugins.config/3`.
5. Instale com `pepe plugin install`, revise a varredura e conceda a ferramenta a
   um agente (CLI, painel ou por chat com `enable_tool`).
