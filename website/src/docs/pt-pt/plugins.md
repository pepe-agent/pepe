---
title: Plugins
description: Amplie o Pepe com as suas proprias ferramentas (e canais) em tempo de execucao colocando um ficheiro Elixir na pasta de plugins. Sem recompilar, sem mexer no nucleo.
---

O Pepe ja traz um conjunto de ferramentas incorporadas: executar um comando de
shell, ler e escrever ficheiros, obter um URL, pesquisar na web, enviar um
ficheiro para a conversa atual e muito mais. Um plugin permite acrescentar as
suas proprias sem tocar no nucleo nem recompilar a aplicacao. Coloque um ficheiro
na pasta de plugins e ele funciona na proxima chamada de ferramenta.

Um plugin pode acrescentar dois tipos de coisa:

- Uma **ferramenta**. Um modulo pequeno que o modelo pode invocar durante o ciclo
  do agente. Este e o caso comum e o foco desta pagina.
- Um **fornecedor de canal**. Um modulo que ensina o Pepe a comunicar com uma
  nova plataforma de mensagens atraves do webhook de entrada generico. O mesmo
  carregador, um formato diferente.

## Como funciona uma ferramenta

Um agente corre um ciclo. Invoca o modelo, o modelo pode pedir para invocar uma
ou mais ferramentas, o Pepe executa-as, devolve os resultados e repete ate o
modelo entregar uma resposta final. Uma ferramenta e uma funcao com nome que o
modelo esta autorizado a invocar. Descreve-a com uma especificacao JSON (nome,
descricao, parametros) para que o modelo saiba quando e como invoca-la, e o
utilizador fornece o codigo que corre quando isso acontece.

Cada ferramenta, incorporada ou de plugin, implementa o mesmo contrato de tres
funcoes.

### O comportamento Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

- `name/0` e o nome de funcao que o modelo invoca, por exemplo `"read_file"`. Tem
  de ser unico entre todas as ferramentas.
- `spec/0` devolve a especificacao de funcao ao estilo da OpenAI: um nome, uma
  descricao em linguagem simples e um JSON Schema para os parametros. O modelo le
  isto para decidir quando invocar a ferramenta e que argumentos passar.
- `run/2` recebe os `args` descodificados (um mapa simples com chaves em texto,
  ja analisados a partir do JSON do modelo) e um mapa `ctx` com informacao sobre
  a execucao atual. Devolve `{:ok, text}` em caso de sucesso ou
  `{:error, message}` em caso de falha. De qualquer forma, o resultado e
  convertido em texto e devolvido ao modelo como resposta da ferramenta, por isso
  escreva-o para o modelo ler.

Um auxiliar, `Pepe.Tools.Tool.function/3`, constroi por si o envelope padrao da
especificacao, de modo que so preenche o nome, a descricao e os parametros.

### Uma ferramenta minima

Aqui esta uma ferramenta completa e funcional que inverte um texto. Guarde-a como
um ficheiro `.exs` e instale-a (ver abaixo).

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

Este e o padrao por inteiro. A segunda clausula de `run/2` e um bom habito. Se o
modelo invocar a ferramenta sem o argumento obrigatorio, devolve um erro claro em
vez de rebentar. Uma falha tambem e apanhada e comunicada, mas uma mensagem feita
a medida ajuda o modelo a recuperar na jogada seguinte.

### O que ha no ctx

O mapa `ctx` transporta o contexto da execucao atual. As chaves que tem mais
probabilidade de usar:

- `ctx[:agent]` e o agente que esta a correr, por exemplo `%{name: "assistant"}`.
- `ctx[:session_key]` identifica a conversa em direto quando existe (uma conversa
  num canal de mensagens, uma sessao WebSocket). Fica ausente nas execucoes de um
  so turno.
- `ctx[:cwd]` e a diretoria de trabalho da execucao.

As ferramentas que leem ou escrevem ficheiros usam `Pepe.Agent.Workspace` para
resolver caminhos em relacao ao espaco de trabalho persistente do agente. As
ferramentas que comunicam com o mundo exterior (uma API HTTP, uma base de dados)
costumam ignorar o `ctx` por completo. Trate cada chave como opcional e faca a
correspondencia de forma defensiva.

