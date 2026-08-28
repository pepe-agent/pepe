---
title: Agentes
description: Descreve um agente uma única vez, com as suas instruções, o seu modelo e as suas ferramentas, e o Pepe trata do resto, chamando o modelo e a executar ferramentas até ter uma resposta a sério.
---

## O que é um agente

Um agente resume-se a uma descrição curta que escreves uma vez: o nome, as
instruções (o prompt de sistema que lhe dá uma persona), o modelo com que pensa e a
lista de ferramentas que tem permissão para chamar. Um punhado de opções adicionais,
um limite de iterações, uma temperatura, quem pode contactar, quem pode administrar,
fecham o conjunto. É só isto. O próprio agente não guarda nenhuma lógica: quem faz o
trabalho é o Pepe, chamando o modelo, executando as ferramentas que este pede,
devolvendo-lhe os resultados e repetindo o processo até surgir uma resposta final.

Cada agente existe como uma entrada dentro de um único ficheiro JSON,
`~/.pepe/config.json`. Não há nenhuma base de dados por trás disto. Há três formas de
criar e editar agentes, e todas acabam por escrever no mesmo ficheiro:

1. A ferramenta de linha de comandos `pepe`.
2. O painel web.
3. Uma conversa normal, falando com um agente que já tenha a ferramenta de gestão
   correspondente.

Assim fica um agente completo, tal como é guardado em disco:

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

Antes de conseguir pensar, um agente precisa de uma ligação de modelo. Se ainda não
tens nenhuma criada, a configuração guiada leva-te pela mão a escolher um
fornecedor, a iniciar sessão e a selecionar um modelo:

```bash
pepe setup
```

A seguir, define um agente com um prompt e algumas ferramentas:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "És um assistente prestável e direto." \
  --tools bash,read_file,write_file,web_search
