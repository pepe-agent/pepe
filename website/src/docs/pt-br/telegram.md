---
title: Telegram
description: Crie bots do Telegram e conecte-os aos agentes do Pepe.
---

## Telegram

Nenhum canal é mais rápido de colocar no ar que o Telegram: não existe URL
pública para configurar. Basta criar um bot com o @BotFather, copiar o token
dele e registrar no Pepe. É o próprio Pepe quem vai até o Telegram buscar as
mensagens novas, então não é preciso expor nada da sua máquina para a
internet.

Configure o bot padrão de forma interativa:

```bash
pepe gateway telegram setup
```

O comando pede o token (aceita um token literal ou uma referência
`${ENV_VAR}`), pergunta se você quer vincular um agente e deixa você
restringir, opcionalmente, quais ids de chat podem falar com o bot.

Dá para manter vários bots ao mesmo tempo, cada um preso a um agente
diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou via `${ENV_VAR}`.
- `--agent`: define quem responde. Sem essa flag, vale o agente padrão.
- `--trainers`: quem pode alimentar a memória do bot e rodar os comandos de
  operador dele. Deixe em branco para liberar geral, use `none` para travar
  tudo, ou passe uma lista de ids separada por vírgula para liberar só essas
  pessoas.
- `--heartbeat-minutes` e `--heartbeat-hours`: configuram uma janela periódica
  de despertar, útil para agentes que precisam checar algo em horários fixos.
  As horas seguem um formato de janela local, tipo `8-22`. Detalhes na seção
  "Heartbeat" mais adiante.
- `--progress`: escolhe como o bot avisa que está trabalhando enquanto uma
  execução está rolando: `reaction`, `ambient`, `off` ou `verbose`. Veja
  "Mostrando que o agente está trabalhando" mais abaixo.

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Rodar o poller em primeiro plano (um poller por bot):

```bash
pepe gateway telegram
```

Cada bot tem seu próprio poller, seu próprio token, seu agente vinculado,
suas listas de permissão e seu próprio espaço de sessões. Dois bots
configurados com o mesmo token são deduplicados automaticamente, já que dois
pollers disputando um único token entrariam em conflito.

Na prática você raramente precisa rodar isso à parte: o `pepe serve` já sobe
os bots do Telegram configurados junto com a API HTTP, então um único
servidor cobre todos os canais de uma vez.

Mesmo dentro de um único bot, ainda dá para trocar o agente por chat com
`/agent <nome>` (veja [Roteamento](../routing/)). Um bot dedicado serve para
quando você quer que um canal inteiro *seja* um agente só.

<div class="note"><strong>Painel.</strong> A seção Channels do painel mostra
seus bots com um selo ativo/inativo em tempo real, deixa você adicionar um
bot novo, trocar o agente vinculado e remover qualquer um deles. As mudanças
feitas ali gravam a mesma configuração que a linha de comando usa, e os
pollers em execução se ajustam sozinhos, sem reiniciar nada.</div>

### Onde a configuração fica

O bot padrão mora na chave `"telegram"` do `~/.pepe/config.json`. Bots
extras, com nome próprio, ficam em `"telegrams"`, um mapa de nome para
configuração, e aceitam as mesmas chaves do bot padrão:

- `bot_token`: token literal ou via `${ENV_VAR}`.
- `enabled`: controla se o poller desse bot sobe.
- `agent`: define quem responde.
- `allowed_chats` e `allowed_users`: listas de ids liberados. Sem elas, o bot
  atende qualquer pessoa.
- `require_mention`: em grupo, só responde quando @mencionado.
- `reactions`: define quais 👍/👎 numa mensagem viram feedback para o agente:
  `own` (padrão, só reações nas mensagens do próprio bot), `all` ou `off`. O
  agente já sabe o que fazer com isso sem precisar de instrução: no 👍 grava
  na memória o que deu certo, no 👎 grava o que evitar repetir, e nunca
  responde à reação em si. Essa gravação passa pela mesma revisão de qualquer
  outra memória, na tela Learning do painel, antes de valer de fato.
