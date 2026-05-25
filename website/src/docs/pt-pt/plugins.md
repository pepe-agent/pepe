---
title: Plugins
description: Amplia o Pepe com ferramentas e canais próprios instalando plugins com a sua própria configuração.
---

Um plugin acrescenta uma **ferramenta** que o modelo pode invocar, ou um
**fornecedor de canal** (uma nova plataforma de mensagens), ou ambos: Elixir
compilado em tempo de execução a partir de `~/.pepe/plugins/`, sem rebuild.
São os únicos dois formatos que um plugin pode ter hoje; um módulo é
comparado com o formato que implementa.

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
