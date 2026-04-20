---
title: Agentes
description: Define um agente a partir de um prompt, um modelo e um conjunto de ferramentas, e deixa o runtime chamar o modelo, executar ferramentas e repetir o ciclo até chegar a uma resposta.
---

## O que é um agente

Um agente é uma definição pequena e declarativa. Tem um nome, um system prompt que
lhe dá uma personalidade, uma ligação de modelo com a qual raciocinar e uma lista de
ferramentas que tem permissão para chamar. Um punhado de opções extra (um limite de
iterações, uma temperatura, com quem pode falar, quem pode administrar) completam o
conjunto. É tudo. O agente não guarda lógica própria. O runtime do Pepe faz o
trabalho: chama o modelo, executa as ferramentas que o modelo pedir, devolve os
resultados e repete até haver uma resposta final.

Cada agente vive como uma entrada dentro de um único ficheiro JSON em
`~/.pepe/config.json`. Não há base de dados. Podes criar e editar agentes de três
formas, e todas escrevem no mesmo ficheiro:

1. A ferramenta de linha de comandos `pepe`.
2. O painel web.
3. Uma conversa normal, falando com um agente que tenha a ferramenta de gestão
   correspondente.

Eis um agente completo tal como fica em disco:

```json
{
  "agents": {
    "assistant": {
      "description": "General-purpose helper",
      "model": "openrouter",
      "system_prompt": "És um assistente prestável e direto.",
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

## O teu primeiro agente

Um agente precisa de uma ligação de modelo antes de conseguir raciocinar. Se ainda
não criaste nenhuma, a configuração guiada acompanha-te para escolher um fornecedor,
iniciar sessão e escolher um modelo:

```bash
pepe setup
```

Depois define um agente com um prompt e algumas ferramentas:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "És um assistente prestável e direto." \
  --tools bash,read_file,write_file,web_search
```

Corre um prompt de uma só vez contra ele. A resposta é transmitida para o teu
terminal à medida que é produzida:

```bash
pepe run assistant "Que ficheiros existem no diretório atual?"
```

Esse único comando dispara o ciclo completo. O agente decide que precisa de olhar
para o sistema de ficheiros, chama a ferramenta `list_dir` ou `bash`, lê o resultado
e responde-te em linguagem natural.

<div class="note"><strong>A partir do painel.</strong> A secção de Agentes do painel
web faz o mesmo com um formulário: nome, personalidade, modelo, uma lista de seleção
de ferramentas e o âmbito de administração. Escreve a mesma entrada em
<code>~/.pepe/config.json</code>, por isso podes combinar livremente a CLI, o painel
e a edição manual.</div>

### Fá-lo pela conversa

Qualquer agente que tenha a ferramenta `manage_agent` pode criar e configurar outros
agentes por conversa. É assim que o primeiríssimo agente (vê "O agente proprietário"
mais abaixo) te deixa construir o resto da tua frota sem tocar na CLI. Uma mensagem
como:

```text
Cria um agente chamado researcher. Dá-lhe uma persona focada em pesquisa
cuidadosa na web, aponta-o ao modelo openrouter e ativa web_search e
fetch_url.
```