- `quick_reactions`: desligado por padrão. Ligado, uma mensagem que é só um
  agradecimento ou um emoji solto (um "valeu!", um ❤️ isolado) recebe de
  volta uma reação nativa em vez de uma resposta escrita, sem gastar uma
  chamada de modelo com isso. Se a mensagem tiver conteúdo de verdade, a
  resposta continua normal.
- `trainers`: de quem o bot aprende e quem pode rodar os comandos de
  operador.

Para descobrir os ids dessas listas, o jeito mais fácil é digitar `/whoami`
num chat: ele devolve o seu id de usuário e o id daquele chat.

As sessões são isoladas por bot. O bot padrão guarda as conversas sob a
chave `telegram:<chat_id>`; um bot com nome usa `telegram:<name>:<chat_id>`.
Assim, dois bots nunca se misturam, nem nas conversas nem na entrega de
tarefas agendadas.

### Comandos de barra

Toda conversa é uma sessão persistente, controlada por comandos de barra, que
também aparecem no menu "/" do Telegram, já no idioma configurado.

| Comando | O que faz |
|---|---|
| `/new` | Começa uma conversa nova |
| `/undo` | Desfaz sua última mensagem |
| `/rewind N` | Volta N trocas atrás e segue a conversa dali |
| `/retry` | Refaz a última resposta |
| `/compact` | Resume o histórico para liberar contexto |
| `/stop` | Para a execução atual |
| `/inline <texto>` | Injeta uma mensagem na execução que já está rodando |
| `/btw <pergunta>` | Faz uma pergunta paralela que não fica salva na conversa |
| `/mention on\|off` | Em um grupo, exigir ou não uma @menção |
| `/model [nome] [session\|global]` | Mostra o modelo atual, ou define outro |
| `/learn` | Salva o que o agente aprendeu na memória e nas skills |
| `/whoami` | Mostra seus ids de usuário e de chat do Telegram |
| `/help` | Lista os comandos que você pode rodar |

#### Voltando algumas trocas atrás

Quando o agente pega um caminho errado e as três respostas seguintes já vêm em
cima dele, `/rewind 3` tira essas três trocas da conversa e retoma de antes
delas. Nada mais muda: mesmo chat, mesmo agente, tudo que ele já sabia de antes
continua lá. A contagem é de trocas, do jeito que você enxerga na própria tela,
então não existe número de mensagem para procurar em lugar nenhum.

Se você pedir mais do que a conversa tem, ele volta tudo que dá e diz quantas
trocas foram, em vez de recusar e deixar você chutar um número menor. O que sai
não volta, então, quando a ideia for testar outro caminho sem perder o atual,
ramifique a conversa (o `/fork` do painel).

Se o histórico já tiver sido resumido para economizar contexto, o resumo fica.
Ele cobre trocas que foram condensadas muito antes, que nenhum rewind traz de
volta, e nunca fala do que o rewind acabou de tirar.

E os comandos de operador, liberados só para os treinadores do bot:

| Comando | O que faz |
|---|---|
| `/agent <nome>` | Troca o agente que responde nesse chat |
| `/status` | Mostra informações da sessão |
| `/models` | Escolhe um modelo numa lista de botões |
| `/tools` | Lista as ferramentas de runtime disponíveis |
| `/skill [nome]` | Lista as skills, ou roda uma pelo nome |
| `/approve` | Gerencia as permissões de ferramenta salvas |
| `/usage` | Mostra o gasto e a contagem de mensagens do mês |

Skills instaladas ganham comando de barra próprio: uma skill chamada
`weather` responde tanto a `/weather` quanto a `/skill weather`, e aparece no
menu "/". Um comando de skill conta como comando de operador, porque uma
skill roda instruções livres através do agente.

#### Comandos de operador são exclusivos dos treinadores

