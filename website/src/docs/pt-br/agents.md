---
title: Agentes
description: Defina um agente a partir de um prompt, um modelo e um conjunto de ferramentas, e deixe o runtime chamar o modelo, executar ferramentas e repetir o ciclo até chegar a uma resposta.
---

## O que é um agente

Um agente é uma definição pequena e declarativa. Ele tem um nome, um system prompt
que lhe dá uma personalidade, uma conexão de modelo com a qual raciocinar e uma
lista de ferramentas que ele tem permissão para chamar. Um punhado de ajustes extras
(um limite de iterações, uma temperatura, com quem ele pode falar, quem ele pode
administrar) completam o conjunto. É isso. O agente não guarda lógica própria. O
runtime do Pepe faz o trabalho: chama o modelo, executa as ferramentas que o modelo
pedir, devolve os resultados e repete até haver uma resposta final.

Cada agente vive como uma entrada dentro de um único arquivo JSON em
`~/.pepe/config.json`. Não há banco de dados. Você pode criar e editar agentes de
três formas, e todas escrevem no mesmo arquivo:

1. A ferramenta de linha de comando `pepe`.
2. O painel web.
3. Uma conversa comum, falando com um agente que tenha a ferramenta de gestão
   correspondente.

Veja um agente completo como ele fica em disco:

```json
{
  "agents": {
    "assistant": {
      "description": "General-purpose helper",
      "model": "openrouter",
      "system_prompt": "You are a concise, helpful assistant.",
      "tools": ["bash", "read_file", "write_file", "web_search"],
      "auto_approve": [],
      "can_message": [],
      "can_manage": null,
      "hooks": [],
      "max_iterations": 12,
      "temperature": null
    }
  }
}
```

## Seu primeiro agente

Um agente precisa de uma conexão de modelo antes de conseguir raciocinar. Se você
ainda não criou nenhuma, a configuração guiada te acompanha para escolher um
provedor, fazer login e escolher um modelo:

```bash
pepe setup
```

Depois defina um agente com um prompt e algumas ferramentas:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "You are a concise, helpful assistant." \
  --tools bash,read_file,write_file,web_search
