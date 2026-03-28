---
title: Início rápido
description: Instala o Pepe, liga um modelo, define um agente e conversa com ele, e depois expõe esse mesmo agente por HTTP, um WebSocket e um canal de conversa, em poucos minutos.
---

O Pepe é um runtime de agentes de IA alojado por ti próprio. Defines um agente (um
nome, um prompt de sistema, um conjunto de ferramentas e uma ligação a um modelo) e
o Pepe corre o ciclo de chamadas de ferramentas por ti. Chama o modelo, executa as
ferramentas que o modelo pediu, devolve os resultados e repete até o modelo
produzir uma resposta final.

O Pepe comunica com qualquer fornecedor compatível com a OpenAI através do
protocolo de Chat Completions, por isso a OpenAI, o OpenRouter, o Together, o Groq,
o DeepSeek, o Mistral, um Ollama local e tudo o resto que fale a mesma API funcionam
sem alterar uma linha de código. O Pepe está construído em Elixir, mas não precisas
de saber Elixir para o usar. Esta página leva-te do zero a um agente que conversa, e
depois coloca esse mesmo agente por trás de uma API HTTP, de um WebSocket e de um
canal de conversa.

Há três formas de comandar o Pepe, e quase tudo o que se segue pode ser feito por
qualquer uma delas:

1. A ferramenta de linha de comandos `pepe`.
2. O painel web que acompanha o servidor.
3. Por conversa, falando em linguagem natural com um agente que detém a ferramenta
   de gestão correspondente.

Sempre que um passo puder ser feito por conversa, vais encontrar uma pequena
subsecção "Fá-lo por conversa" que mostra a mensagem que enviarias e o que o agente
faz.

## 1. Instalação

Um único comando instala o binário `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confirma que ficou instalado:

```bash
pepe help
```

Tudo o que o Pepe sabe vive num único ficheiro JSON em `~/.pepe/config.json`. Não há
nenhuma base de dados para executar. Podes editar esse ficheiro à mão mais tarde,
mas os comandos abaixo escrevem-no por ti.

## 2. Configuração guiada (o caminho rápido)

O `pepe setup` acompanha-te ao longo de todo o processo. Escolhe um fornecedor,
inicia sessão ou recebe uma chave de API, escolhe um modelo, cria o teu primeiro
agente e oferece-se para ligar um canal de conversa e o painel.

```bash
pepe setup
```

Se preferires fazer cada passo de forma explícita, salta o setup e segue os passos 3
a 6. Os dois caminhos escrevem a mesma configuração, por isso podes misturá-los à
vontade.

<div class="note"><strong>Os segredos ficam fora do ficheiro.</strong> Quando o Pepe pede uma chave de API, aceita uma referência <code>${ENV_VAR}</code>, por exemplo <code>${OPENROUTER_API_KEY}</code>. O que fica escrito em <code>~/.pepe/config.json</code> é a referência. O valor real é lido do teu ambiente em tempo de execução e nunca fica guardado expandido.</div>

## 3. Ligar um modelo

Aponta o Pepe para qualquer endpoint compatível com a OpenAI. Guarda a chave como
uma referência de ambiente para que o segredo em bruto nunca vá parar ao ficheiro de
configuração.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5 \
  --default
```

Vais ver uma confirmação como esta:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5)
```

Algumas coisas que vale a pena saber:

- Executa `pepe model add NAME` sem `--base-url` para obteres um seletor guiado.
  Escolhe um fornecedor do catálogo, escolhe como te autenticar e depois escolhe um
  modelo da lista em direto do fornecedor.
- `pepe model providers` lista os fornecedores que o Pepe conhece de origem.
- `pepe model list` mostra cada ligação guardada e assinala a predefinida.
- `pepe model test` envia um pedido real mínimo para confirmar que a ligação
  funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5)...
✓ openrouter works - reply: pong
```

O painel também consegue fazer tudo isto, no seu separador Modelos, se preferires um
formulário à linha de comandos.

## 4. Adicionar um agente

Um agente é um nome, um prompt de sistema e uma lista de ferramentas permitidas que
pode usar. Se deixares o `--tools` de fora, o agente recebe todas as ferramentas
incorporadas. Passa uma lista separada por vírgulas para a restringir. Adiciona
`--model` para associar uma ligação de modelo específica, ou omite para usar a
predefinida.