A segunda tabela expõe a superfície de operador: configuração, permissões,
gastos e o inventário interno de modelos, ferramentas e skills. Tudo isso
fica restrito à lista `trainers` do bot, e a trava está no único ponto por
onde todo comando passa antes de ser executado, então não existe um segundo
caminho por onde um comando escaparia dela.

- Um bot **sem lista `trainers`** confia em qualquer pessoa que fale com ele.
  É o caso do bot pessoal, onde nada muda: todos os comandos ficam
  disponíveis, skills inclusive.
- Um bot **com lista `trainers`** é voltado para clientes. Quem fala com ele
  sem estar na lista não alcança `/approve`, `/agent`, `/status`, `/models`,
  `/tools`, `/skill` nem `/usage`, nem comando de skill nenhum. Esses
  comandos também não aparecem para esse tipo de usuário: o `/help` só lista
  o que a pessoa pode de fato rodar, e o menu "/" do bot é montado pensando
  na pessoa menos confiável que pode vê-lo, então os comandos de operador
  simplesmente ficam fora do popup. Quem não é treinador e ainda assim digita
  um desses comandos recebe um aviso de que ele não está disponível ali, sem
  nunca ver o funcionamento interno do bot.

O `/model` fica de propósito no meio do caminho. Consultá-lo sem argumentos
revela qual modelo está por trás do bot, e isso é informação de
infraestrutura, então essa leitura é só para treinadores. Já trocar de
modelo é outra história: qualquer cliente pode escolher um modelo para a
própria conversa, a menos que você bloqueie essa opção. Veja "Troque de
modelo no meio da conversa" mais abaixo.

### Em grupos

Num chat individual o bot sempre responde. Já num grupo, por padrão, só
responde quando é @mencionado ou recebe um `/comando`; do contrário,
responderia a cada mensagem de um grupo movimentado. Para desligar essa
exigência por completo, em todos os grupos onde o bot estiver, use
`require_mention: false` durante o `pepe gateway telegram setup`.

Se você quiser mudar isso só num grupo específico, sem tocar na configuração
geral do bot, rode:

```text
/mention off   # só nesse grupo, até o /new - não precisa @mencionar para ele responder
/mention on    # volta a exigir @menção
/mention       # mostra a configuração atual
```

Essa dispensa fica gravada na conversa daquele grupo, não no bot, então não
vaza para nenhum outro grupo onde o bot também esteja, e some assim que a
conversa é reiniciada com `/new`.

Uma conversa em grupo é uma sessão única, compartilhada por todo mundo que
está nela. Cada mensagem chega marcada com o nome de quem escreveu (algo
como `Alice: qual é o status?`), para o modelo sempre saber a quem está
respondendo a cada turno, em vez de supor que a última pessoa a escrever é a
mesma de um assunto anterior. Numa conversa privada essa marcação não
existe, porque não haveria ninguém mais para confundir. O bot também não
enxerga nada que não seja endereçado a ele: uma mensagem sem @menção (e sem
a dispensa do `/mention off`) nunca chega ao agente, nem como contexto de
fundo, então ele não tem como "se atualizar" sobre uma conversa que rolou
antes de ser chamado.

### Tópicos de fórum

Num grupo com **tópicos** ativados, cada tópico vira sua própria conversa, e
a resposta volta para o tópico de onde partiu. Dá para atribuir a um tópico
**seu próprio agente**: rode `/agent <nome>` dentro dele (ou simplesmente
**peça** ao agente para ligar aquele tópico a outro agente, que ele faz isso
sozinho) e o vínculo permanece mesmo depois de um `/new` ou de um reinício.
A busca pelo nome ignora maiúsculas e minúsculas, então `/agent engenheiro`
encontra um agente cadastrado como `Engenheiro`. Assim, um mesmo grupo pode
ter um tópico de "suporte" respondido pelo agente de suporte e um de
"engenharia" respondido pelo engenheiro, cada um seguindo seu próprio
caminho. O agente que responde a uma mensagem é, nessa ordem: o vinculado ao
tópico, se houver; senão o `agent` configurado no bot; senão o padrão
global. Um tópico vinculado continua seguindo a regra de menção do grupo,
então use `require_mention: false` (ou `/mention off` dentro do tópico) se
quiser que ele responda sem precisar de @menção.