```

Rode um prompt de uma vez só contra ele. A resposta é transmitida para o seu
terminal à medida que é produzida:

```bash
pepe run assistant "What files are in the current directory?"
```

Esse único comando dispara o ciclo completo. O agente decide que precisa olhar o
sistema de arquivos, chama a ferramenta `list_dir` ou `bash`, lê o resultado e
responde em linguagem natural.

<div class="note"><strong>Pelo painel.</strong> A seção de Agentes do painel web faz
a mesma coisa com um formulário: nome, personalidade, modelo, uma lista de seleção
de ferramentas e o escopo de administração. Ela escreve a mesma entrada em
<code>~/.pepe/config.json</code>, então você pode combinar livremente a CLI, o
painel e a edição manual.</div>

### Faça por chat

Qualquer agente que tenha a ferramenta `manage_agent` pode criar e configurar outros
agentes por conversa. É assim que o primeiro agente de todos (veja "O agente dono"
mais abaixo) deixa você montar o resto da sua frota sem tocar na CLI. Uma mensagem
como:

```text
Create a new agent called researcher. Give it a persona focused on careful
web research, point it at the openrouter model, and turn on web_search and
fetch_url.
```

O agente chama `manage_agent` com `action: "create"`, e depois `set_persona`,
`set_model` e `add_tool` para cada capacidade. `manage_agent` é uma ferramenta de
risco: ela passa pela barreira de permissão, então numa superfície que consegue
perguntar (o console, um canal de chat) o runtime te pede para autorizar a mudança
antes de escrevê-la, e a própria ferramenta é instruída a confirmar o plano com você
primeiro. Um agente só pode gerir os agentes dentro do seu escopo `can_manage`
(tratado em "Administrar agentes" mais abaixo); pedir para ele mexer em um que esteja
fora desse escopo é recusado com educação.

## Os campos, um por um

| Campo | O que faz | Padrão |
|-------|--------------|---------|
| `name` | A identidade do agente, e a chave sob a qual ele é armazenado e endereçado. Dentro de uma empresa vira um identificador como `acme/assistant` (veja abaixo). | obrigatório |
| `description` | Uma nota curta para humanos. Nunca enviada ao modelo. | nenhum |
| `model` | O nome de uma conexão de modelo. Deixe sem definir para usar o modelo padrão do escopo. | padrão do escopo |
| `system_prompt` | A personalidade e as instruções com que o agente roda. | `You are Pepe, a helpful AI agent.` (um prompt inicial) |
| `tools` | A lista de nomes de ferramentas que este agente pode chamar. Só essas são oferecidas ao modelo. | todas as ferramentas quando `--tools` é omitido na criação |
| `auto_approve` | Ferramentas que este agente pode executar sem pedir permissão. `["*"]` significa todas. | `[]` |
| `can_message` | Outros agentes para os quais este pode enviar mensagens (uma rota direcionada). | `[]` |
| `can_manage` | Quais agentes este pode administrar. Veja "Administrar agentes". | `null` (só ele mesmo) |
| `hooks` | Transformações do fluxo de mensagens a aplicar, como a redação de dados pessoais. | `[]` |
| `max_iterations` | O teto rígido de quantas rodadas de modelo mais ferramenta um turno pode ter. | `12` |
| `temperature` | Temperatura de amostragem passada ao modelo. Sem definir usa o padrão do próprio provedor. | padrão do provedor |

## Como o ciclo de chamada de ferramentas roda

Quando você envia um turno a um agente, o runtime faz o seguinte:

1. Chama o modelo com a conversa até o momento e as especificações JSON de cada
   ferramenta na lista permitida do agente.
2. Se o modelo responder com uma resposta final, essa resposta é devolvida e o ciclo
   termina.
3. Se em vez disso o modelo pedir para chamar uma ou mais ferramentas, o runtime
   executa cada uma, anexa os resultados à conversa e volta ao passo 1.
4. Isso se repete até o modelo produzir uma resposta final ou o ciclo atingir
   `max_iterations`. Se o teto for atingido, o turno termina com a nota
   `(stopped: max iterations reached)`.

Como os resultados são devolvidos ao modelo, ele pode encadear passos. Ele pode ler
um arquivo, decidir que precisa de outro, ler esse também e então escrever um resumo,
tudo dentro de um mesmo turno. O limite de iterações é a proteção que impede que um
agente confuso fique em loop para sempre.

Outras duas barreiras ficam na frente da chamada ao modelo. Um agente cujo modelo
exige redação se recusa a rodar a menos que o agente tenha um hook de redação
ativado, e uma empresa que atingiu seu teto de gasto mensal para aqui sem novas
chamadas ao modelo. Ambas falham o turno de forma limpa em vez de seguir em
silêncio.

<div class="note"><strong>Transmissão e eventos.</strong> Conforme o ciclo roda, ele
emite eventos de ciclo de vida: um fragmento de texto transmitido
(<code>assistant_delta</code>), uma mensagem completa do assistente
(<code>assistant</code>), uma chamada de ferramenta (<code>tool_call</code>), uma
ferramenta recusada (<code>tool_denied</code>), um resultado de ferramenta
(<code>tool_result</code>), uma troca para um modelo reserva (<code>failover</code>),
um registro de uso de tokens (<code>usage</code>), uma resposta final
(<code>done</code>) ou um erro (<code>error</code>). A CLI, o WebSocket e os canais
de mensagens exibem tudo ao vivo, e por isso você vê a digitação e a atividade das
ferramentas conforme acontece, em vez de um único bloco no fim.</div>

## Ferramentas e a barreira de permissão

Uma ferramenta é uma capacidade. Um agente só pode fazer o que a sua lista `tools`
permite. Dê ao agente `read_file` mas não `write_file` e ele consegue olhar mas não
mexer.

Liste todas as ferramentas disponíveis na sua instalação:

```bash
pepe tools
```

O conjunto embutido cobre o essencial:

| Ferramenta | O que faz |
|------|--------------|
| `bash` | Executa um comando de shell. |
| `run_script` | Escreve e executa um programa curto em Python, Node, Ruby ou Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Trabalha com arquivos no espaço de trabalho do agente. |
| `fetch_url`, `web_search` | Lê uma página web ou busca na web. |
| `send_file` | Entrega um arquivo que o agente produziu no canal atual. |
| `send_to_agent` | Envia mensagem a outro agente (sujeito a `can_message`). |
| `schedule_task`, `watch` | Cria tarefas recorrentes e vigias de uma vez só do tipo "me avise quando X". |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Gere agentes, ferramentas e roteamento pelo chat. |
| `manage_channel`, `end_session` | Conecta e fecha canais de mensagens pelo chat. |
| `manage_mcp`, `scan_skill`, `skill` | Adiciona servidores de ferramentas externas e habilidades. |
| `config_get`, `config_set`, `doctor` | Inspeciona e altera a configuração sob proteções, roda diagnósticos. |

Algumas ferramentas são somente leitura e rodam livremente: `read_file`, `list_dir`,
`fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` e
`send_to_agent` (que é regida pela lista de rotas permitidas `can_message`). Todo o
resto, incluindo qualquer ferramenta de plugin, é tratado como de risco e passa por
uma barreira de permissão antes de executar.

Quando uma ferramenta de risco não foi pré-aprovada e a superfície consegue perguntar
a uma pessoa (o console, um canal de chat), o runtime te pede para autorizar a
chamada. Você pode responder:

- Permitir uma vez. Pergunta de novo na próxima.
- Permitir pelo resto desta sessão. Guardado em memória, esquecido ao reiniciar.
- Permitir sempre. Persistido no agente adicionando a ferramenta à sua lista
  `auto_approve`.
- Negar. Nunca lembrado, então é perguntado de novo.

Coloque você mesmo uma ferramenta em `auto_approve` para pular o aviso desde o
início. Em superfícies sem pessoa a quem perguntar (por exemplo a API HTTP), as
ferramentas com barreira são autorizadas a rodar para que a requisição não trave.

### Faça por chat

Um agente que acabou de instalar um plugin, ou que quer uma capacidade que ainda não
tem, pode ativar uma ferramenta em si mesmo com `enable_tool`:

```text
Enable the web_search tool for yourself.
```

O agente chama `enable_tool` com o nome da ferramenta. A ferramenta já precisa
existir como embutida ou como plugin instalado, e a mudança entra em vigor na próxima
mensagem do agente. `enable_tool` também tem barreira, então você autoriza a
concessão antes de ela ser escrita.

## A conexão de modelo

`model` nomeia uma conexão que você definiu com `pepe model add`. Deixá-lo sem
definir significa que o agente usa o modelo padrão do seu escopo, então você pode
apontar um conjunto inteiro de agentes para um provedor e trocar todos mudando um
único padrão.

Uma conexão de modelo pode carregar uma cadeia de reserva. Quando o modelo primário
do agente falha com um erro transitório (um limite de taxa, um tempo esgotado, uma
queda de rede ou um 5xx), o runtime desce pela cadeia e tenta de novo no próximo
modelo, emitindo um evento `failover` enquanto o faz. Um erro grave como uma chave de
API errada ou uma requisição mal formada falha na hora, já que outro endpoint não
resolveria.

O Pepe fala com os provedores pelo protocolo Chat Completions da OpenAI, então
qualquer endpoint compatível com OpenAI funciona sem mudança de código.

### Faça por chat

Um agente com a ferramenta `manage_agent` pode reapontar um modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino precisa
ser uma conexão configurada, e a mudança passa pela barreira de permissão como
qualquer outra edição de configuração.

## O agente padrão

Um agente por escopo pode ser o padrão. O padrão é o que roda quando você não nomeia
um agente:

```bash
pepe run "summarize this repository"
```

O primeiro agente que você cria no escopo padrão (sem empresa) vira automaticamente o
padrão. Mude a qualquer momento:

```bash
pepe agent default assistant
```

## O agente dono

O primeiro agente de todos, criado durante a configuração, é o agente do próprio
dono, e ele nasce plenamente capaz. Recebe todas as ferramentas, é superadministrador
sobre todos os outros agentes (`can_manage` é `["*"]`) e todas as suas chamadas de
ferramenta já vêm pré-aprovadas (`auto_approve` é `["*"]`) para que ele nunca pare
para perguntar. É isso que deixa você fazer trabalho de verdade por chat desde o
primeiro minuto, incluindo criar e configurar todos os agentes seguintes. Os agentes
que você adiciona depois são mais restritos por padrão: você escolhe suas
ferramentas, eles administram apenas a si mesmos e suas chamadas de risco passam pela
barreira de permissão.

## Deixar os agentes conversarem entre si

`can_message` é uma lista de rotas permitidas direcionada. Se o agente A inclui o
agente B, então A pode enviar a B uma mensagem com a ferramenta `send_to_agent`. O
contrário não está implícito. Adicione uma rota pela CLI:

```bash
pepe agent route triage assistant
```

Agora `triage` pode passar trabalho para `assistant`. Remova a rota com `--remove`.
As rotas nunca cruzam a fronteira de uma empresa; a CLI recusa `A -> B` quando os
dois estão em empresas diferentes.

### Faça por chat

Um agente com a ferramenta `set_route` pode mudar o roteamento por conversa. `from`
assume por padrão o agente que está chamando:

```text
Allow yourself to message the billing agent.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. O roteamento é
direcionado, então isso não deixa `billing` responder com mensagens. Por editar a
configuração, `set_route` passa pela barreira de permissão e você autoriza a mudança.