```

Corre um prompt avulso contra ele. A resposta vai sendo transmitida para o teu
terminal à medida que é produzida:

```bash
pepe run assistant "Que ficheiros existem no diretório atual?"
```

Só este comando já dispara o ciclo completo: o agente percebe que precisa de
espreitar o sistema de ficheiros, chama a ferramenta `list_dir` ou `bash`, lê o
resultado e devolve-te a resposta em linguagem corrente.

<div class="note"><strong>A partir do painel.</strong> A secção de Agentes do painel
web faz exatamente o mesmo através de um formulário: nome, persona, modelo, uma
lista de ferramentas para marcar e o âmbito de administração. O que escreve em
<code>~/.pepe/config.json</code> é a mesma entrada, por isso podes alternar
livremente entre a CLI, o painel e a edição manual do ficheiro.</div>

### Fazer isto por chat

Qualquer agente com a ferramenta `manage_agent` consegue criar e configurar outros
agentes através de conversa. É assim que o primeiro agente de todos (ver "O agente
proprietário" mais abaixo) te deixa construir o resto da tua frota sem nunca tocar
na CLI. Uma mensagem como esta:

```text
Cria um agente chamado researcher. Dá-lhe uma persona focada em pesquisa
cuidadosa na web, aponta-o ao modelo openrouter e ativa web_search e
fetch_url.
```

faz o agente chamar `manage_agent` com `action: "create"` e, a seguir,
`set_persona`, `set_model` e `add_tool` para cada capacidade pedida. O `manage_agent`
é uma ferramenta de risco, por isso passa sempre pela barreira de permissão: numa
superfície onde há alguém a quem perguntar (a consola, um canal de chat), o runtime
pede-te para autorizares a alteração antes de a escrever, e a própria ferramenta
está instruída a confirmar contigo o plano primeiro. Um agente só consegue gerir os
agentes dentro do seu âmbito `can_manage` (explicado mais abaixo, em
[Administrar agentes](#administrar-agentes)); pedir-lhe para mexer nalgum que esteja
fora desse âmbito é simplesmente recusado, com educação.

## Os campos, um a um

| Campo | O que faz | Predefinição |
|-------|--------------|---------|
| `name` | O rótulo pelo qual o agente é endereçado. Dentro de um projeto passa a um identificador como `acme/assistant` (ver abaixo). O agente também guarda um id interno estável, por isso mudar este nome nunca quebra nenhuma ligação já existente. | obrigatório |
| `description` | Uma nota curta, só para humanos lerem. Nunca é enviada ao modelo. | nenhuma |
| `model` | O nome de uma ligação de modelo. Deixa por preencher para usar o modelo predefinido do projeto. | predefinição do projeto |
| `system_prompt` | A persona e as instruções com que o agente corre. | `És o Pepe, um agente de IA prestável.` (um prompt semente) |
| `langfuse_prompt` | Vai buscar a persona ao prompt deste nome no [Langfuse](#gerir-uma-persona-a-partir-do-langfuse), em vez de usar `system_prompt`. | `null` (desligado) |
| `tools` | A lista de ferramentas que este agente pode chamar. Só estas chegam a ser oferecidas ao modelo. | todas as ferramentas: um agente novo nasce com tudo ligado, e és tu quem retira o que não quer |
| `auto_approve` | Ferramentas que este agente pode correr sem pedir autorização. `["*"]` significa todas. | `[]` |
| `can_message` | Outros agentes a quem este pode enviar mensagens (uma rota de sentido único). | `[]` |
| `can_manage` | Que agentes este pode administrar. Ver [Administrar agentes](#administrar-agentes). | `null` (só a si próprio) |
| `hooks` | Transformações a aplicar ao fluxo de mensagens, como a redação de dados pessoais. | `[]` |
| `max_iterations` | O teto rígido de quantas rondas de modelo mais ferramenta um turno pode levar. | `12` |
| `temperature` | A temperatura de amostragem passada ao modelo. Por definir, usa-se a predefinição do próprio fornecedor. | predefinição do fornecedor |
| `triage_model` | Uma ligação de modelo que avalia a complexidade antes do primeiro turno de uma sessão. Ver [Encaminhamento de modelo por complexidade](#encaminhamento-de-modelo-por-complexidade). | nenhuma (desligado) |
| `simple_model` | A ligação de modelo para a qual descer quando o `triage_model` considera uma conversa simples. | nenhuma |

## Como corre o ciclo de chamada de ferramentas

Ao enviares uma mensagem a um agente, o Pepe segue estes passos:

1. Chama o modelo com a conversa acumulada até ali e a descrição de cada ferramenta
   que o agente tem permissão para usar.
2. Se o modelo responder com uma resposta final, é essa que te é devolvida e o ciclo
   termina ali.
3. Se, em vez disso, o modelo pedir para chamar uma ou mais ferramentas, o Pepe
   corre cada uma delas, junta os resultados à conversa e volta ao passo 1.
4. Este ciclo repete-se até o modelo produzir uma resposta final ou até se atingir o
   `max_iterations`. Quando o limite é alcançado, o turno termina com a nota
   `(stopped: max iterations reached)`.

Como os resultados voltam sempre para a conversa, o modelo consegue encadear passos:
lê um ficheiro, decide que precisa de outro, lê esse também, e só depois escreve um
resumo, tudo dentro do mesmo turno. O limite de iterações existe precisamente para
travar um agente confuso antes que ele entre num ciclo sem fim.

Há ainda duas outras barreiras antes da chamada ao modelo. Um agente cujo modelo
exige redação recusa-se a correr enquanto não tiver um hook de redação ativo, e um
projeto que já atingiu o seu teto de gasto mensal (ou o seu teto separado de
mensagens de clientes por mês) para tudo ali mesmo, sem novas chamadas ao modelo nem
respostas. Em ambos os casos o turno falha de forma limpa, em vez de continuar às
escondidas; consulta Faturação e limites para saberes como esses tetos se
configuram.

<div class="note"><strong>Transmissão e eventos.</strong> Enquanto o ciclo corre, vai
emitindo eventos de ciclo de vida: um fragmento de texto transmitido
(<code>assistant_delta</code>), uma mensagem completa do assistente
(<code>assistant</code>), uma chamada de ferramenta (<code>tool_call</code>), uma
ferramenta recusada (<code>tool_denied</code>), o resultado de uma ferramenta
(<code>tool_result</code>), uma mudança para um modelo de reserva
(<code>failover</code>), um registo de consumo de tokens (<code>usage</code>), a
resposta final (<code>done</code>) ou um erro (<code>error</code>). É por a CLI, o
WebSocket e os canais de mensagens mostrarem tudo isto ao vivo que vês a escrita e a
atividade das ferramentas a acontecer em tempo real, em vez de receberes tudo num
único bloco no final.</div>

## Conversas longas: compactação

Uma conversa não cresce indefinidamente dentro da janela de contexto do modelo (a
quantidade de conversa que um modelo consegue ver de uma só vez). Assim que o
tamanho estimado ultrapassa cerca de 60% dessa janela, o Pepe substitui o **meio**
do histórico por um resumo curto que o próprio modelo escreve de si mesmo, mantendo
o prompt de sistema e os turnos mais recentes tal como estão, palavra por palavra.
Isto acontece sozinho, sem qualquer configuração: a transcrição completa continua
guardada (ver Traces); só o que é enviado ao modelo fica condensado.

Por omissão, esse resumo é feito **uma vez**, do zero, sempre que o limiar volta a
ser ultrapassado. Isso chega para a maioria das conversas, mas uma que se prolongue
bastante pode acabar por atingi-lo repetidamente, resumindo de cada vez um meio que
só ficou maior. Um agente pode optar antes pelo `micro_compaction`: quando a janela
enche, passa a dobrar, a cada turno, exatamente a troca mais antiga que ainda não
tinha sido resumida, num resumo que se vai atualizando aos poucos, um custo pequeno
e constante em vez de uma paragem periódica. A contrapartida existe mesmo, e é por
isso que vem desligado por omissão: uma vez ativo, o resumo em curso muda a cada
turno, e isso impede o fornecedor de reaproveitar a cópia em cache do início fixo do
prompt entre chamadas. Compensa para uma conversa longa o suficiente para atingir o
limiar com frequência; não compensa para uma curta.

```bash
pepe agent add support --micro-compaction ...
```

Também podes ligar isto num agente já existente através do editor de agentes do
painel, ou pedindo a um agente com a ferramenta `manage_agent` que ligue o
interruptor `micro_compaction` noutro agente.

## Mencionar o que mais o agente sabe fazer

Quem já usa um agente para uma coisa raramente descobre sozinho que ele também
consegue vigiar algo à espera de uma mudança, correr uma tarefa recorrente ou
perseguir um objetivo até ele estar de facto concluído: nada disso aparece a menos
que a própria persona do agente o mencione. O `capability_nudge`, desligado por
omissão, permite que o agente acrescente, logo depois de ter ajudado com algo, uma
frase curta e natural a apontar para uma funcionalidade relacionada, sempre que uma
se aplique mesmo. Não é um menu nem acontece em todos os turnos: é descoberta pelo
uso, não uma avalanche de onboarding.

```bash
pepe agent add support --capability-nudge ...
```

Deixa isto desligado num agente que precise de se manter direto e transacional;
liga-o a partir do editor de agentes do painel, ou pedindo a um agente com a
ferramenta `manage_agent` que ative a flag `capability_nudge` noutro agente.

## Ferramentas e a barreira de permissão

Uma ferramenta é uma capacidade, e um agente só consegue fazer o que a sua lista
`tools` permite. Dá a um agente `read_file` mas não `write_file`, e ele consegue
olhar, mas não mexer.

Para veres todas as ferramentas disponíveis na tua instalação:

```bash
pepe tools
```

O conjunto que já vem incluído cobre o essencial:

| Ferramenta | O que faz |
|------|--------------|
| `bash` | Corre um comando de shell. |
| `run_script` | Escreve e corre um programa curto em Python, Node, Ruby ou Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Trabalham com ficheiros dentro do workspace do agente. |
| `fetch_url`, `web_search` | Lê uma página web ou pesquisa na internet. |
| `send_file` | Entrega, no canal atual, um ficheiro que o agente produziu. |
| `send_to_agent` | Envia uma mensagem a outro agente (sujeito ao `can_message`). |
| `ask_user` | Pede-te para escolheres entre algumas opções, com botões ou menu a sério onde o canal o suportar. |
| `schedule_task`, `watch` | Criam tarefas recorrentes e vigias pontuais do tipo "avisa-me quando X acontecer". |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Gerem agentes, ferramentas e encaminhamento diretamente pelo chat. |
| `manage_channel`, `end_session` | Ligam e fecham canais de mensagens pelo chat. |
| `manage_mcp`, `scan_skill`, `skill` | Adicionam servidores de ferramentas externas e skills. |
| `manage_plugin` | Instala, verifica, lista e remove plugins da comunidade (ferramentas, canais) pelo chat. |
| `config_get`, `config_set`, `doctor` | Consultam e alteram a configuração com salvaguardas, e correm diagnósticos. |

Algumas ferramentas apenas leem coisas, por isso correm livremente: `read_file`,
`list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`,
`scan_skill` e `send_to_agent` (esta última é regida pelas rotas `can_message` em
vez de por uma barreira). Tudo o resto, incluindo qualquer ferramenta vinda de um
plugin, é considerado de risco e passa por uma barreira de permissão antes de
correr.

Quando uma ferramenta de risco ainda não foi pré-aprovada e a superfície tem
alguém a quem perguntar (a consola, um canal de chat), o Pepe pede-te autorização
para a chamada. As respostas possíveis são:

- Permitir uma vez. Volta a perguntar da próxima vez.
- Permitir durante o resto desta execução. Só é oferecida enquanto a execução
  tiver absorvido conteúdo vindo de fora (ver
  [Segurança e ambiente isolado](../security/)): é o único tipo de pré-aprovação
  que continua mesmo a funcionar dentro dessa janela.
- Permitir durante o resto desta sessão. Fica guardado em memória e esquecido ao
  reiniciar.
- Permitir sempre. Fica gravado no agente, ao juntares a ferramenta à sua lista
  `auto_approve`.
- Recusar. Nunca fica registado, por isso volta a ser perguntado.

Podes tu próprio colocar uma ferramenta em `auto_approve` para saltar logo o aviso.
Em superfícies onde não há ninguém a quem perguntar (por exemplo a API HTTP, um
webhook, uma tarefa de cron), uma ferramenta com barreira é recusada, em vez de
correr sem ninguém a vigiar: só corre o que já estiver em `auto_approve`.

### A pedir-te para escolheres

Há perguntas que se respondem melhor com um toque do que por escrito. O `ask_user`
deixa um agente apresentar uma escolha múltipla a sério e receber a resposta ainda
dentro do mesmo turno, em vez de adivinhar ou terminar o turno na esperança de que a
próxima mensagem responda exatamente ao que foi perguntado. No Telegram aparece como
botões inline a sério; na consola, como um menu numerado; no chat do painel, como
opções clicáveis. Corre livremente, já que perguntar não traz risco nenhum e por
isso nunca passa pela barreira de permissão, mas só funciona onde exista mesmo
alguém interativo a quem perguntar: a API HTTP, um webhook ou uma execução de
cron/watch sem supervisão recusam logo a chamada, em vez de ficarem à espera de um
botão que ninguém pode carregar.

### Fazer isto por chat

Um agente que acabou de instalar um plugin, ou que precisa de uma capacidade que
ainda não tem, consegue ativar uma ferramenta em si próprio com o `enable_tool`:

```text
Enable the web_search tool for yourself.
```

O agente chama `enable_tool` com o nome da ferramenta pretendida. Essa ferramenta
já tem de existir, como integrada ou como plugin instalado, e a alteração só entra
em vigor a partir da mensagem seguinte do agente. O `enable_tool` também passa por
barreira, por isso autorizas a concessão antes de ela ficar escrita.

## A ligação de modelo

`model` aponta para uma ligação que definiste com `pepe model add`. Deixá-lo por
preencher significa que o agente passa a usar o modelo predefinido do seu projeto,
o que te permite apontar um conjunto inteiro de agentes para um só fornecedor e
trocá-los todos de uma vez, mudando apenas essa predefinição.

Uma ligação de modelo pode carregar uma cadeia de reserva. Quando o modelo primário
do agente falha com um erro transitório (um limite de taxa, um tempo esgotado, uma
falha de rede ou um 5xx), o Pepe desce pela cadeia e tenta de novo no modelo
seguinte, emitindo um evento `failover` nesse momento. Já um erro grave, como uma
chave de API inválida ou um pedido mal formado, falha logo, sem tentar mais nada,
porque outro endpoint não resolveria o problema de qualquer forma.

O Pepe comunica com os fornecedores através do protocolo Chat Completions da
OpenAI, por isso qualquer endpoint compatível com a OpenAI funciona sem ser preciso
alterar nada no código.

### Fazer isto por chat

Um agente com a ferramenta `manage_agent` consegue reapontar um modelo que
administra:

```text
Point the researcher agent at the groq-fast model.
```

O agente chama `manage_agent` com `action: "set_model"`. O modelo de destino tem de
ser uma ligação já configurada, e a alteração passa pela barreira de permissão
como qualquer outra edição de configuração.

## Encaminhamento de modelo por complexidade

O `model` do próprio agente é tratado como a boa predefinição. Se quiseres, uma
verificação rápida e barata pode avaliar se uma conversa é simples o suficiente
para *descer* para um modelo mais económico, ainda antes de o turno a sério sequer
começar. Não é preciso configurar nenhum agente extra, bastam dois campos:

- `triage_model`: uma ligação de modelo que classifica a mensagem recebida com um
  prompt fixo já incorporado (não uma persona que tu escreves); o Pepe limita-se a
  procurar a palavra "SIMPLE" na resposta.
- `simple_model`: a ligação de modelo para a qual descer, e onde ficar pelo resto
  da sessão, assim que o veredito da triagem for de simplicidade.

```bash
pepe agent add assistant \
  --model modelo-forte-e-caro \
  --triage-model modelo-barato-e-rapido \
  --simple-model modelo-do-dia-a-dia \
  --prompt "..." \
  --tools bash,read_file,web_search
