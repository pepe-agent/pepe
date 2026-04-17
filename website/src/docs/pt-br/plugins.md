---
title: Plugins
description: Estenda o Pepe com ferramentas e canais próprios instalando plugins com sua própria configuração.
---

Um plugin adiciona uma **ferramenta** que o modelo pode chamar, ou um
**provedor de canal** (uma nova plataforma de mensagens), ou os dois. Ambos são
Elixir compilado em tempo de execução a partir de `~/.pepe/plugins/`, sem rebuild.
Esses são os únicos dois formatos que um plugin pode ter hoje; um módulo é
comparado com o formato que ele implementa.

## O comportamento Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Finalidade |
|---|---|
| `name/0` | O nome de função que o modelo chama, por exemplo `"read_file"`. Precisa ser único entre todas as ferramentas; um plugin nunca ganha uma colisão de nome contra uma ferramenta embutida. |
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

## O comportamento Channel provider

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
| `parse/1` | sim | Normaliza um payload decodificado em zero ou mais mensagens `%{from, text, id}`, ou `:ignore` para o que não tem nada a fazer (recibos, atualizações de status). |
| `deliver/3` | sim | Envia uma resposta em texto para `to` (um endereço do provedor: número de telefone, id de canal, ...). |
| `label/0` | não | Rótulo humano para o painel (usa `name/0` por padrão). |
| `config_schema/0` | não | Campos que o painel renderiza para configurar uma conexão, mesmo formato do array `config` de um manifesto de plugin (abaixo). |
| `respond/3` | não | Uma resposta HTTP **síncrona** ao `POST` bruto, para protocolos que precisam de uma antes de qualquer trabalho do agente (o desafio de verificação de URL do Slack, o `PING` do Discord). `{:reply, status, content_type, body}` ou `:cont` para cair em `parse/1`. |
| `deliver_file/4` | não | Envia um arquivo como anexo. Omita e o `send_file` simplesmente reporta que o canal não recebe arquivos. |
| `addressed?/2` | não | Esse payload se dirige ao bot, então deve receber resposta? Permite que um provedor honre `require_mention` em grupos (padrão quando omitido: sempre endereçado). |

## O registro

`Pepe.Tools.all/0` devolve as ferramentas embutidas seguidas de cada
ferramenta de plugin carregada; `Pepe.Webhooks` faz o mesmo para provedores de
canal. Uma regra para lembrar: uma embutida sempre ganha uma colisão de nome,
então escolha um nome de ferramenta diferente de `read_file`, `web_search` e
do resto de `pepe tools`.

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

## Instalar um plugin

A fonte é um arquivo local, um diretório local, um `.tar.gz`, ou uma URL para
qualquer um desses. Uma URL de repositório do GitHub é baixada como seu
arquivo de código-fonte (`main`, depois `master`, quando nenhuma branch é
indicada).

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
segurança da CLI, mas sem a saída de emergência `--force`: um veredito
perigoso é sempre recusado pela conversa, e o agente vai te dizer para
revisar o código e rodar `--force` você mesmo em um terminal se ainda assim
quiser.

## A varredura de segurança

Um plugin é Elixir comum com acesso total ao aplicativo em execução:
instalar um é uma decisão de confiança, igual a adicionar qualquer
dependência. Antes de ser colocado em disco, o `Pepe.Skills.Sentinel` varre o
código de forma estática, lendo a árvore de sintaxe atrás de padrões
perigosos (lançar shells, eval dinâmico, chamadas destrutivas no sistema de
arquivos, leitura de segredos, acesso à rede). Ele nunca executa o código, e
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

**Transferência nativa para humano, sem cola extra.** O Chatwoot carrega o
sinal de transferência em todo webhook: o `status` da conversa. O plugin
implementa `parse/1` para responder só conversas marcadas como `pending`
(controladas pelo bot); no momento em que um atendente humano assume
(`open`), o Pepe fica quieto, e volta quando a conversa retorna a `pending`.

**Configuração, no Chatwoot:** crie um AgentBot, aponte o webhook de saída
dele para `https://SEU_HOST/webhooks/<company>/chatwoot/<slug>`. A conexão
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
