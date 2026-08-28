---
title: Telegram
description: Cria e gere bots do Telegram ligados a agentes do Pepe.
---

## Telegram

Nenhum outro canal é tão rápido a pôr a funcionar como o Telegram, porque não exige URL público nenhum. Basta criar um bot com o @BotFather, copiar o token e registá-lo: é o Pepe que vai buscar as mensagens novas ao Telegram, por isso não há nada na tua máquina que precise de ficar exposto à internet.

Para configurar o bot predefinido de forma interativa:

```bash
pepe gateway telegram setup
```

Isto pede-te o token (um literal ou uma referência `${ENV_VAR}`), opcionalmente um agente para lhe associar, e opcionalmente uma lista de ids de conversa autorizados a falar com ele.

Nada te impede de correr mais do que um bot, cada um ligado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual o agente que responde; omite para usar o teu predefinido.
- `--trainers`: de quem este bot pode aprender para a memória, e quem pode executar os seus comandos de operador. Omite para todos, usa `none` para ninguém, ou passa uma lista de ids separados por vírgulas para restringir a esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de ativação, para agentes que precisam de verificar algo a horas certas (as horas seguem um formato de janela local, tipo `8-22`); vê "Heartbeat: contactos proativos" mais abaixo.
- `--progress`: como o bot sinaliza que está a trabalhar durante uma execução, escolhendo entre `reaction`, `ambient`, `off` e `verbose`; vê "Mostrar que está a trabalhar" mais abaixo.

Para listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

E para correr o poller em primeiro plano (um poller por bot):

```bash
pepe gateway telegram
```

Cada bot fica com o seu próprio poller, o seu token, o seu agente, as suas listas de autorizados e o seu espaço de nomes de sessão. Se dois bots resolverem para o mesmo token, um deles é ignorado automaticamente, já que dois pollers a competir pelo mesmo token entrariam em conflito.

Na prática raramente precisas de correr isto à parte: o `pepe serve` já arranca com os bots configurados a par da API HTTP, por isso um único servidor cobre todos os canais de uma vez.

Ainda dentro de um único bot consegues trocar de agente por conversa com `/agent <nome>` (vê [Encaminhamento](../routing/)); um bot dedicado só faz sentido quando queres que um canal inteiro *seja* um único agente.

<div class="note"><strong>Painel.</strong> Na secção Channels do painel encontras os teus bots com um distintivo de ativo/inativo em tempo real, e dali consegues adicionar um bot, mudar a que agente ele fala, ou removê-lo. Grava exatamente a mesma configuração que a linha de comandos, e os pollers em execução reconciliam-se sozinhos, sem reinício.</div>

### Onde vive a configuração

O bot predefinido fica guardado sob `"telegram"` no `~/.pepe/config.json`. Bots adicionais, com nome próprio, ficam sob `"telegrams"`, um mapa de nome para configuração, e cada um aceita as mesmas chaves do predefinido:

- `bot_token`: o token, literal ou `${ENV_VAR}`.
- `enabled`: se o poller deste bot arranca.
- `agent`: qual o agente que responde.
- `allowed_chats` e `allowed_users`: as listas de ids autorizados; deixa-as de fora e o bot fala com toda a gente.
- `require_mention`: num grupo, só responder quando o bot é @mencionado.
- `reactions`: quais 👍/👎 numa mensagem chegam ao agente como feedback: `own` (predefinição, só reações nas próprias mensagens do bot), `all`, ou `off`. Todo o agente já sabe o que fazer com isto por conta própria: no 👍 guarda na memória o que resultou, no 👎 o que evitar repetir, e nunca responde à reação em si. Como qualquer outra gravação de memória, passa por revisão na página Learning do painel antes de ficar a valer.
- `quick_reactions`: desligado por predefinição. Ligado, uma mensagem que não é mais do que um agradecimento ou um emoji solto ("obrigado!", um ❤️ sozinho) recebe apenas uma reação nativa em vez de uma resposta completa, sem custar uma chamada de modelo; qualquer mensagem com conteúdo real continua a receber a resposta normal.
- `trainers`: de quem o bot aprende, e quem pode correr os seus comandos de operador.

A forma mais fácil de descobrir os ids para essas listas é o `/whoami` numa conversa: imprime o teu id de utilizador e o id da conversa.

As sessões têm espaço de nomes por bot: o predefinido indexa as conversas como `telegram:<chat_id>`, enquanto um bot com nome usa `telegram:<nome>:<chat_id>`. Assim, dois bots nunca colidem, nem nas conversas nem na entrega de tarefas agendadas.