```

A triagem corre uma única vez, logo no primeiro turno de uma sessão, e nunca mais
volta a correr nessa mesma sessão; assim que uma conversa é considerada simples,
fica presa ao modelo mais barato pelo resto da conversa (o mesmo mecanismo que o
comando `/model` usa para trocar o modelo de uma sessão, só que aqui é acionado
sozinho, em vez de à mão). Um veredito de complexidade não muda absolutamente nada:
a sessão continua no próprio modelo do agente, exatamente como correria se não
houvesse nenhum `triage_model` definido.

A triagem é uma otimização de melhor esforço, nunca uma dependência. Se o modelo de
triagem não existir, estiver inacessível, ou simplesmente demorar demasiado tempo
(há um limite de poucos segundos), o turno segue em frente no próprio modelo do
agente, sem alarido; uma falha na triagem nunca chega a bloquear ou a quebrar uma
conversa. O `simple_model` também precisa de estar definido para a triagem sequer
correr, já que de outra forma não haveria para onde descer.

Cada veredito aparece como um passo próprio no Trace desse turno (o replay de cada
execução, no painel), ao lado de qualquer hook de privacidade que tenha corrido
sobre a mensagem, por isso consegues ver exatamente porque é que uma sessão acabou
num modelo e não no outro.

## O agente predefinido

Cada projeto pode ter um agente predefinido, que é o que corre quando não indicas
nenhum nome:

```bash
pepe run "resume este repositório"
```

O primeiro agente que crias no projeto default torna-se predefinido
automaticamente. Podes trocá-lo a qualquer momento:

```bash
pepe agent default assistant
```

## O agente proprietário

O primeiríssimo agente criado durante a configuração é o agente do próprio
proprietário, e já nasce com plenos poderes: recebe todas as ferramentas, é
superadministrador de todos os outros agentes (`can_manage` fica a `["*"]`) e todas
as suas chamadas de ferramenta vêm pré-aprovadas (`auto_approve` fica a `["*"]`),
por isso nunca para para perguntar nada. É isto que te deixa fazer trabalho a sério
por chat logo desde o primeiro minuto, incluindo criar e configurar todos os
agentes que vierem a seguir. Os agentes que juntares depois já nascem mais
limitados: és tu quem escolhe as suas ferramentas, só administram a si próprios e
as suas chamadas de risco passam pela barreira de permissão.

## Deixar os agentes falarem entre si

`can_message` é uma lista de sentido único. Se o agente A tiver o agente B nessa
lista, então A pode enviar-lhe uma mensagem através da ferramenta `send_to_agent`;
o inverso não fica implícito. Junta uma rota pela CLI:

```bash
pepe agent route triage assistant
```

A partir daqui, `triage` já pode passar trabalho a `assistant`. Para remover a
rota, usa `--remove`. As rotas nunca atravessam a fronteira de um projeto: a CLI
recusa `A -> B` sempre que os dois estejam em projetos diferentes.

### Fazer isto por chat

Um agente com a ferramenta `set_route` consegue mudar o encaminhamento por
conversa. O `from` assume por omissão o próprio agente que está a chamar:

```text
Allow yourself to message the billing agent.
```

O agente chama `set_route` com `action: "allow"` e `to: "billing"`. Como o
encaminhamento é de sentido único, isto não permite que `billing` responda de
volta. E como isto altera a configuração, o `set_route` passa pela barreira de
permissão e és tu quem autoriza a mudança.

## Administrar agentes

`can_manage` decide que agentes um agente pode administrar (criar, editar,
reconfigurar, treinar) através da ferramenta `manage_agent`. Vem fechado por
omissão, e o seu significado é bem preciso:

- Por definir (`null`): o agente só se pode administrar a si próprio.
- Vazio (`[]`, definido com `--can-manage none`): não pode administrar ninguém, nem
  sequer a si próprio. Um filho totalmente trancado, por exemplo um agente virado
  para o cliente que não se deve poder alterar.
- Uma lista de nomes: exatamente esses agentes, e mais nenhum. Se quiseres que se
  administre também a si próprio, tens de incluir o seu próprio nome na lista.
- `["*"]` (definido com `--can-manage "*"`): todos os agentes. Um superadministrador
  declarado como tal.

Concede autoridade de gestão diretamente:

```bash
pepe agent manage supervisor "*"
```

### Fazer isto por chat

Um agente administrador usa o `manage_agent` para moldar os agentes dentro do seu
âmbito. As suas ações são `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` e `remember` (que acrescenta um facto duradouro à memória
do alvo). Por exemplo:

```text
Dá ao agente de apoio a ferramenta send_file e regista na memória dele que
reembolsos acima de 200 precisam de uma pessoa.
```

O agente chama `manage_agent` com `action: "add_tool"` e depois com
`action: "remember"`. Todas estas ações passam por barreira: o agente propõe a
alteração, tu autorizas, e só depois disso é que ela é aplicada. Um agente também
consegue mudar o seu próprio nome com a ferramenta separada `rename_agent`
("De agora em diante, chama-te scout"), o que move o diretório do seu workspace e
entra em vigor logo na mensagem seguinte.

## Agentes multi-inquilino com projetos

Todo o agente vive dentro de um projeto. Numa instalação recente, esse é o único
**projeto default**, para o qual todos os comandos recorrem sempre que omites
`--project`, tal como sempre acontece numa instalação de um único inquilino.
Adiciona um segundo projeto para isolar um inquilino: os seus agentes, workspaces,
espaço partilhado, ligações de modelo e encaminhamento ficam separados de qualquer
outro projeto.

A verdadeira identidade de um agente é o seu identificador. No projeto default esse
identificador é só o nome simples (`assistant`); noutro projeto qualquer, fica
qualificado como `projeto/nome` (`acme/assistant`), o que permite reutilizar o
mesmo nome simples em vários projetos sem que haja colisão.

Cria um projeto e depois junta-lhe agentes com `--project`:

```bash
pepe project add acme --description "Acme Corp"