<div class="note"><strong>Use o Req incluido para HTTP.</strong> O Pepe ja depende
do cliente HTTP Req, por isso o seu plugin pode chamar qualquer API web sem uma
dependencia adicional. Veja como a ferramenta incorporada <code>web_search</code>
e o exemplo da Google mais abaixo o fazem.</div>

## O registo: como as ferramentas sao encontradas

`Pepe.Tools` e o registo unico. Combina duas fontes.

- O conjunto **incorporado**, uma lista fixa em `Pepe.Tools`. Inclui `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file` e as ferramentas de gestao que um agente
  usa para operar o runtime por conversa (`manage_agent`, `manage_channel`,
  `enable_tool`, `schedule_task` e outras).
- Os **plugins**, descobertos em tempo de execucao a partir da pasta de plugins.

`Pepe.Tools.all/0` devolve as incorporadas seguidas de cada ferramenta de plugin
carregada. Quando lista as ferramentas de um agente, cada nome e procurado aqui.
Ha uma regra que convem conhecer: numa colisao de nomes, ganha a incorporada. Nao
consegue sobrepor `read_file` com um plugin do mesmo nome, por isso escolha um
nome distinto para a sua ferramenta.

### Conceder uma ferramenta a um agente

Um plugin instalado nao entrega automaticamente as suas ferramentas a todos os
agentes. So as ferramentas que lista num agente ficam expostas a ele, e cada
invocacao continua a passar pela mesma barreira de permissao de uma ferramenta
incorporada. Concede uma ferramenta de tres formas.

**Com a CLI do pepe.** Liste a ferramenta no `--tools` do agente:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**No painel.** Abra o agente em Agentes e assinale a ferramenta na respetiva
lista de ferramentas. As ferramentas do plugin surgem ao lado das incorporadas.

#### Fá-lo por chat

Um agente que tem a ferramenta incorporada `enable_tool` pode ativar uma
ferramenta para si proprio depois de instalar um plugin, sem tocar na CLI nem no
painel.

> Tu: ativa a ferramenta reverse_text
>
> Agente: reverse_text ativada; ja a podes usar a partir da tua proxima mensagem

`enable_tool` so aceita uma ferramenta que ja exista como incorporada ou como
plugin carregado, e a alteracao entra em vigor na proxima mensagem do agente.
Para conceder uma ferramenta a um agente *diferente*, um agente com a ferramenta
`manage_agent` pode faze-lo com a acao `add_tool`. Essa ferramenta esta limitada
aos agentes que o agente que atua tem permissao para gerir, e as suas instrucoes
mandam confirmar a alteracao consigo antes de a aplicar.

> Tu: da ao agente de apoio a ferramenta gmail_search
>
> Agente: Vou adicionar gmail_search ao agente "support". Confirmas?
>
> Tu: sim
>
> Agente: gmail_search adicionada ao support.

## Onde vivem os plugins e como carregam

Os plugins vivem em `~/.pepe/plugins/` (a pasta base segue `PEPE_HOME` se o
definir). O Pepe percorre essa pasta de forma recursiva a procura de ficheiros
`.exs`, compila cada um uma vez e guarda em cache. Quando a data de modificacao de
um ficheiro muda, ele e recompilado na chamada seguinte. Coloque um ficheiro e
funciona sem reiniciar. Edite-o e a alteracao entra em vigor na proxima chamada de
ferramenta.

Cada modulo carregado e comparado com o formato que um consumidor espera. Um
modulo que exporta `name/0`, `spec/0` e `run/2` e tratado como uma ferramenta. Um
modulo que exporta `name/0` mais os callbacks de fornecedor de canal e tratado
como um canal. Um ficheiro pode definir varios modulos, por isso um unico plugin
pode trazer um punhado de ferramentas relacionadas (o exemplo da Google traz
quatro).

## Instalar um plugin

A fonte pode ser um ficheiro local, uma diretoria local, um arquivo comprimido ou
um URL para qualquer um deles. O URL de um repositorio do GitHub e obtido como o
seu arquivo de codigo-fonte (quando nenhum ramo e indicado, tenta-se `main` e
depois `master`).

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

**No painel.** A pagina de Plugins tem um campo de instalacao que aceita o URL de
um repositorio do GitHub, um URL `.tar.gz` ou um caminho local. Assinala uma
caixa a confirmar que confia na fonte e depois carrega em Instalar. Os plugins
instalados sao listados com um botao Remover e, quando o plugin declara
definicoes, um botao Configurar (ver abaixo).

