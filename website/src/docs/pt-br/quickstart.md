---
title: Início rápido
description: Instale o Pepe, conecte um modelo, defina um agente e converse com ele, e depois exponha esse mesmo agente por HTTP, um WebSocket e um canal de chat, em poucos minutos.
---

O Pepe é um runtime de agentes de IA auto-hospedado. Você define um agente (um
nome, um prompt de sistema, um conjunto de ferramentas e uma conexão com um modelo)
e o Pepe roda o laço de chamadas de ferramentas para você. Ele chama o modelo,
executa as ferramentas que o modelo pediu, devolve os resultados e repete até o
modelo produzir uma resposta final.

O Pepe conversa com qualquer provedor compatível com a OpenAI pelo protocolo de
Chat Completions, então OpenAI, OpenRouter, Together, Groq, DeepSeek, Mistral, um
Ollama local e qualquer outra coisa que fale a mesma API funcionam sem mudar uma
linha de código. O Pepe é construído em Elixir, mas você não precisa saber Elixir
para usá-lo. Esta página leva você do zero a um agente que conversa, e depois põe
esse mesmo agente atrás de uma API HTTP, um WebSocket e um canal de chat.

Há três formas de comandar o Pepe, e quase tudo o que segue pode ser feito por
qualquer uma delas:

1. A ferramenta de linha de comando `pepe`.
2. O painel web que acompanha o servidor.
3. Por chat, falando em linguagem natural com um agente que tem a ferramenta de
   gestão correspondente.

Onde um passo pode ser feito por chat, você vai encontrar uma pequena subseção
"Faça por chat" mostrando a mensagem que você enviaria e o que o agente faz.

## 1. Instalação

Um único comando instala o binário `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confira que ele foi instalado:

```bash
pepe help
```

Tudo o que o Pepe sabe vive em um único arquivo JSON em `~/.pepe/config.json`. Não
há banco de dados para rodar. Você pode editar esse arquivo na mão depois, mas os
comandos abaixo o escrevem para você.

## 2. Configuração guiada (o caminho rápido)

O `pepe setup` conduz você pelo processo inteiro. Ele escolhe um provedor, faz
login ou pega uma chave de API, escolhe um modelo, cria seu primeiro agente e
oferece conectar um canal de chat e o painel.

```bash
pepe setup
```

Se você preferir fazer cada passo de forma explícita, pule o setup e siga os passos
3 a 6. Os dois caminhos escrevem a mesma configuração, então você pode misturar os
dois à vontade.

<div class="note"><strong>Os segredos ficam fora do arquivo.</strong> Quando o Pepe pede uma chave de API, ele aceita uma referência <code>${ENV_VAR}</code>, por exemplo <code>${OPENROUTER_API_KEY}</code>. O que é escrito em <code>~/.pepe/config.json</code> é a referência. O valor real é lido do seu ambiente em tempo de execução e nunca é guardado expandido.</div>

## 3. Conectar um modelo

Aponte o Pepe para qualquer endpoint compatível com a OpenAI. Guarde a chave como
uma referência de ambiente para que o segredo cru nunca caia no arquivo de
configuração.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5 \
  --default
```

Você verá uma confirmação assim:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5)
```

Algumas coisas que vale saber:

- Rode `pepe model add NAME` sem `--base-url` para ter um seletor guiado. Escolha um
  provedor do catálogo, escolha como se autenticar e depois escolha um modelo da
  lista ao vivo do provedor.
- `pepe model providers` lista os provedores que o Pepe conhece de fábrica.
- `pepe model list` mostra cada conexão salva e marca a padrão.
- `pepe model test` envia uma requisição real mínima para confirmar que a conexão
  funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5)...
✓ openrouter works - reply: pong
```

O painel também faz tudo isso, na aba Modelos, se você preferir um formulário à
linha de comando.

## 4. Adicionar um agente

Um agente é um nome, um prompt de sistema e uma lista de ferramentas permitidas que
ele pode usar. Se você deixar `--tools` de fora, o agente recebe todas as
ferramentas embutidas. Passe uma lista separada por vírgulas para restringir.
Adicione `--model` para vincular uma conexão de modelo específica, ou omita para
usar a padrão.