pepe agent add support \
  --project acme \
  --model openrouter \
  --prompt "És o agente de apoio da Acme." \
  --tools read_file,web_search
```

Junta `--project acme` a qualquer comando de agente para atuares dentro desse
âmbito. Nomes simples de pares em `--can-message` e `--can-manage` resolvem-se
sempre dentro do próprio projeto do agente, por isso as rotas nunca cruzam por
acidente a fronteira de um inquilino. Cada projeto pode fixar o seu próprio modelo
predefinido e o seu próprio agente predefinido, ou partilhar o fornecedor global do
operador. Um agente nunca é promovido a predefinição global só por ter sido o
primeiro a ser criado dentro de um projeto que não é o default.

Tanto os projetos como os agentes carregam um id interno estável, e é contra esse
id, não contra o nome, que fica registada cada ligação (encaminhamento, permissões,
predefinições, tarefas de cron, bots, tokens). Renomear um projeto ou um agente
muda-lhe só o rótulo e move-lhe o diretório; nada do que apontava para ele fica
pendurado no vazio.

## Gerir agentes pela CLI

```bash
# Cria um agente. Omite --tools para conceder todas; passa --tools "" para nenhuma.
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
  [--project PROJECT]

# Lista os agentes de um projeto, ou todos os agentes em qualquer lado.
pepe agent list [--project PROJECT | --all]