### Troque de modelo no meio da conversa

`/model` mostra o modelo em uso naquele chat e oferece um botão **Browse
models** para trocar; `/models` pula direto para esse seletor. A lista
mostrada é a do seu projeto, com uma marca no modelo ativo, então basta
tocar em outro para trocar. As duas leituras são exclusivas de treinador, já
que revelam quais modelos ficam por trás do bot. Digitando direto:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem esse bot fala
```

Qualquer pessoa numa conversa liberada pode trocar o modelo da própria
sessão; já a troca **global** (valendo para toda conversa que aquele bot
atende) fica reservada aos **treinadores**, a mesma lista que controla
`/learn` e a memória, para que ninguém no chat consiga reapontar o bot
inteiro para outro modelo sem que ninguém perceba. Só ao treinador é
perguntado qual das duas opções ele quis dizer; qualquer outra pessoa já
troca direto a própria conversa, sem pergunta nenhuma. Para desligar de vez
a troca de modelo por quem não é treinador, defina `model_switch_locked:
true` no bot. Uma troca feita numa sessão vive só em memória: ela é
descartada com `/new` ou com o reinício do servidor, voltando ao que a
configuração do agente já determinava.

### Mostrando que o agente está trabalhando

Enquanto uma execução roda, o bot sinaliza que está ocupado, só que de
propósito de um jeito discreto, não como um relatório para você acompanhar
de perto. O indicador nativo de "digitando..." do Telegram fica ativo em
qualquer modo escolhido. Além dele, o `tool_progress` (a flag `--progress`)
oferece quatro opções:

- `reaction`, o padrão: uma reação 👀 na sua própria mensagem enquanto o
  agente trabalha, removida assim que a resposta sai. Não gera mensagem nova
  no chat, e é o mais discreto dos quatro.
- `ambient`: uma única linha vaga, tipo "procurando informação..." ou
  "rodando algo...", editada no próprio lugar e apagada quando a resposta
  chega. Sem nome de ferramenta, sem argumento, sem histórico.
- `off`: nada além do indicador nativo de digitação.
- `verbose`: o histórico completo, para quem quer acompanhar a execução de
  perto. Cada chamada de ferramenta aparece assim que acontece, precedida da
  frase que o modelo disse antes de recorrer a ela. O histórico mostra *o
  que* foi feito; a frase explica *por quê*, e é isso que permite perceber
  que o agente está indo pelo caminho errado antes mesmo de chegar lá. Ainda
  assim, tudo isso continua sendo uma única mensagem, editada no lugar e
  apagada quando a resposta sai.

Dá para configurar de três formas: pela linha de comando com `--progress`;
de dentro de uma conversa, com a ferramenta `manage_channel`
(`set_progress`); ou pelo **painel**, em Canais → seu bot → *Editar* →
"Enquanto o agente trabalha", onde cada modo vem explicado.

### Heartbeat: check-ins por iniciativa própria

De tempos em tempos, um bot pode dar a palavra ao próprio agente para ele
falar algo **por conta própria** ("o deploy terminou", "você me pediu para
acompanhar X"), e, tão importante quanto isso, para ele **não dizer nada**
na maioria das vezes. Isso vem desligado por padrão, e você liga bot por
bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Um agente com a ferramenta `manage_channel` também consegue configurar isso
sozinho, direto de uma conversa:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Cada pulso roda o agente sobre o contexto vivo daquela sessão, com um prompt
avisando que aquilo é uma checagem automática e pedindo para responder
exatamente `HEARTBEAT_OK` quando não houver nada relevante a dizer. Esse é o
caso mais comum, e só uma mensagem de verdade chega a ser enviada ao chat.
Você alimenta esse mecanismo de duas formas:

- Com um `HEARTBEAT.md` opcional no workspace do agente, onde você anota o
  que ele deve ficar de olho.
- Com **eventos de sistema**, que qualquer parte do Pepe pode enfileirar
  para uma sessão (`Pepe.Heartbeat.Events.push/2`), e que o próximo pulso já
  recolhe sozinho.

Por construção, não tem como esse mecanismo virar um laço proativo fora de
controle: uma trava de resfriamento impõe pelo menos 30 segundos entre
pulsos, e um disjuntor entra em ação se houver 5 disparos em 60 segundos. O
`heartbeat_hours` (uma janela local como `8-22`) mantém o bot calado fora do
horário que você definiu.

### Chats mortos se recuperam sozinhos

Quando um envio falha de forma permanente, seja porque bloquearam o bot ou
porque o chat ou o usuário deixou de existir, aquele chat passa a ser
ignorado em todo envio seguinte. Não sobra chamada de API desperdiçada nem
barulho no log. No instante em que um envio para ele volta a funcionar, por
exemplo porque a pessoa desbloqueou o bot, a marca é removida sozinha. Não
existe nada para você resetar manualmente.

### Uma resposta sobrevive a um reinício no meio do envio

Se o Pepe reiniciar (um deploy, uma queda) bem no momento em que estava
enviando a resposta de um turno, essa resposta não se perde: ela chega
assim que o bot volta a funcionar, antes mesmo de ele tratar qualquer coisa
nova. Quando o reinício pega o envio genuinamente no meio do caminho, sem
certeza se a mensagem já saiu ou não, a cópia reenviada vem marcada com o
prefixo "♻️ Recovered reply", deixando claro que aquilo pode ser uma
duplicata em vez de simplesmente repetir a mensagem sem aviso. Já uma
resposta que nunca chegou a sair vai limpa, sem prefixo nenhum. Isso não
pede nenhuma configuração e não deixa nada para você resetar na mão.

### Idioma e erros

As mensagens fixas do próprio Pepe (respostas de comando, botões, recusas)
seguem o `locale` configurado. Já as respostas do agente acompanham o
idioma que a pessoa está usando para escrever, seja ele qual for. Erros
internos nunca aparecem crus no chat.

### Fazendo tudo pela conversa

Um agente com a ferramenta `manage_channel` consegue criar e revincular
bots do Telegram direto de uma conversa. Como isso mexe na configuração,
toda chamada passa pela barreira de permissão: o agente propõe a mudança, e
você confirma antes dela valer.

Você diria algo como:

> Cria um bot do Telegram chamado sales que conversa com o agente de vendas.
> O token está na variável de ambiente SALES_BOT_TOKEN.

O agente chama `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Duas proteções entram em
jogo aqui:

- **Segredo nenhum passa pela conversa.** Você só informa o *nome* da
  variável de ambiente que guarda o token, nunca o token em si. Ele fica
  salvo como `${SALES_BOT_TOKEN}` e é resolvido só na hora da leitura, então
  o valor cru jamais chega ao modelo nem aparece nos registros. Um token
  colado direto (que contém dois-pontos) é recusado; a variável de ambiente
  é algo que só você configura.
- **O bot padrão fica fora de alcance.** A ferramenta só mexe em bots
  nomeados, nunca no `default`, e não toca em mais nada da sua configuração.

As outras ações de `manage_channel` são `list`, `set_agent` (revincular um
bot a outro agente), `set_trainers`, `set_heartbeat`, `set_progress`,
`enable`, `disable` e `remove`. Depois de qualquer mudança, os pollers em
execução se ajustam sozinhos, então um bot liga ou desliga ao vivo, sem
precisar de reinício.

<div class="note"><strong>Só para o Telegram.</strong> Essa ferramenta de
conversa gerencia especificamente bots do Telegram. Conexões via webhook
(WhatsApp, Slack e as demais) são criadas pela linha de comando, pelo painel
ou pelo <code>pepe setup</code>, nunca por conversa.</div>