```bash
pepe agent add assistant \
  --prompt "You are a helpful, concise assistant." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

```bash
✓ agent assistant saved (tools: bash, read_file, write_file, edit_file, list_dir, fetch_url, web_search)
```

As ferramentas embutidas cobrem o essencial: comandos de shell (`bash`,
`run_script`), arquivos (`read_file`, `write_file`, `edit_file`, `move_file`,
`list_dir`) e a web (`fetch_url`, `web_search`), mais um conjunto de ferramentas de
gestão vistas mais adiante nesta página. Veja a lista completa a qualquer momento
com:

```bash
pepe tools
```

<div class="note"><strong>As ferramentas são como você concede capacidade.</strong> Um agente só pode fazer o que suas ferramentas permitem. Dê a um agente de suporte <code>fetch_url</code> e <code>web_search</code> mas não <code>bash</code>, e ele simplesmente não consegue rodar comandos de shell. Comece restrito e adicione ferramentas conforme você confia no agente.</div>

O painel tem uma aba Agentes que faz a mesma coisa com um formulário.

### Faça por chat

Um agente que tem a ferramenta `manage_agent` pode criar e moldar outros agentes na
conversa. Duas coisas controlam isso: a ferramenta precisa estar na lista permitida
do agente que age, e esse agente precisa ter autoridade sobre o alvo (concedida com
`pepe agent manage ADMIN TARGET`, ou `"*"` para todos). Como é uma ferramenta
arriscada, cada mudança passa também pela barreira de permissão, onde você a aprova
antes de ela ser aplicada.

Você enviaria:

> Create an agent called researcher that digs up sources and summarizes them.
> Give it web_search and fetch_url, nothing else.

O agente confirma os detalhes com você e depois (com a sua aprovação no aviso de
permissão) cria o agente `researcher`, define sua persona e concede as duas
ferramentas. A mesma ferramenta também pode apontar um agente para um modelo
diferente, adicionar ou remover uma única ferramenta e acrescentar fatos duráveis à
memória de um agente.

## 5. Converse com ele

Rode um único prompt. A resposta é transmitida ao seu terminal conforme o modelo a
produz, e quaisquer chamadas de ferramenta rodam pelo caminho.

```bash
pepe run assistant "what files are in this directory?"
```

Tire o nome do agente para usar seu agente padrão:

```bash
pepe run "summarize the README in three bullets"
```

Para uma conversa de ida e volta que lembra o contexto, abra o console interativo.
Ele mantém a sessão, então as perguntas seguintes se apoiam no que veio antes.

```bash
pepe chat assistant
```

Quando uma ferramenta quer fazer algo sensível (rodar um comando de shell, escrever
um arquivo), o console pede que você a aprove antes de ela rodar, e diz o que torna
a chamada arriscada (por exemplo "writes to a file" ou "accesses the network").

### Faça por chat

Assim que um agente tem a ferramenta `enable_tool`, ele pode adicionar uma
ferramenta à sua própria lista permitida na conversa, o que é útil logo depois de
você instalar um plugin. A ferramenta já precisa existir como embutida ou como
plugin. Como isso muda a configuração, a chamada é protegida, então você a aprova
no aviso de permissão. A nova ferramenta fica disponível a partir da próxima
mensagem do agente.

> You just installed the weather plugin. Turn on the get_weather tool for
> yourself.

## 6. Sirva em todo lugar

Um único comando põe o mesmo agente atrás de uma API HTTP compatível com a OpenAI,
um WebSocket com streaming e um painel web local.

```bash
pepe serve --port 4000
```

```bash
✓ Pepe serving on http://localhost:4000  (override with PORT=NNNN)

  OpenAI API : POST http://localhost:4000/v1/chat/completions
  Models     : GET  http://localhost:4000/v1/models
  Health     : GET  http://localhost:4000/health
  WebSocket  : ws://localhost:4000/socket/websocket  (topic agent:default)

   dashboard: open on localhost only; remote clients are blocked until you set a password
```

### Chame como se fosse a OpenAI

O nome do agente vai no campo `model`. Qualquer SDK da OpenAI ou um `curl` simples
funciona.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hi"}]}'
```

Como tem o formato padrão de Chat Completions, as bibliotecas cliente da OpenAI que
já existem apontam direto para ele. Aqui está a mesma chamada em algumas linguagens.

**Python**

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="unused")

resp = client.chat.completions.create(
    model="assistant",
    messages=[{"role": "user", "content": "hi"}],
)
print(resp.choices[0].message.content)
```

**Node**

```javascript
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://localhost:4000/v1", apiKey: "unused" });