# Imprime o prompt de sistema totalmente montado, não só o campo de persona: tudo
# o que o Pepe constrói à volta dele. Ver "A ver exatamente o que o modelo vê" abaixo.
pepe agent prompt NAME [--project PROJECT]

# Encaminhamento dirigido: deixa FROM enviar mensagens a TO.
pepe agent route FROM TO [--remove] [--project PROJECT]

# Autoridade de gestão: deixa ADMIN administrar TARGET (ou "*" para todos).
pepe agent manage ADMIN TARGET [--remove] [--project PROJECT]

# Renomeia um agente e move o diretório do seu workspace.
pepe agent rename OLD NEW

# Apaga um agente.
pepe agent remove NAME [--project PROJECT]

# Define o agente predefinido de um projeto.
pepe agent default NAME [--project PROJECT]
```

## Correr um agente

O mesmo agente é acessível de quatro formas diferentes.

**De uma só vez, pela CLI.** Sem sessão, transmitido diretamente para o stdout.

```bash
pepe run assistant "your prompt here"
```

**Consola interativa.** Mantém a conversa, por isso o contexto passa de um turno
para o seguinte. Retoma ou separa sessões de consola com `--session KEY`.

```bash
pepe chat assistant
```

**Por HTTP e WebSocket.** Arranca o servidor e depois chama a API compatível com a
OpenAI, ou abre um WebSocket de transmissão. É o campo `model` do pedido que indica
o agente.

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

O WebSocket fica disponível em `ws://localhost:4000/socket/websocket`, e a
verificação de saúde em `GET /health`.