## Administrar agentes

`can_manage` controla quais agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) pela ferramenta `manage_agent`. É fechado por padrão e seu
significado é preciso:

- Sem definir (`null`): o agente pode administrar apenas a si mesmo.
- Vazio (`[]`, definido com `--can-manage none`): ele não pode administrar ninguém,
  nem a si mesmo. Um filho travado, por exemplo um agente voltado ao cliente que não
  pode se alterar.
- Uma lista de nomes: exatamente esses agentes, e nenhum outro. Inclua o próprio nome
  para deixar que ele também administre a si mesmo.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  explícito.

Conceda autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Faça por chat

Um agente administrador usa `manage_agent` para moldar os agentes do seu escopo. Suas
ações são `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
`remove_tool` e `remember` (anexa um fato duradouro à memória do alvo). Por exemplo:

```text
Give the support agent the send_file tool and add a note to its memory that
refunds over 200 need a human.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma dessas ações tem barreira: o agente propõe a mudança,
você a autoriza e só então ela é aplicada. Um agente também pode se renomear com a
ferramenta separada `rename_agent` ("De agora em diante, se chame scout"), que move o
diretório do seu espaço de trabalho e entra em vigor na próxima mensagem.

## Agentes multi-inquilino com empresas

Empresas são opcionais. Sem uma, tudo vive no escopo padrão, chamado Principal,
exatamente como uma instalação de inquilino único sempre funcionou. Adicione uma
empresa para isolar um inquilino: seus agentes, espaços de trabalho, espaço
compartilhado, conexões de modelo e roteamento ficam isolados de qualquer outra
empresa.