Um ficheiro `.exs` avulso e copiado diretamente para a pasta de plugins. Um
**pacote** e copiado como pasta. Um pacote e uma diretoria que contem um
`manifest.json` e um ou mais ficheiros `.exs`.

## A analise de seguranca

Um plugin e Elixir comum com acesso total a aplicacao em execucao. Instalar um e
uma decisao de confianca, tal como acrescentar qualquer dependencia. Para tornar
essa decisao informada, o Pepe analisa o codigo de forma estatica antes de o
colocar em disco. A analise le a arvore de sintaxe a procura de padroes perigosos
(lancar shells, chamadas de rede, ofuscacao, ler segredos). Nunca executa o
codigo e devolve um de tres veredictos: limpo, cautela ou perigo.

Um veredicto de perigo bloqueia a instalacao. Pode prosseguir mesmo assim, depois
de rever o codigo, passando `--force` na CLI (ou o botao "Instalar mesmo assim"
no painel, que so surge apos um veredicto de perigo):

```bash
pepe plugin install ./risky_plugin.exs --force
```

Tambem pode analisar uma fonte sem a instalar:

```bash
pepe plugin scan ./my_plugin.exs
```

<div class="note"><strong>Um plugin corre com acesso total.</strong> E codigo de
nivel de administrador. Instale apenas a partir de uma fonte que conhece e em que
confia, e leia-a primeiro. A analise e uma rede de seguranca, nao um substituto da
revisao.</div>

## O manifesto e o dialogo de Configurar

Um pacote pode transportar um `manifest.json`. Nomeia o pacote, descreve-o, lista
o que fornece e, o mais util, declara as definicoes de que precisa. Aqui esta o
manifesto do exemplo da Google:

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

- `key` e o nome da definicao que o seu codigo le.
- `label` e o rotulo legivel mostrado no formulario.
- `type` e `"text"`, `"secret"` (entrada mascarada) ou `"select"` (acrescente uma
  lista `"options"`).
- `hint` e um texto de ajuda opcional mostrado por baixo do campo.

O painel le este array e apresenta um dialogo de Configurar para o plugin, por
isso um plugin novo nao precisa de um ecra novo. Um valor que introduz pode ser
uma referencia `${ENV_VAR}`. E guardado como a referencia literal e resolvido a
partir do ambiente apenas na leitura, de modo que os segredos nunca ficam
expandidos no ficheiro de configuracao.

### Ler as suas definicoes a partir do codigo

Dentro do plugin, leia uma definicao guardada com `Pepe.Plugins.config/3`. Devolve
o valor guardado com qualquer referencia `${ENV_VAR}` ja resolvida, ou o valor por
omissao quando nao esta definido:

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

O primeiro argumento e o nome do plugin (o nome do pacote no manifesto). Esta e a
ponte entre o formulario do painel e o seu codigo em execucao. Um padrao comum e
preferir o valor do painel e recorrer a uma variavel de ambiente, de modo que o
plugin funcione quer o operador preencha o formulario, quer exporte uma variavel.

## Enviar um ficheiro de volta para a conversa

As ferramentas devolvem texto ao modelo. Quando quer entregar um ficheiro real a
pessoa na conversa (uma folha de calculo, um PDF, uma imagem), a ferramenta
incorporada `send_file` trata disso. O seu agente produz o ficheiro como
entender, por exemplo um comando `bash` que consulta uma base de dados e escreve
um `.xlsx`, e depois invoca `send_file` com o caminho. O Pepe descobre em que
canal esta a conversa a partir da sessao e entrega o ficheiro ali, por isso o
agente nunca precisa de saber ids de conversa nem tokens.

`send_file` recebe um `path` (absoluto, ou relativo a diretoria de trabalho da
execucao) e um `caption` opcional. Funciona em qualquer canal cujo fornecedor
suporte anexos (Telegram, WhatsApp, Slack, Discord e outros). Se o canal nao pode
receber ficheiros, ou a execucao nao e uma conversa em direto, a ferramenta
comunica isso com clareza ao modelo. Por ser incorporada, tem isto de graca:
basta conceder a ferramenta `send_file` ao agente.