const resp = await client.chat.completions.create({
  model: "assistant",
  messages: [{ role: "user", content: "hi" }],
});
console.log(resp.choices[0].message.content);
```

`GET /v1/models` lista seus agentes, então um cliente que busca os modelos
disponíveis vê cada agente como um.

<div class="note"><strong>A API fica aberta até você trancá-la.</strong> Sem tokens configurados, qualquer um que alcance a porta pode chamá-la. Crie o primeiro token com <code>pepe token add</code> e a partir daí toda chamada precisa de um cabeçalho <code>Authorization: Bearer</code>. Veja a página da API HTTP para os detalhes.</div>

### O painel

Servir também abre um painel web local onde você pode gerenciar agentes, modelos,
canais, tarefas agendadas, plugins, traços e consumo sem editar o arquivo de
configuração na mão. No localhost ele fica aberto por padrão. Se você vincular o
Pepe a um endereço público, o acesso remoto continua bloqueado até você definir uma
senha do painel com `pepe dashboard password '<pass>'`.

## 7. Coloque em um canal de chat

O mesmo agente pode responder pessoas em uma plataforma de mensagens. O Telegram é o
mais rápido de experimentar. Crie um bot com o BotFather do Telegram e depois
entregue o token ao Pepe.

```bash
pepe gateway telegram setup
pepe gateway telegram
```

O primeiro comando guarda o token e vincula o bot a um agente. O segundo inicia o
polling. Daí em diante, qualquer um que mande mensagem para o bot está falando com
seu agente, com as mesmas ferramentas e memória que ele tem em todo lugar.

Além do Telegram, o Pepe se conecta a WhatsApp, Slack, Discord, Microsoft Teams e
Google Chat pelo webhook oficial de cada plataforma, mais um webhook de entrada
genérico para qualquer outra coisa. Você pode configurá-los de forma interativa
rodando `pepe setup` e escolhendo Canais, ou pelo painel.

### Faça por chat

Um agente que tem a ferramenta `manage_channel` pode criar e revincular bots do
Telegram a partir de uma conversa. Ele nunca aceita um token cru. Você dá a ele o
nome de uma variável de ambiente que contém o token, que o Pepe guarda como
`${THE_VAR}` para que o segredo nunca chegue ao modelo nem aos logs. A ferramenta é
arriscada, então a mudança passa pela barreira de permissão antes de ter efeito, e
o polling em execução se reconcilia ao vivo sem reiniciar.

> Set up a Telegram bot for the sales agent. The token is in the SALES_BOT_TOKEN
> environment variable.

O agente confirma os detalhes e depois (com a sua aprovação) cria o bot vinculado ao
agente `sales`, guardando seu token como `${SALES_BOT_TOKEN}`.

## 8. Automatize: tarefas agendadas e vigias

O Pepe pode rodar um agente em um horário, ou vigiar uma condição e notificar você
uma única vez.

Uma tarefa agendada roda um prompt autocontido em um horário cron recorrente.

```bash
pepe cron add
pepe cron list
```

Uma vigia sonda uma verificação barata e avisa você uma única vez quando ela passa,
e depois para. Ela sobrevive a reinícios.

```bash
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
pepe watch list
```

As duas também têm lugar no painel.

### Faça por chat

Um agente com a ferramenta `schedule_task` pode criar trabalhos recorrentes na
conversa, e um com a ferramenta `watch` pode configurar notificações de uma única
vez. As duas são controladas: o agente rascunha os detalhes, confirma com você (o
que, quando, em qual fuso horário, onde reportar) e aplica a mudança só depois de
você a aprovar no aviso de permissão.

Agendar:

> Every weekday at 8am, check our status page and send me a one line summary.

O agente escreve uma tarefa autocontida com um horário cron (`0 8 * * 1-5`) e um
fuso horário, confirma e salva quando você aprova. Por padrão, ele responde no
mesmo chat.

Vigiar:

> Tell me as soon as example.com comes back up.

O agente cria uma vigia de uma única vez que sonda o site em um temporizador e manda
mensagem para você uma vez quando ele tem sucesso, e depois para.

## Onde sua configuração vive

Tudo o que você fez acima está agora em `~/.pepe/config.json`: a conexão do modelo,
o agente e quaisquer canais. Sem banco de dados, sem migrações. Para mover uma
configuração para outra máquina, copie esse arquivo e defina as mesmas variáveis de
ambiente para as quais suas referências `${VAR}` apontam.

```bash
pepe config
```

Isso imprime o caminho da configuração e um resumo do que está definido.

## Próximos passos

- [Agentes e ferramentas](./agents/). Do que um agente é feito e como ele decide
  quais ferramentas chamar.
- [API HTTP](./api/). Streaming, chamadas de ferramentas pela rede e como trancar a
  API com tokens.
- [Canais](./channels/). Telegram, WhatsApp, Slack, Discord, Teams e Google Chat em
  profundidade.
- [Tarefas agendadas](./scheduled/). Rode um agente em um horário recorrente, e
  vigias de uma única vez.
- [Segurança e permissões](./security/). A barreira de aprovação, o isolamento das
  ferramentas de shell e a senha do painel.
- [Plugins](./plugins/). Adicione suas próprias ferramentas e canais sem
  reconstruir.

<div class="note"><strong>Roda mais de um inquilino?</strong> O Pepe pode restringir agentes, modelos e canais a uma empresa para que os inquilinos fiquem isolados. Tudo o que você configurou acima vive no escopo padrão, chamado Principal. Adicione <code>--company NAME</code> a um comando para trabalhar dentro de um específico.</div>