A identidade real de um agente é o seu identificador. No escopo Principal o
identificador é apenas o nome simples (`assistant`). Dentro de uma empresa ele é
qualificado como `company/name` (`acme/assistant`), então o mesmo nome simples pode
ser reutilizado entre empresas sem colisão.

Crie uma empresa e depois adicione agentes dentro dela com `--company`:

```bash
pepe company add acme --description "Acme Corp"

pepe agent add support \
  --company acme \
  --model openrouter \
  --prompt "You are Acme's support agent." \
  --tools read_file,web_search
```

Adicione `--company acme` a qualquer comando de agente para agir dentro daquele
escopo. Nomes de pares simples em `--can-message` e `--can-manage` são resolvidos
dentro da própria empresa do agente, então as rotas nunca cruzam por acidente a
fronteira de um inquilino. Cada empresa pode fixar seu próprio modelo padrão e seu
agente padrão, ou compartilhar o provedor global do operador. Um agente de empresa
nunca é promovido a padrão global (Principal) só por ser o primeiro criado dentro da
sua empresa.

## Gerir agentes pela CLI

```bash
# Create an agent. Omit --tools to grant all tools; pass --tools "" for none.
pepe agent add NAME \
  --model MODEL \
  --prompt "..." \
  --tools t1,t2 \
  [--description "..."] \
  [--can-message b,c] \
  [--can-manage x,y | "*" | none] \
  [--hooks pii_redact] \
  [--max-iterations 12] \
  [--temperature 0.7] \
  [--default] \
  [--company CO]

# List agents in a scope, or every agent everywhere.
pepe agent list [--company CO | --all]

# Directed messaging: let FROM message TO.
pepe agent route FROM TO [--remove] [--company CO]

# Management authority: let ADMIN administer TARGET (or "*" for all).
pepe agent manage ADMIN TARGET [--remove] [--company CO]

# Rename an agent and move its workspace directory.
pepe agent rename OLD NEW

# Delete an agent.
pepe agent remove NAME [--company CO]

# Set the default agent for a scope.
pepe agent default NAME [--company CO]
```

## Rodar um agente

O mesmo agente é alcançável de quatro formas.

**De uma vez só pela CLI.** Sem sessão, transmite para o stdout.

```bash
pepe run assistant "your prompt here"
```

**Console interativo.** Mantém a conversa, então o contexto passa de um turno para o
outro. Retome ou separe sessões de console com `--session KEY`.

```bash
pepe tui assistant
```

**Por HTTP e WebSocket.** Suba o servidor e depois chame a API compatível com OpenAI
ou abra um WebSocket de transmissão. O campo `model` da requisição nomeia o agente.

```bash
pepe serve --port 4000
```

```http
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "assistant",
  "messages": [{ "role": "user", "content": "your prompt here" }]
}
```

O WebSocket é servido em `ws://localhost:4000/socket/websocket`, e a verificação de
saúde em `GET /health`.

**Por um canal de mensagens.** Vincule um agente a uma conexão de Telegram, WhatsApp,
Slack, Discord, Microsoft Teams ou Google Chat, ou a um webhook de entrada genérico,
e ele responde ali com o mesmo ciclo e as mesmas ferramentas.