### Comandos de barra

Cada conversa funciona como uma sessão persistente, conduzida por comandos de barra, que também aparecem no menu "/" do Telegram, no idioma configurado.

| Comando | O que faz |
|---|---|
| `/new` | Começa uma conversa nova |
| `/undo` | Anula a tua última mensagem |
| `/retry` | Refaz a última resposta |
| `/compact` | Resume o histórico para libertar contexto |
| `/stop` | Para a execução atual |
| `/inline <texto>` | Injeta uma mensagem na execução já em curso |
| `/btw <pergunta>` | Faz uma pergunta paralela que não fica guardada na conversa |
| `/mention on\|off` | Num grupo, exige ou dispensa a @menção |
| `/model [nome] [session\|global]` | Mostra o modelo atual, ou muda-o |
| `/learn` | Guarda na memória e nas skills o que o agente aprendeu |
| `/whoami` | Mostra os teus ids de utilizador e de conversa do Telegram |
| `/help` | Lista os comandos disponíveis |

E os comandos de operador, reservados aos formadores do bot:

| Comando | O que faz |
|---|---|
| `/agent <nome>` | Muda o agente que responde nesta conversa |
| `/status` | Mostra informação da sessão |
| `/models` | Escolhe um modelo numa lista de botões |
| `/tools` | Lista as ferramentas de runtime disponíveis |
| `/skill [nome]` | Lista as skills, ou executa uma pelo nome |
| `/approve` | Gere as permissões de ferramenta guardadas |
| `/usage` | Mostra o gasto e a contagem de mensagens do mês |

Cada skill instalada ganha também o seu próprio comando de barra: uma skill chamada `weather` responde tanto a `/weather` como a `/skill weather`, e aparece no menu "/". Um comando de skill conta sempre como comando de operador, porque uma skill executa instruções arbitrárias através do agente.

#### Os comandos de operador são só para formadores

A segunda tabela expõe a superfície de operador: a tua configuração, as tuas permissões, o teu gasto, e o inventário interno de modelos, ferramentas e skills. Por isso fica restrita à lista `trainers` do bot, com a barreira colocada no ponto único onde todos os comandos são despachados, o que impede um comando alcançável por dois nomes de a contornar.

- Um bot **sem lista `trainers`** confia em toda a gente com quem fala. É o caso do bot pessoal, e nada muda para ele: tens todos os comandos, skills incluídas.
- Um bot **com lista `trainers`** está virado para o cliente. Um cliente que fale com ele não consegue chegar a `/approve`, `/agent`, `/status`, `/models`, `/tools`, `/skill`, `/usage`, nem a nenhum comando de skill, e esses comandos nem sequer lhe são anunciados: o `/help` só lista o que quem pergunta pode de facto executar, e o menu "/" do bot é construído a pensar na pessoa menos fiável que o pode ver, deixando os comandos de operador completamente fora do popup. Quem não é formador e escreve um desses comandos mesmo assim recebe apenas o aviso de que não está disponível, sem nunca ver o que se passa por dentro.

O `/model` fica, de propósito, a meio caminho: lê-lo sem argumentos revela qual o modelo por trás do bot, o que é informação de infraestrutura, por isso essa leitura é só para formadores. Já mudá-lo não é exclusivo: um cliente pode escolher um modelo para a sua própria conversa, a menos que tranques essa opção (vê "Muda de modelo a meio de uma conversa" mais abaixo).

### Em grupos

Num chat 1:1 o bot responde sempre. Num grupo, por predefinição só responde quando é @mencionado ou recebe um `/comando`, já que de outra forma acabaria por responder a todas as mensagens de um grupo movimentado. Para desligar essa exigência por completo num bot, em todos os grupos onde ele estiver, basta pôr `require_mention: false` durante o `pepe gateway telegram setup`.

Para dispensar isto num único grupo, sem mexer na configuração geral do bot, corre dentro dele:

```text
/mention off   # só neste grupo, até ao /new - não precisa de @menção para responder
/mention on    # volta a exigir uma @menção
/mention       # mostra a configuração atual
```

Essa dispensa fica presa à conversa daquele grupo, não ao bot, por isso nunca se propaga a outros grupos onde o mesmo bot esteja, e uma conversa nova (`/new`) esquece-a.

