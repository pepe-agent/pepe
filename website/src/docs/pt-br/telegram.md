---
title: Telegram
description: Crie e gerencie bots do Telegram conectados a agentes do Pepe.
---

## Telegram

O Telegram é o canal mais rápido de colocar de pé porque não precisa de nenhuma
URL pública. Crie um bot com o @BotFather, copie o token dele e registre. O Pepe
consulta o Telegram por polling em busca de mensagens novas, então não há webhook
nenhum para expor.

Configure o bot padrão de forma interativa:

```bash
pepe gateway telegram setup
```

Isso pede o token (você pode colar um token literal ou uma referência
`${ENV_VAR}`), um agente opcional para vincular e uma lista opcional de ids de
chat autorizados a falar com ele.

Você pode rodar mais de um bot, cada um vinculado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual agente responde. Omita para usar seu agente padrão.
- `--trainers`: de quem esse bot pode aprender para a memória, e quem pode rodar
  os comandos de operador dele. Omita para todos, `none` para ninguém, ou uma
  lista separada por vírgulas de ids de usuário para apenas esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de
  despertar (para agentes que verificam coisas em um horário). As horas são uma
  janela local como `8-22`. Veja "Heartbeat" mais abaixo.
- `--progress`: como o bot sinaliza que está trabalhando enquanto uma execução
  está em andamento. Uma entre `reaction`, `ambient`, `off` ou `verbose`. Veja
  "Mostrando que está trabalhando" mais abaixo.

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Rode o poller em primeiro plano (um poller por bot):

```bash
pepe gateway telegram
```

Cada bot ganha o próprio poller, o próprio token, o próprio agente vinculado, as
próprias listas de permissão e o próprio espaço de nomes de sessão. Dois bots que
resolvem para o mesmo token são deduplicados, porque dois pollers em um token só
conflitariam entre si.

Normalmente você não precisa rodar isso separadamente. O `pepe serve` inicia os
bots do Telegram configurados junto com a API HTTP, então um único servidor em
execução cobre todos os canais de uma vez.

Dentro de um único bot você ainda pode trocar o agente por chat com
`/agent <nome>` (veja [Roteamento](../routing/)). Um bot dedicado é para quando um
canal inteiro deve *ser* um agente.

<div class="note"><strong>Painel.</strong> A seção Channels do painel lista seus
bots com um selo ao vivo de ativo/inativo, deixa você adicionar um bot, editar
com qual agente ele fala e removê-lo. Ela grava a mesma configuração que a linha
de comando, e os pollers em execução se reconciliam sem reinício.</div>

### Onde a configuração vive

O bot padrão vive sob `"telegram"` no `~/.pepe/config.json`. Os bots nomeados
extras vivem sob `"telegrams"`, um mapa de nome para configuração, e cada um deles
aceita as mesmas chaves do bot padrão:

- `bot_token`: o token, literal ou `${ENV_VAR}`.
- `enabled`: se o poller desse bot inicia.
- `agent`: qual agente responde.
- `allowed_chats` e `allowed_users`: as listas de ids permitidos. Deixe de fora e
  o bot fala com qualquer um.
- `require_mention`: em um grupo, só responder quando o bot for @mencionado.
- `trainers`: de quem o bot aprende, e quem pode rodar os comandos de operador
  dele.

O `/whoami` num chat é o jeito fácil de descobrir os ids para essas listas. Ele
imprime o seu id de usuário e o id do chat.

As sessões têm espaço de nomes por bot. O bot padrão indexa as conversas dele como
`telegram:<chat_id>`, enquanto um bot nomeado usa `telegram:<name>:<chat_id>`. Dois
bots, portanto, nunca colidem, nem nas conversas nem na entrega de tarefas
agendadas.

### Comandos de barra

Todo chat é uma sessão persistente, conduzida por comandos de barra. Eles também
aparecem no menu "/" do Telegram, no idioma que você configurou.

| Comando | O que faz |
|---|---|
| `/new` | Começa uma conversa nova |
| `/undo` | Desfaz sua última mensagem |
| `/retry` | Refaz a última resposta |
| `/compact` | Resume o histórico para liberar contexto |
| `/stop` | Para a execução atual |
| `/inline <texto>` | Injeta uma mensagem na execução que já está rodando |
| `/btw <pergunta>` | Faz uma pergunta paralela que não fica salva na conversa |
| `/mention on\|off` | Em um grupo, exigir ou não uma @menção |
| `/model [nome] [session\|global]` | Mostra o modelo atual, ou define ele |
| `/learn` | Salva o que o agente aprendeu na memória e nas skills |
| `/whoami` | Mostra seus ids de usuário e de chat do Telegram |
| `/help` | Lista os comandos que você pode rodar |

E os comandos de operador, que só os treinadores do bot podem rodar:

| Comando | O que faz |
|---|---|
| `/agent <nome>` | Troca o agente que responde nesse chat |
| `/status` | Mostra informações da sessão |
| `/models` | Escolhe um modelo numa lista de botões |
| `/tools` | Lista as ferramentas de runtime disponíveis |
| `/skill [nome]` | Lista as skills, ou roda uma pelo nome |
| `/approve` | Gerencia as permissões de ferramenta salvas |
| `/usage` | Mostra o gasto e a contagem de mensagens do mês |

As skills instaladas também viram comandos de barra próprios, então uma skill
chamada `weather` responde a `/weather` além de `/skill weather`, e fica
descobrível pelo menu "/". Um comando de skill conta como comando de operador,
porque uma skill roda instruções arbitrárias através do agente.

#### Os comandos de operador são só para treinadores

Os comandos da segunda tabela expõem a superfície de operador: sua configuração,
suas permissões, seu gasto e o inventário interno de modelos, ferramentas e
skills. Eles são restritos à lista `trainers` do bot, e a trava fica no ponto
único onde todo comando é despachado, então um comando que pode ser alcançado por
dois nomes não consegue passar por fora dela.

- Um bot **sem lista `trainers`** confia em todo mundo com quem fala. Esse é o bot
  pessoal, e para ele nada muda: você tem todos os comandos, skills incluídas.
- Um bot **com lista `trainers`** é voltado ao cliente. Um cliente falando com ele
  não consegue alcançar `/approve`, `/agent`, `/status`, `/models`, `/tools`,
  `/skill` nem `/usage`, nem nenhum comando de skill. Eles também não são
  anunciados para esse cliente: o `/help` lista só os comandos que quem chamou
  pode de fato rodar, e o menu "/" do bot é montado para a pessoa menos confiável
  que consegue vê-lo, então os comandos de operador ficam de fora do popup por
  completo. Quem não é treinador e digita um mesmo assim ouve que o comando não
  está disponível ali, e nunca vê as entranhas de operador.

O `/model` é, de propósito, metade de cada. Lê-lo (`/model` sem argumentos) revela
qual modelo está por trás do bot, o que é infraestrutura, então esse caminho é só
para treinadores. Trocar não é: um cliente pode escolher um modelo para a própria
conversa, a não ser que você tranque isso. Veja "Troque de modelo no meio de uma
conversa" abaixo.

### Em grupos

Num chat 1:1 o bot sempre responde. Adicionado a um grupo, por padrão só
responde quando é @mencionado ou recebe um `/comando`, porque senão responderia
a toda mensagem num grupo movimentado. Desligue essa exigência por completo para
o bot (em todo grupo em que ele estiver) com `require_mention: false` durante o
`pepe gateway telegram setup`.

Para um único grupo, sem mexer na configuração do bot inteiro, rode:

```text
/mention off   # só nesse grupo, até o /new: não precisa @mencionar para ele responder
/mention on    # volta a exigir @menção
/mention       # mostra a configuração atual
```

A dispensa vive na conversa daquele grupo, não no bot, então nunca vaza para
nenhum outro grupo em que o mesmo bot esteja, e uma conversa nova (`/new`)
esquece ela.

Uma conversa de grupo é uma única sessão compartilhada entre todo mundo que
está nela, sem marcar quem disse o quê. Se seu agente precisa diferenciar as
pessoas, avise isso no prompt dele. O bot também é cego para o que não é
endereçado a ele: uma mensagem que não o @menciona (e não está dispensada
via `/mention off`) nunca chega ao agente, nem como contexto silencioso,
então ele não consegue "se atualizar" sobre o que rolou antes dele entrar na
conversa.

### Troque de modelo no meio de uma conversa