Isto tambem e uma capacidade de conversa. Um agente que tem `send_file` vai usa-la
quando lhe pedir um ficheiro na conversa.

> Tu: exporta as encomendas do mes passado como folha de calculo e envia-ma aqui
>
> Agente: (corre uma consulta, escreve orders.xlsx, invoca send_file) Enviei orders.xlsx para a conversa.

## Exemplo: o plugin do Google Workspace

O Pepe inclui um exemplo completo de plugin em `examples/plugins/google`. Um
unico ficheiro `google.exs` define quatro ferramentas:

| Ferramenta | O que faz |
|------|--------------|
| `gcal_upcoming` | Lista os proximos eventos do Google Calendar principal |
| `gcal_create_event` | Cria um evento (resumo, inicio, fim, descricao) |
| `gmail_search` | Pesquisa no Gmail e devolve remetente e assunto das correspondencias |
| `gmail_send` | Envia um e-mail em texto simples |

Instale-o e conceda as ferramentas a um agente:

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

O plugin mostra o padrao por inteiro num so ficheiro: varios modulos de
ferramenta que cada um implementa o comportamento, um pequeno modulo auxiliar
partilhado para a autenticacao e o HTTP, e um manifesto que alimenta o dialogo de
Configurar.

### Como se autentica

As APIs da Google usam tokens bearer OAuth2. O plugin resolve um token no momento
da chamada, por isso nada de sensivel fica embebido no codigo. Le as suas
definicoes primeiro a partir da configuracao do painel e recorre a variaveis de
ambiente, o que significa que funciona quer preencha o formulario de Configurar,
quer exporte variaveis. Ha duas formas de fornecer credenciais.

**A. Um token de acesso pronto** (o mais rapido; expira em cerca de uma hora):

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

Para os obter, crie um cliente OAuth (tipo "Desktop app") num projeto do Google
Cloud, ative as APIs do Calendar e do Gmail, e corra o fluxo de consentimento uma
vez para os scopes que usa (`https://www.googleapis.com/auth/calendar` e
`https://www.googleapis.com/auth/gmail.modify`). Tambem pode introduzir os mesmos
valores no dialogo de Configurar do plugin no painel, guardando os segredos como
referencias `${ENV_VAR}` para os manter fora do ficheiro.

Aqui esta o formato de uma das ferramentas, para ver o padrao da API de ponta a
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

Uma vez concedidas as ferramentas e definidas as credenciais, o agente usa-as em
conversa normal.

> Tu: o que tenho na agenda amanha, e envia um resumo por e-mail para sam@example.com
>
> Agente: (invoca gcal_upcoming, depois gmail_send) Tens 3 eventos amanha. Enviei o resumo por e-mail para sam@example.com.

## Fornecedores de canal, em breve

O mesmo carregador alimenta os canais de mensagens. Um plugin de canal e um
modulo que exporta `name/0` mais os callbacks de fornecedor do webhook de entrada
(`verify`, `authenticate`, `parse`, `deliver` e, opcionalmente, `respond`,
`deliver_file` e um `config_schema` para o seu proprio dialogo de Configurar).
Uma vez instalado, o fornecedor fica acessivel na rota do webhook de entrada
generico sem acrescentar um novo URL, e aparece entre os fornecedores de canal em
`pepe plugin list`. O exemplo incluido do Chatwoot em `examples/plugins/chatwoot`
corre o Pepe por tras de uma caixa de entrada do Chatwoot com passagem nativa
para um humano. A pagina de canais de mensagens cobre o contrato do fornecedor
por completo.

## Lista de verificacao para escrever a sua propria ferramenta

1. Escreva um modulo que implemente `name/0`, `spec/0` e `run/2`.
2. De-lhe um nome unico (as incorporadas ganham uma colisao, por isso evite os
   nomes delas).
3. Devolva `{:ok, text}` ou `{:error, message}` a partir de `run/2`, escrito para
   o modelo ler.
4. Se precisar de credenciais ou opcoes, inclua um `manifest.json` com um array
   `config` e leia-as com `Pepe.Plugins.config/3`.
5. Instale com `pepe plugin install`, reveja a analise e conceda a ferramenta a um
   agente (CLI, painel ou por conversa com `enable_tool`).