O agente chama `manage_agent` com `action: "create"`, e depois `set_persona`,
`set_model` e `add_tool` para cada capacidade. `manage_agent` é uma ferramenta de
risco: passa pela barreira de permissão, por isso numa superfície que consegue
perguntar (a consola, um canal de chat) o runtime pede-te para autorizar a alteração
antes de a escrever, e a própria ferramenta é instruída a confirmar o plano contigo
primeiro. Um agente só pode gerir os agentes dentro do seu âmbito `can_manage`
(tratado em [Administrar agentes](#administrar-agentes) mais abaixo); pedir-lhe para mexer num que esteja
fora desse âmbito é recusado com cortesia.

## Os campos, um a um

| Campo | O que faz | Predefinição |
|-------|--------------|---------|
| `name` | A identidade do agente, e a chave sob a qual é guardado e endereçado. Dentro de uma empresa passa a ser um identificador como `acme/assistant` (vê abaixo). | obrigatório |
| `description` | Uma nota curta para humanos. Nunca enviada ao modelo. | nenhum |
| `model` | O nome de uma ligação de modelo. Deixa por definir para usar o modelo predefinido do âmbito. | predefinição do âmbito |
| `system_prompt` | A personalidade e as instruções com que o agente corre. | `És o Pepe, um agente de IA prestável.` (um prompt inicial) |
| `tools` | A lista de nomes de ferramentas que este agente pode chamar. Só estas são oferecidas ao modelo. | todas as ferramentas quando `--tools` é omitido na criação |
| `auto_approve` | Ferramentas que este agente pode executar sem pedir permissão. `["*"]` significa todas. | `[]` |
| `can_message` | Outros agentes aos quais este pode enviar mensagens (uma rota dirigida). | `[]` |
| `can_manage` | Que agentes este pode administrar. Vê [Administrar agentes](#administrar-agentes). | `null` (só a si próprio) |
| `hooks` | Transformações do fluxo de mensagens a aplicar, como a redação de dados pessoais. | `[]` |
| `max_iterations` | O limite máximo de quantas rondas de modelo mais ferramenta um turno pode ter. | `12` |
| `temperature` | Temperatura de amostragem passada ao modelo. Por definir usa a predefinição do próprio fornecedor. | predefinição do fornecedor |
| `triage_model` | Uma ligação de modelo que julga a complexidade antes do primeiro turno de uma sessão. Vê [Encaminhamento de modelo por complexidade](#encaminhamento-de-modelo-por-complexidade). | nenhum (desligado) |
| `simple_model` | A ligação de modelo para a qual desce quando `triage_model` julga uma conversa simples. | nenhum |

## Como corre o ciclo de chamada de ferramentas

Quando envias um turno a um agente, o runtime faz o seguinte:

1. Chama o modelo com a conversa até ao momento e as especificações JSON de cada
   ferramenta na lista permitida do agente.
2. Se o modelo responder com uma resposta final, essa resposta é devolvida e o ciclo
   termina.
3. Se em vez disso o modelo pedir para chamar uma ou mais ferramentas, o runtime
   executa cada uma, acrescenta os resultados à conversa e volta ao passo 1.
4. Isto repete-se até o modelo produzir uma resposta final ou o ciclo atingir
   `max_iterations`. Se o limite for atingido, o turno termina com a nota
   `(stopped: max iterations reached)`.

Como os resultados são devolvidos ao modelo, ele pode encadear passos. Pode ler um
ficheiro, decidir que precisa de outro, ler esse também e depois escrever um resumo,
tudo dentro de um mesmo turno. O limite de iterações é a salvaguarda que impede que
um agente confuso ande em ciclo para sempre.

Outras duas barreiras ficam à frente da chamada ao modelo. Um agente cujo modelo
exige redação recusa-se a correr a menos que o agente tenha um hook de redação
ativado, e uma empresa que atingiu o seu limite de gasto mensal - ou o seu limite de
mensagens de clientes por mês, um limite separado - para aqui sem novas chamadas ao
modelo nem respostas. Ambas falham o turno de forma limpa em vez de prosseguir em
silêncio; ver Faturação e limites para saber como configurar esses limites.

<div class="note"><strong>Transmissão e eventos.</strong> À medida que o ciclo corre,
emite eventos de ciclo de vida: um fragmento de texto transmitido
(<code>assistant_delta</code>), uma mensagem completa do assistente
(<code>assistant</code>), uma chamada de ferramenta (<code>tool_call</code>), uma
ferramenta recusada (<code>tool_denied</code>), um resultado de ferramenta
(<code>tool_result</code>), uma troca para um modelo de reserva
(<code>failover</code>), um registo de uso de tokens (<code>usage</code>), uma
resposta final (<code>done</code>) ou um erro (<code>error</code>). A CLI, o WebSocket
e os canais de mensagens mostram tudo ao vivo, e é por isso que vês a escrita e a
atividade das ferramentas à medida que acontece, em vez de um único bloco no fim.</div>

## Ferramentas e a barreira de permissão

Uma ferramenta é uma capacidade. Um agente só pode fazer aquilo que a sua lista
`tools` permite. Dá a um agente `read_file` mas não `write_file` e ele consegue olhar
mas não mexer.

Lista todas as ferramentas disponíveis na tua instalação:

```bash
pepe tools
```

O conjunto integrado cobre o essencial:

| Ferramenta | O que faz |
|------|--------------|
| `bash` | Executa um comando de shell. |
| `run_script` | Escreve e executa um programa curto em Python, Node, Ruby ou Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Trabalha com ficheiros no espaço de trabalho do agente. |
| `fetch_url`, `web_search` | Lê uma página web ou pesquisa na web. |
| `send_file` | Entrega um ficheiro que o agente produziu no canal atual. |
| `send_to_agent` | Envia mensagem a outro agente (sujeito a `can_message`). |
| `schedule_task`, `watch` | Cria tarefas recorrentes e vigias de uma só vez do tipo "avisa-me quando X". |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Gere agentes, ferramentas e encaminhamento pelo chat. |
| `manage_channel`, `end_session` | Liga e fecha canais de mensagens pelo chat. |
| `manage_mcp`, `scan_skill`, `skill` | Adiciona servidores de ferramentas externas e competências. |
| `manage_plugin` | Instala, verifica, lista e remove plugins da comunidade (ferramentas, canais) pelo chat. |
| `config_get`, `config_set`, `doctor` | Inspeciona e altera a configuração sob salvaguardas, corre diagnósticos. |

Algumas ferramentas são só de leitura e correm livremente: `read_file`, `list_dir`,
`fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` e
`send_to_agent` (que é regida pela lista de rotas permitidas `can_message`). Todo o
resto, incluindo qualquer ferramenta de plugin, é tratado como de risco e passa por
uma barreira de permissão antes de executar.

Quando uma ferramenta de risco não foi pré-aprovada e a superfície consegue perguntar
a uma pessoa (a consola, um canal de chat), o runtime pede-te para autorizar a
chamada. Podes responder:

- Permitir uma vez. Pergunta de novo na próxima.
- Permitir durante o resto desta sessão. Guardado em memória, esquecido ao
  reiniciar.
- Permitir sempre. Persistido no agente ao adicionar a ferramenta à sua lista
  `auto_approve`.
- Recusar. Nunca é lembrado, por isso é perguntado de novo.

Coloca tu próprio uma ferramenta em `auto_approve` para saltar o aviso desde o
início. Em superfícies sem pessoa a quem perguntar (por exemplo a API HTTP), as
ferramentas com barreira são autorizadas a correr para que o pedido não fique preso.

### Fá-lo pela conversa

Um agente que acabou de instalar um plugin, ou que quer uma capacidade que ainda não
tem, pode ativar uma ferramenta em si próprio com `enable_tool`:

```text
Enable the web_search tool for yourself.
```

O agente chama `enable_tool` com o nome da ferramenta. A ferramenta já tem de existir
como integrada ou como plugin instalado, e a alteração entra em vigor na próxima
mensagem do agente. `enable_tool` tem barreira também, por isso autorizas a concessão
antes de ser escrita.

## A ligação de modelo

`model` nomeia uma ligação que definiste com `pepe model add`. Deixá-la por definir
significa que o agente usa o modelo predefinido do seu âmbito, por isso podes apontar
um conjunto inteiro de agentes para um fornecedor e trocá-los todos ao mudar uma
única predefinição.

Uma ligação de modelo pode transportar uma cadeia de reserva. Quando o modelo
primário do agente falha com um erro transitório (um limite de taxa, um tempo
esgotado, uma quebra de rede ou um 5xx), o runtime desce pela cadeia e volta a tentar
no modelo seguinte, emitindo um evento `failover` enquanto o faz. Um erro grave como
uma chave de API errada ou um pedido mal formado falha de imediato, já que outro
endpoint não o resolveria.

O Pepe fala com os fornecedores através do protocolo Chat Completions da OpenAI, por
isso qualquer endpoint compatível com OpenAI funciona sem alteração de código.

### Fá-lo pela conversa

Um agente com a ferramenta `manage_agent` pode reapontar um modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino tem de
ser uma ligação configurada, e a alteração passa pela barreira de permissão como
qualquer outra edição de configuração.

## Encaminhamento de modelo por complexidade

O próprio `model` de um agente é tratado como a boa predefinição. Opcionalmente,
uma chamada de classificação barata e direta pode julgar se uma conversa é
simples o suficiente para *descer* para algo mais barato, antes mesmo de o
turno a sério começar. Sem agente extra para configurar, só dois campos:

- `triage_model`: uma ligação de modelo que classifica a mensagem recebida com
  um prompt fixo e incorporado (não uma persona que escreves); o Pepe só
  procura a palavra "SIMPLE" na resposta.
- `simple_model`: a ligação de modelo para a qual desce (e fica, durante o
  resto da sessão) assim que o veredito da triagem for simples.

```bash
pepe agent add assistant \
  --model modelo-forte-e-caro \
  --triage-model modelo-barato-e-rapido \
  --simple-model modelo-do-dia-a-dia \
  --prompt "..." \
  --tools bash,read_file,web_search
```

A triagem corre uma única vez, no primeiro turno de uma sessão, nunca mais
naquela mesma sessão. Assim que uma conversa é julgada simples, fica no
modelo mais barato durante o resto da conversa (o mesmo mecanismo que o
comando `/model` usa para mudar o modelo de uma sessão, só que acionado
automaticamente em vez de à mão). Um veredito complexo não muda nada: a sessão
corre no próprio modelo do agente exatamente como correria sem `triage_model`
definido.

A triagem é uma otimização de melhor esforço, nunca uma dependência. Se o
modelo de triagem não existe, está inacessível, ou demora demasiado tempo (com
um limite de poucos segundos), o turno segue no próprio modelo do agente, em
silêncio. Uma falha na triagem nunca bloqueia nem quebra uma conversa.
`simple_model` também precisa de estar definido para a triagem correr; senão
não haveria para onde descer.

Cada veredito aparece como um passo próprio no Trace desse turno (o replay de
cada execução no painel), junto de qualquer hook de privacidade que tenha
corrido sobre a mensagem. Assim vês exatamente porque é que uma sessão
acabou num modelo e não noutro.

## O agente predefinido

Um agente por âmbito pode ser o predefinido. O predefinido é o que corre quando não
nomeias um agente:

```bash
pepe run "resume este repositório"
```

O primeiro agente que crias no âmbito predefinido (sem empresa) torna-se
automaticamente o predefinido. Muda-o quando quiseres:

```bash
pepe agent default assistant
```

## O agente proprietário

O primeiríssimo agente criado durante a configuração é o agente do próprio
proprietário, e nasce plenamente capaz. Recebe todas as ferramentas, é
superadministrador sobre todos os outros agentes (`can_manage` é `["*"]`) e todas as
suas chamadas de ferramenta vêm pré-aprovadas (`auto_approve` é `["*"]`) para que
nunca pare para perguntar. É isto que te deixa fazer trabalho a sério pela conversa desde
o primeiro minuto, incluindo criar e configurar todos os agentes seguintes. Os
agentes que adicionas depois são mais restritos por predefinição: escolhes as suas
ferramentas, administram apenas a si próprios e as suas chamadas de risco passam pela
barreira de permissão.

## Deixar os agentes falarem entre si

`can_message` é uma lista de rotas permitidas dirigida. Se o agente A inclui o agente
B, então A pode enviar a B uma mensagem com a ferramenta `send_to_agent`. O contrário
não está implícito. Adiciona uma rota pela CLI:

```bash
pepe agent route triage assistant
```

Agora `triage` pode passar trabalho a `assistant`. Remove a rota com `--remove`. As
rotas nunca cruzam a fronteira de uma empresa; a CLI recusa `A -> B` quando os dois
estão em empresas diferentes.

### Fá-lo pela conversa

Um agente com a ferramenta `set_route` pode mudar o encaminhamento por conversa.
`from` assume por predefinição o agente que está a chamar:

```text
Allow yourself to message the billing agent.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. O encaminhamento
é dirigido, por isso isto não deixa `billing` responder com mensagens. Por editar a
configuração, `set_route` passa pela barreira de permissão e tu autorizas a alteração.

## Administrar agentes

`can_manage` controla que agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) através da ferramenta `manage_agent`. É fechado por
predefinição e o seu significado é preciso:

- Por definir (`null`): o agente só pode administrar-se a si próprio.
- Vazio (`[]`, definido com `--can-manage none`): não pode administrar ninguém, nem
  sequer a si próprio. Um filho bloqueado, por exemplo um agente virado para o
  cliente que não se deve alterar.
- Uma lista de nomes: exatamente esses agentes, e mais nenhum. Inclui o próprio nome
  para o deixar administrar-se também a si próprio.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  explícito.

Concede autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Fá-lo pela conversa

Um agente administrador usa `manage_agent` para moldar os agentes do seu âmbito. As
suas ações são `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
`remove_tool` e `remember` (acrescenta um facto duradouro à memória do alvo). Por
exemplo:

```text
Dá ao agente de apoio a ferramenta send_file e regista na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Cada uma destas ações tem barreira: o agente propõe a
alteração, tu autoriza-la e só então é aplicada. Um agente também se pode renomear
com a ferramenta separada `rename_agent` ("De agora em diante, chama-te scout"), que
move o diretório do seu espaço de trabalho e entra em vigor na próxima mensagem.

## Agentes multiempresa com empresas

As empresas são opcionais. Sem uma, tudo vive no âmbito predefinido, chamado
Principal, exatamente como uma instalação de empresa única sempre funcionou.
Adiciona uma empresa para isolar uma empresa: os seus agentes, espaços de trabalho,
espaço partilhado, ligações de modelo e encaminhamento ficam isolados de qualquer
outra empresa.

A identidade real de um agente é o seu identificador. No âmbito Principal o
identificador é apenas o nome simples (`assistant`). Dentro de uma empresa é
qualificado como `company/name` (`acme/assistant`), por isso o mesmo nome simples
pode ser reutilizado entre empresas sem colisão.

Cria uma empresa e depois adiciona agentes dentro dela com `--company`:

```bash
pepe company add acme --description "Acme Corp"

pepe agent add support \
  --company acme \
  --model openrouter \
  --prompt "És o agente de apoio da Acme." \
  --tools read_file,web_search
```

Adiciona `--company acme` a qualquer comando de agente para agir dentro desse âmbito.
Nomes de pares simples em `--can-message` e `--can-manage` resolvem-se dentro da
própria empresa do agente, por isso as rotas nunca cruzam por acidente a fronteira de
uma empresa. Cada empresa pode fixar o seu próprio modelo predefinido e o seu agente
predefinido, ou partilhar o fornecedor global do operador. Um agente de empresa nunca
é promovido a predefinido global (Principal) só por ser o primeiro criado dentro da
sua empresa.

## Gerir agentes pela CLI

```bash
# Cria um agente. Omite --tools para conceder todas as ferramentas; passa --tools "" para nenhuma.
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
  [--triage-model MODEL] \
  [--simple-model MODEL] \
  [--default] \
  [--company CO]

# Lista agentes num âmbito, ou todos os agentes.
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

## Correr um agente

O mesmo agente é alcançável de quatro formas.

**De uma só vez pela CLI.** Sem sessão, transmite para o stdout.

```bash
pepe run assistant "your prompt here"
```

**Consola interativa.** Mantém a conversa, por isso o contexto passa de um turno para
o outro. Retoma ou separa sessões de consola com `--session KEY`.

```bash
pepe tui assistant
```

**Por HTTP e WebSocket.** Arranca o servidor e depois chama a API compatível com
OpenAI ou abre um WebSocket de transmissão. O campo `model` do pedido nomeia o agente.

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

**Através de um canal de mensagens.** Liga um agente a uma ligação de Telegram,
WhatsApp, Slack, Discord, Microsoft Teams ou Google Chat, ou a um webhook de entrada
genérico, e ele responde ali com o mesmo ciclo e as mesmas ferramentas.