```bash
pepe agent add assistant \
  --prompt "You are a helpful, concise assistant." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

```bash
✓ agent assistant saved (tools: bash, read_file, write_file, edit_file, list_dir, fetch_url, web_search)
```

As ferramentas incorporadas cobrem o essencial: comandos de shell (`bash`,
`run_script`), ficheiros (`read_file`, `write_file`, `edit_file`, `move_file`,
`list_dir`) e a web (`fetch_url`, `web_search`), mais um conjunto de ferramentas de
gestão abordadas mais à frente nesta página. Vê a lista completa a qualquer momento
com:

```bash
pepe tools
```

<div class="note"><strong>As ferramentas são a forma de conceder capacidade.</strong> Um agente só consegue fazer o que as suas ferramentas permitem. Dá a um agente de apoio <code>fetch_url</code> e <code>web_search</code> mas não <code>bash</code>, e ele simplesmente não consegue executar comandos de shell. Começa restrito e vai adicionando ferramentas à medida que confias no agente.</div>

O painel tem um separador Agentes que faz o mesmo com um formulário.

### Fá-lo por conversa

Um agente que detém a ferramenta `manage_agent` pode criar e moldar outros agentes
numa conversa. Duas coisas o condicionam: a ferramenta tem de estar na lista
permitida do agente que age, e esse agente tem de ter autoridade sobre o alvo
(concedida com `pepe agent manage ADMIN TARGET`, ou `"*"` para todos). Por ser uma
ferramenta arriscada, cada alteração passa também pela barreira de permissões, onde
a aprovas antes de ser aplicada.

Enviarias:

> Create an agent called researcher that digs up sources and summarizes them.
> Give it web_search and fetch_url, nothing else.

O agente confirma os detalhes contigo e depois (com a tua aprovação no pedido de
permissão) cria o agente `researcher`, define a sua persona e concede as duas
ferramentas. A mesma ferramenta também pode apontar um agente para um modelo
diferente, adicionar ou remover uma única ferramenta e acrescentar factos duráveis à
memória de um agente.

## 5. Fala com ele

Executa um único prompt. A resposta é transmitida para o teu terminal à medida que o
modelo a produz, e quaisquer chamadas de ferramenta executam pelo caminho.

```bash
pepe run assistant "what files are in this directory?"
```

Retira o nome do agente para usares o teu agente predefinido:

```bash
pepe run "summarize the README in three bullets"
```

Para uma conversa de ida e volta que se lembra do contexto, abre a consola
interativa. Mantém a sessão, por isso as perguntas seguintes assentam no que veio
antes.

```bash
pepe chat assistant
```

Quando uma ferramenta quer fazer algo sensível (executar um comando de shell,
escrever um ficheiro), a consola pede-te que a aproves antes de ela correr, e diz o
que torna a chamada arriscada (por exemplo "writes to a file" ou "accesses the
network").

### Fá-lo por conversa

Assim que um agente detém a ferramenta `enable_tool`, pode adicionar uma ferramenta à
sua própria lista permitida numa conversa, o que é cómodo logo depois de instalares
um plugin. A ferramenta já tem de existir como incorporada ou como plugin. Como isto
altera a configuração, a chamada é protegida, por isso aprova-la no pedido de
permissão. A nova ferramenta fica disponível a partir da mensagem seguinte do
agente.

> You just installed the weather plugin. Turn on the get_weather tool for
> yourself.

## 6. Serve-o em todo o lado

Um único comando coloca o mesmo agente por trás de uma API HTTP compatível com a
OpenAI, de um WebSocket com streaming e de um painel web local.

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

### Chama-o como a OpenAI

O nome do agente vai no campo `model`. Funciona qualquer SDK da OpenAI ou um `curl`
simples.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hi"}]}'
```

Como tem o formato padrão de Chat Completions, as bibliotecas cliente da OpenAI que
já existem apontam diretamente para ele. Aqui está a mesma chamada a partir de
algumas linguagens.

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

`GET /v1/models` lista os teus agentes, por isso um cliente que procura os modelos
disponíveis vê cada agente como um.

<div class="note"><strong>A API fica aberta até a trancares.</strong> Sem tokens configurados, qualquer pessoa que alcance a porta pode chamá-la. Cria o primeiro token com <code>pepe token add</code> e a partir daí cada chamada precisa de um cabeçalho <code>Authorization: Bearer</code>. Consulta a página da API HTTP para os detalhes.</div>

### O painel

Servir também abre um painel web local onde podes gerir agentes, modelos, canais,
tarefas agendadas, plugins, rastreios e consumo sem editar o ficheiro de
configuração à mão. No localhost fica aberto por predefinição. Se associares o Pepe a
um endereço público, o acesso remoto permanece bloqueado até definires uma palavra
passe do painel com `pepe dashboard password '<pass>'`.

## 7. Coloca-o num canal de conversa