`/model` mostra o modelo ativo nesse chat, com um botão **Browse models**
para escolher outro; `/models` vai direto para esse seletor. O seletor é escopado
ao seu projeto e põe um tique no modelo em uso, então você toca em um para trocar.
Essas duas leituras são só para treinadores, já que revelam quais modelos estão
por trás do bot. Uso digitado:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem esse bot fala
```

Qualquer pessoa em uma conversa permitida pode trocar sua própria sessão;
trocar **globalmente** (para todas as conversas que esse bot atende) é
reservado para **treinadores**, a mesma lista que controla o `/learn` e a
memória, então um membro qualquer do chat não consegue reapontar o bot
inteiro para outro modelo em silêncio. É o treinador quem é perguntado qual das
duas opções ele quis dizer; qualquer outra pessoa simplesmente troca a própria
conversa, sem nada a responder. Defina `model_switch_locked: true` no bot para
desativar totalmente a troca de modelo por quem não é treinador. Uma troca de
sessão vive só na memória; ela reseta com `/new` ou com um reinício do servidor,
voltando ao que a configuração do próprio agente diz.

### Mostrando que está trabalhando

Enquanto uma execução está em andamento, o bot mostra que está ocupado. Isso é de
propósito um sinal ambiente, e não um relatório de status que você deva ler. O
indicador nativo de "digitando..." do Telegram continua vivo em todos os modos.
Além dele, o `tool_progress` (a opção `--progress`) escolhe um entre quatro:

- `reaction`, o padrão: uma reação 👀 na sua própria mensagem enquanto o agente
  trabalha, removida quando a resposta chega. Não acrescenta nenhuma mensagem ao
  chat, e é o mais silencioso dos quatro.
- `ambient`: uma única linha vaga ("procurando as coisas...", "rodando algo...")
  editada no lugar e apagada quando a resposta chega. Sem nomes de ferramenta, sem
  argumentos, sem registro.
- `off`: nada além do indicador nativo de digitação.
- `verbose`: o registro completo, para quem quer acompanhar a execução. Cada
  chamada de ferramenta assim que acontece e, acima dela, a frase que o modelo
  disse antes de recorrer àquela ferramenta. O registro conta *o que* ele fez; a
  frase conta *por quê*, que é o que permite ver o agente indo para o lugar
  errado antes de ele chegar lá. Continua sendo uma mensagem só, editada no
  lugar, apagada quando a resposta chega.

Defina pela linha de comando com `--progress`, ou de dentro de uma conversa com a
ferramenta `manage_channel` (`set_progress`).

### Heartbeat: check-ins proativos

Um bot pode periodicamente dar a palavra ao agente dele para dizer alguma coisa
**por iniciativa própria** ("o deploy terminou", "você me pediu para ficar de olho
em X") e, igualmente importante, o direito de **não dizer nada** na maior parte do
tempo. Vem desligado, e você escolhe ligar por bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Um agente que tem a ferramenta `manage_channel` também consegue configurar isso
sozinho, de dentro de uma conversa:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Cada pulso roda o agente sobre o contexto vivo da sessão dele, com um prompt que
diz que essa é uma verificação automática e que ele deve responder exatamente
`HEARTBEAT_OK` se não houver nada que valha a pena dizer. Esse é o caso comum, e
só uma mensagem de verdade chega a ser enviada ao chat. Você o alimenta com duas
coisas:

- Um `HEARTBEAT.md` opcional no workspace do agente, que é onde você escreve o que
  deve ser observado.
- **Eventos de sistema**, que qualquer parte do Pepe pode enfileirar para uma
  sessão (`Pepe.Heartbeat.Events.push/2`), e que o pulso seguinte recolhe sozinho.

Um laço proativo descontrolado é impossível por construção. Uma trava de
resfriamento impõe um mínimo de 30 segundos entre pulsos, e um disjuntor de
enxurrada dispara com 5 acionamentos em 60 segundos. O `heartbeat_hours` (uma
janela local como `8-22`) mantém o bot quieto fora do horário em que você está
acordado.

### Chats mortos se curam sozinhos

Se um envio volta com falha permanente, porque o bot foi bloqueado ou porque o
chat ou o usuário sumiu, aquele chat passa a ser pulado em todo envio seguinte.
Não há chamadas de API desperdiçadas nem barulho no log. No momento em que um
envio para ele volta a dar certo, por exemplo porque a pessoa desbloqueou o bot, a
marca é retirada automaticamente. Não há nada para reiniciar na mão.

### Idioma e erros

As mensagens fixas do próprio Pepe (respostas de comando, botões, recusas) seguem
o `locale` que você configurou. As respostas do agente seguem o idioma em que a
pessoa escreve, qualquer que seja. Erros internos crus nunca vazam para o chat.

### Faça pela conversa

Um agente que tem a ferramenta `manage_channel` pode criar e revincular bots do
Telegram a partir de uma conversa. Como ela edita a configuração, cada chamada
passa pela barreira de permissão: o agente propõe a mudança e você confirma
antes de ela ser aplicada.

Você diria:

> Adicione um bot do Telegram chamado sales que fale com o agente de vendas. O
> token está na variável de ambiente SALES_BOT_TOKEN.

O agente chama `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Duas proteções importam aqui:

- **Segredos nunca passam pela conversa.** Você informa o *nome* de uma variável de
  ambiente que guarda o token, nunca o token em si. Ele é armazenado como
  `${SALES_BOT_TOKEN}` e resolvido na hora da leitura, então o segredo cru nunca
  chega ao modelo nem aos registros. Um token cru (que contém dois pontos) é
  rejeitado. Você mesmo define essa variável de ambiente.
- **O bot padrão protegido é intocável.** A ferramenta só mexe em bots com nome,
  nunca no `default`, e não toca em mais nada da sua configuração.

Outras ações do `manage_channel` são `list`, `set_agent` (revincular um bot a
outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` e `remove`. Depois de qualquer mudança ela reconcilia os pollers em
execução, então um bot inicia ou para ao vivo, sem reinício.

<div class="note"><strong>Só Telegram.</strong> A ferramenta de chat gerencia
bots do Telegram. As conexões por webhook (WhatsApp, Slack e as demais) são
criadas pela linha de comando, pelo painel ou pelo <code>pepe setup</code>, não
pela conversa.</div>