Uma conversa de grupo é uma única sessão partilhada por toda a gente que lá está. Cada mensagem recebida chega identificada com o nome de quem a escreveu (`Alice: como está o estado?`), para o modelo saber a quem está a responder em cada turno, em vez de presumir que quem escreveu por último é sempre a mesma pessoa de antes; numa conversa privada essa identificação nunca aparece, já que não há mais ninguém a quem pudesse pertencer. O bot também é cego a tudo o que não lhe é dirigido: uma mensagem sem @menção (e sem dispensa por `/mention off`) nunca chega ao agente, nem como contexto silencioso, por isso ele nunca consegue "pôr-se a par" de conversa anterior à sua entrada.

### Tópicos de fórum

Num grupo com **tópicos** ativados, cada tópico funciona como a sua própria conversa, e a resposta volta sempre ao tópico de onde veio. Também podes dar a um tópico **o seu próprio agente**: basta correr `/agent <nome>` dentro dele (ou simplesmente **pedir** ao agente para ligar esse tópico a outro, e ele trata disso por ti), e a associação fica guardada mesmo depois de `/new` ou de um reinício. Os nomes são comparados sem distinguir maiúsculas, por isso `/agent engenheiro` encontra um agente chamado `Engenheiro`. Assim, um mesmo grupo consegue ter um tópico de "suporte" respondido pelo agente de suporte e um de "engenharia" respondido pelo engenheiro, lado a lado. O agente que responde a uma mensagem é sempre o agente vinculado ao tópico, se existir; caso contrário, o `agent` do bot; e, na falta desse, a predefinição global. Um tópico vinculado continua a obedecer à regra de menção do grupo, por isso, se quiseres que responda sem @menção, define `require_mention: false` (ou usa `/mention off` dentro desse tópico).

### Muda de modelo a meio de uma conversa

O `/model` mostra o modelo ativo naquele chat, com um botão **Browse models** para escolheres outro; `/models` salta diretamente para esse seletor. A lista está limitada ao teu projeto e assinala com um visto o modelo em uso, bastando tocar noutro para trocar. As duas leituras são só para formadores, já que revelam quais os modelos por trás do bot. Escrito diretamente:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem este bot fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão; mudá-lo **globalmente**, para todas as conversas atendidas por este bot, fica reservado a **formadores** (a mesma lista que rege o `/learn` e a memória), de modo que ninguém no chat consegue reapontar o bot inteiro para outro modelo em silêncio. É ao formador que se pergunta qual das duas opções pretendia; qualquer outra pessoa muda apenas a própria conversa, sem nada a decidir. Para desativar por completo a troca de modelo a quem não é formador, define `model_switch_locked: true` no bot. Uma troca por sessão vive só em memória e desaparece com `/new` ou com um reinício do servidor, voltando ao que a configuração do próprio agente definir.

### Mostrar que está a trabalhar

Enquanto uma execução decorre, o bot dá sinal de que está ocupado, de propósito de forma ambiente, e não como um relatório de estado para leres com atenção. O indicador nativo de "a escrever..." do Telegram mantém-se ativo em qualquer modo. Por cima dele, o `tool_progress` (a opção `--progress`) escolhe um de quatro:

- `reaction`, a predefinição: uma reação 👀 na tua própria mensagem enquanto o agente trabalha, retirada assim que a resposta chega. Não acrescenta nenhuma mensagem à conversa, e é o mais discreto dos quatro.
- `ambient`: uma única linha vaga ("a procurar coisas...", "a executar algo..."), editada no próprio sítio e apagada quando a resposta surge; sem nomes de ferramenta, sem argumentos, sem registo.
- `off`: nada além do indicador nativo de escrita.
- `verbose`: o registo completo, para quem gosta de acompanhar a execução ao pormenor. Cada chamada de ferramenta aparece assim que acontece, com a frase que o modelo disse antes de a usar logo por cima. O registo mostra *o que* foi feito; a frase explica *porquê*, e é essa combinação que permite perceber que o agente vai por mau caminho antes de lá chegar. Continua a ser uma única mensagem, editada no lugar e apagada quando a resposta chega.

Define este comportamento de três formas: pela linha de comandos com `--progress`; de dentro de uma conversa com a ferramenta `manage_channel` (`set_progress`); ou no **painel**, em Canais → o teu bot → *Editar* → "Enquanto o agente trabalha", onde cada modo vem explicado.

### Heartbeat: contactos proativos