O mesmo agente pode responder a pessoas numa plataforma de mensagens. O Telegram é o
mais rápido de experimentar. Cria um bot com o BotFather do Telegram e depois
entrega o token ao Pepe.

```bash
pepe gateway telegram setup
pepe gateway telegram
```

O primeiro comando guarda o token e associa o bot a um agente. O segundo arranca a
sondagem. A partir daí, qualquer pessoa que envie mensagem ao bot está a falar com o
teu agente, com as mesmas ferramentas e memória que ele tem em todo o lado.

Para além do Telegram, o Pepe liga-se ao WhatsApp, Slack, Discord, Microsoft Teams e
Google Chat através do webhook oficial de cada plataforma, mais um webhook de entrada
genérico para qualquer outra coisa. Podes configurá-los de forma interativa
executando `pepe setup` e escolhendo Canais, ou a partir do painel.

### Fá-lo por conversa

Um agente que detém a ferramenta `manage_channel` pode criar e reassociar bots do
Telegram a partir de uma conversa. Nunca aceita um token em bruto. Dás-lhe o nome de
uma variável de ambiente que contém o token, que o Pepe guarda como `${THE_VAR}`
para que o segredo nunca chegue ao modelo nem aos registos. A ferramenta é
arriscada, por isso a alteração passa pela barreira de permissões antes de ter
efeito, e a sondagem em execução reconcilia-se em direto sem reiniciar.

> Set up a Telegram bot for the sales agent. The token is in the SALES_BOT_TOKEN
> environment variable.

O agente confirma os detalhes e depois (com a tua aprovação) cria o bot associado ao
agente `sales`, guardando o seu token como `${SALES_BOT_TOKEN}`.

## 8. Automatiza: tarefas agendadas e vigilâncias

O Pepe pode executar um agente segundo um horário, ou vigiar uma condição e
notificar-te uma única vez.

Uma tarefa agendada executa um prompt autónomo segundo um horário cron recorrente.

```bash
pepe cron add
pepe cron list
```

Uma vigilância sonda uma verificação barata e avisa-te uma única vez quando esta se
cumpre, e depois para. Sobrevive a reinícios.

```bash
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
pepe watch list
```

Ambas também têm um lugar no painel.

### Fá-lo por conversa

Um agente com a ferramenta `schedule_task` pode criar trabalhos recorrentes numa
conversa, e um com a ferramenta `watch` pode configurar notificações de uma única
vez. Ambas são condicionadas: o agente rascunha os detalhes, confirma-os contigo (o
que, quando, em que fuso horário, onde reportar) e aplica a alteração apenas depois
de a aprovares no pedido de permissão.

Agendar:

> Every weekday at 8am, check our status page and send me a one line summary.

O agente escreve uma tarefa autónoma com um horário cron (`0 8 * * 1-5`) e um fuso
horário, confirma-a e guarda-a assim que a aprovas. Por predefinição, reporta à
mesma conversa.

Vigiar:

> Tell me as soon as example.com comes back up.

O agente cria uma vigilância de uma única vez que sonda o site num temporizador e te
envia mensagem uma vez quando tem êxito, e depois para.

## Onde vive a tua configuração

Tudo o que fizeste acima está agora em `~/.pepe/config.json`: a ligação ao modelo, o
agente e quaisquer canais. Sem base de dados, sem migrações. Para mover uma
configuração para outra máquina, copia esse ficheiro e define as mesmas variáveis de
ambiente para onde apontam as tuas referências `${VAR}`.

```bash
pepe config
```

Isso imprime o caminho da configuração e um resumo do que está definido.

## Próximos passos

- [Agentes e ferramentas](./agents/). De que é feito um agente e como decide quais
  ferramentas chamar.
- [API HTTP](./api/). Streaming, chamadas de ferramentas pela rede e como trancar a
  API com tokens.
- [Canais](./channels/). Telegram, WhatsApp, Slack, Discord, Teams e Google Chat em
  profundidade.
- [Tarefas agendadas](./scheduled/). Executa um agente segundo um horário
  recorrente, e vigilâncias de uma única vez.
- [Segurança e permissões](./security/). A barreira de aprovação, o isolamento das
  ferramentas de shell e a palavra passe do painel.
- [Plugins](./plugins/). Adiciona as tuas próprias ferramentas e canais sem
  reconstruir.

<div class="note"><strong>Estás a gerir mais do que um inquilino?</strong> O Pepe pode restringir agentes, modelos e canais a uma empresa para que os inquilinos se mantenham isolados. Tudo o que configuraste acima vive no âmbito predefinido, chamado Principal. Adiciona <code>--company NAME</code> a um comando para trabalhar dentro de um específico.</div>