**Através de um canal de mensagens.** Basta ligar um agente a uma ligação de
Telegram, WhatsApp, Slack, Discord, Microsoft Teams ou Google Chat, ou a um webhook
de entrada genérico, e ele passa a responder ali com o mesmo ciclo e as mesmas
ferramentas.

## Gerir uma persona a partir do Langfuse

Define `langfuse_prompt` com o nome de um prompt e a persona deste agente passa a
vir do [Langfuse](../langfuse/) em vez do próprio `system_prompt`/`SOUL.md`: edita
o prompt no Langfuse e a alteração chega ao Pepe dentro de poucos minutos, sem
redeploy nenhum e sem sequer tocar no `config.json`.

```bash
pepe agent add support --langfuse-prompt support-persona
```

É opt-in, agente a agente: um que não tenha `langfuse_prompt` definido fica
completamente por afetar, e se a obtenção falhar (endereço inacessível, nome que
não resolve), cai de imediato de volta para a persona local. Para a configuração e
as credenciais, ver [Langfuse](../langfuse/).

## A ver exatamente o que o modelo vê

O campo `system_prompt` é só a semente. O que realmente chega ao modelo como
mensagem de sistema inclui também os ficheiros de persona, identidade e arranque do
agente, quando existem, um contrato de comportamento curto, a hora atual e um
índice dos documentos e skills que ele conhece, nada disto visível se te limitares
a ler o campo tal como está em disco. Para veres a coisa toda montada, exatamente
como uma conversa a sério a enviaria:

```bash
pepe agent prompt NAME
```

A página de edição de agente do painel tem a mesma vista, dentro de **Prompt
montado**, recolhida por omissão porque pode ficar bastante longa.