Um bot consegue, de tempos a tempos, dar a palavra ao seu agente para dizer algo **por iniciativa própria** ("o deploy terminou", "pediste-me para ficar atento a X") e, tão importante quanto isso, dar-lhe também o direito de **não dizer nada** na maior parte das vezes. Isto vem desligado, e ativa-se por bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Um agente com a ferramenta `manage_channel` também consegue configurar isto sozinho, dentro de uma conversa:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Cada pulsação corre o agente sobre o contexto vivo da sua sessão, com um prompt a avisar que se trata de uma verificação automática, e a pedir que responda exatamente `HEARTBEAT_OK` se não houver nada que valha a pena dizer. Esse é o caso mais comum, e só uma mensagem genuína chega mesmo a ser enviada à conversa. Duas fontes alimentam esta verificação:

- Um `HEARTBEAT.md` opcional no workspace do agente, onde escreves o que deve ser vigiado.
- **Eventos de sistema**, que qualquer parte do Pepe consegue colocar em fila para uma sessão (`Pepe.Heartbeat.Events.push/2`), e que a pulsação seguinte recolhe sozinha.

Um ciclo proativo descontrolado é impossível por construção: uma barreira de arrefecimento impõe um mínimo de 30 segundos entre pulsações, e um disjuntor corta ao fim de 5 disparos em 60 segundos. O `heartbeat_hours` (uma janela local, como `8-22`) mantém o bot calado fora das horas em que faz sentido falar.

### As conversas mortas curam-se sozinhas

Se um envio volta com falha permanente, seja porque o bot foi bloqueado, seja porque a conversa ou o utilizador desapareceu, essa conversa passa a ser ignorada em todos os envios seguintes, sem chamadas de API desperdiçadas nem ruído no registo. No momento em que um envio para ela volta a resultar, por exemplo porque a pessoa desbloqueou o bot, a marca é retirada automaticamente, sem nada para repores à mão.

### Uma resposta sobrevive a um reinício a meio do envio

Se o Pepe reiniciar, seja por um deploy ou por uma falha, no exato momento em que estava a enviar a resposta de um turno, essa resposta não se perde: é reenviada assim que o bot volta a funcionar, antes de tratar de qualquer coisa nova. Quando o reinício apanhou o envio genuinamente em curso, sem certeza se a mensagem já tinha chegado, a cópia reenviada leva o prefixo "♻️ Recovered reply", para que um possível duplicado fique sempre sinalizado em vez de se repetir em silêncio. Já uma resposta que nunca chegou a começar a ser enviada sai limpa, sem prefixo nenhum. Nada disto precisa de configuração nem tem algo para repores manualmente.

### Idioma e erros

As mensagens fixas do próprio Pepe, como respostas de comando, botões e recusas, seguem o `locale` que configuraste. Já as respostas do agente seguem o idioma em que a pessoa escreve, seja ele qual for. Erros internos em bruto nunca chegam a aparecer na conversa.

### Fá-lo pela conversa

Um agente com a ferramenta `manage_channel` consegue criar e reassociar bots do Telegram a partir de uma conversa. Como isto altera a configuração, toda a chamada passa pela barreira de permissão: o agente propõe a alteração e és tu quem confirma antes de ela ficar a valer.

Poderias dizer, por exemplo:

> Adiciona um bot do Telegram chamado sales que fale com o agente de vendas. O token está na variável de ambiente SALES_BOT_TOKEN.

O agente invoca `manage_channel` com `action: "add"`, `name: "sales"`, `token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Duas salvaguardas importam aqui:

- **Os segredos nunca passam pela conversa.** O que fornece é o *nome* de uma variável de ambiente que guarda o token, nunca o token em si. Fica armazenado como `${SALES_BOT_TOKEN}` e é resolvido no momento da leitura, por isso o segredo em bruto nunca chega ao modelo nem aos registos. Um token em bruto, por conter dois pontos, é sempre rejeitado; és tu quem define essa variável de ambiente.
- **O bot predefinido está protegido e é intocável.** A ferramenta só mexe em bots com nome próprio, nunca no `default`, e não toca em mais nada da tua configuração.

As restantes ações de `manage_channel` são `list`, `set_agent` (para reassociar um bot a outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`, `disable` e `remove`. Depois de qualquer alteração, os pollers em execução reconciliam-se sozinhos, por isso um bot arranca ou pára ao vivo, sem reinício nenhum.

<div class="note"><strong>Apenas Telegram.</strong> Esta ferramenta de conversa gere só bots do Telegram. As ligações por webhook, como WhatsApp, Slack e as restantes, são criadas pela linha de comandos, pelo painel, ou pelo <code>pepe setup</code>, nunca pela conversa.</div>
