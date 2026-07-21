---
title: Telegram
description: Cria e gere bots do Telegram ligados a agentes do Pepe.
---

## Telegram

O Telegram é o canal mais rápido de pôr de pé porque não precisa de qualquer URL
público. Cria um bot com o @BotFather, copia o respetivo token e regista-o. O Pepe
consulta o Telegram à procura de mensagens novas, por isso não há webhook nenhum
a expor.

Configura o bot predefinido de forma interativa:

```bash
pepe gateway telegram setup
```

Isto pede o token (podes colar um token literal ou uma referência `${ENV_VAR}`),
um agente opcional para associar e uma lista opcional de ids de conversa
autorizados a falar com ele.

Podes executar mais do que um bot, cada um associado a um agente diferente:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

As opções do `telegram add`:

- `--token` (obrigatória): o token do bot, literal ou `${ENV_VAR}`.
- `--agent`: qual o agente que responde. Omite para usar o teu agente
  predefinido.
- `--trainers`: de quem este bot pode aprender para a memória, e quem pode
  executar os comandos de operador dele. Omite para todos, `none` para ninguém, ou
  uma lista separada por vírgulas de ids de utilizador para apenas esses.
- `--heartbeat-minutes` e `--heartbeat-hours`: uma janela periódica opcional de
  ativação (para agentes que verificam coisas segundo um horário). As horas são
  uma janela local como `8-22`. Vê "Heartbeat" mais abaixo.
- `--progress`: como o bot sinaliza que está a trabalhar enquanto uma execução
  decorre. Uma entre `reaction`, `ambient`, `off` ou `verbose`. Vê "Mostrar que
  está a trabalhar" mais abaixo.

Listar e remover bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Executa o poller em primeiro plano (um poller por bot):

```bash
pepe gateway telegram
```

Cada bot tem o seu próprio poller, o seu token, o seu agente associado, as suas
listas de autorizados e o seu espaço de nomes de sessão. Dois bots que resolvem
para o mesmo token são desduplicados, porque dois pollers num só token entrariam
em conflito um com o outro.

Normalmente não precisas de executar isto em separado. O `pepe serve` arranca com
os bots do Telegram configurados a par da API HTTP, por isso um único servidor em
execução cobre todos os canais de uma vez.

Dentro de um único bot podes na mesma mudar de agente por conversa com
`/agent <nome>` (vê [Encaminhamento](../routing/)). Um bot dedicado é para quando
um canal inteiro deve *ser* um agente.

<div class="note"><strong>Painel.</strong> A secção Channels do painel lista os
teus bots com um distintivo ao vivo de ativo/inativo, permite-te adicionar um
bot, editar com que agente ele fala e removê-lo. Grava a mesma configuração que a
linha de comandos, e os pollers em execução reconciliam-se sem reinício.</div>

### Onde vive a configuração

O bot predefinido vive sob `"telegram"` no `~/.pepe/config.json`. Os bots com nome
adicionais vivem sob `"telegrams"`, um mapa de nome para configuração, e cada um
deles aceita as mesmas chaves do bot predefinido:

- `bot_token`: o token, literal ou `${ENV_VAR}`.
- `enabled`: se o poller deste bot arranca.
- `agent`: qual o agente que responde.
- `allowed_chats` e `allowed_users`: as listas de ids autorizados. Deixa-as de
  fora e o bot fala com qualquer um.
- `require_mention`: num grupo, só responder quando o bot é @mencionado.
- `reactions`: que 👍/👎 numa mensagem chegam ao agente como feedback — `own`
  (padrão, só reações nas próprias mensagens do bot), `all` ou `off`.
- `quick_reactions`: desligado por padrão. Ligado, uma mensagem que é só um
  agradecimento ou um emoji solto ("obrigado!", um ❤️ sozinho) recebe uma
  reação nativa em vez de uma resposta completa, sem gastar chamada de
  modelo. Tudo o que tiver conteúdo real continua a receber resposta normal.
- `trainers`: com quem o bot aprende, e quem pode executar os comandos de operador
  dele.

O `/whoami` numa conversa é a forma fácil de descobrir os ids para essas listas.
Imprime o teu id de utilizador e o id da conversa.

As sessões têm espaço de nomes por bot. O bot predefinido indexa as conversas como
`telegram:<chat_id>`, enquanto um bot com nome usa `telegram:<name>:<chat_id>`.
Dois bots nunca colidem, portanto, nem nas conversas nem na entrega de tarefas
agendadas.

### Comandos de barra

Cada conversa é uma sessão persistente, conduzida por comandos de barra. Também
aparecem no menu "/" do Telegram, no idioma que configuraste.

| Comando | O que faz |
|---|---|
| `/new` | Começa uma conversa nova |
| `/undo` | Anula a tua última mensagem |
| `/retry` | Refaz a última resposta |
| `/compact` | Resume o histórico para libertar contexto |
| `/stop` | Para a execução atual |
| `/inline <texto>` | Injeta uma mensagem na execução já a decorrer |
| `/btw <pergunta>` | Faz uma pergunta paralela que não fica guardada na conversa |
| `/mention on\|off` | Num grupo, exigir ou não uma @menção |
| `/model [nome] [session\|global]` | Mostra o modelo atual, ou define-o |
| `/learn` | Guarda o que o agente aprendeu na memória e nas skills |
| `/whoami` | Mostra os teus ids de utilizador e de conversa do Telegram |
| `/help` | Lista os comandos que podes executar |

E os comandos de operador, que só os formadores do bot podem executar:

| Comando | O que faz |
|---|---|
| `/agent <nome>` | Muda o agente que responde nesta conversa |
| `/status` | Mostra informação da sessão |
| `/models` | Escolhe um modelo numa lista de botões |
| `/tools` | Lista as ferramentas de runtime disponíveis |
| `/skill [nome]` | Lista as skills, ou executa uma pelo nome |
| `/approve` | Gere as permissões de ferramenta guardadas |
| `/usage` | Mostra o gasto e a contagem de mensagens do mês |

As skills instaladas tornam-se também comandos de barra próprios, por isso uma
skill chamada `weather` responde a `/weather` além de `/skill weather`, e fica
descoberta a partir do menu "/". Um comando de skill conta como comando de
operador, porque uma skill executa instruções arbitrárias através do agente.

#### Os comandos de operador são só para formadores

Os comandos da segunda tabela expõem a superfície de operador: a tua configuração,
as tuas permissões, o teu gasto e o inventário interno de modelos, ferramentas e
skills. Estão restritos à lista `trainers` do bot, e a barreira fica no ponto
único onde todos os comandos são despachados, por isso um comando que pode ser
alcançado por dois nomes não consegue contorná-la.

- Um bot **sem lista `trainers`** confia em toda a gente com quem fala. É o bot
  pessoal, e para ele nada muda: tens todos os comandos, skills incluídas.
- Um bot **com lista `trainers`** é virado para o cliente. Um cliente que fale com
  ele não consegue alcançar `/approve`, `/agent`, `/status`, `/models`, `/tools`,
  `/skill` nem `/usage`, nem qualquer comando de skill. Também não lhe são
  anunciados: o `/help` lista apenas os comandos que quem chamou pode de facto
  executar, e o menu "/" do bot é construído para a pessoa menos fiável que o
  consegue ver, por isso os comandos de operador ficam de fora do popup por
  completo. Quem não é formador e escreve um mesmo assim ouve que o comando não
  está disponível ali, e nunca vê os interiores de operador.

O `/model` é, de propósito, metade de cada. Lê-lo (`/model` sem argumentos) revela
qual o modelo por trás do bot, o que é infraestrutura, por isso esse caminho é só
para formadores. Mudá-lo não é: um cliente pode escolher um modelo para a sua
própria conversa, a não ser que tranques isso. Vê "Muda de modelo a meio de uma
conversa" abaixo.

### Em grupos

Num chat 1:1 o bot responde sempre. Adicionado a um grupo, por padrão só
responde quando é @mencionado ou recebe um `/comando`; caso contrário,
responderia a todas as mensagens num grupo movimentado. Desliga essa
exigência por completo para um bot (em todos os grupos em que está) com
`require_mention: false` durante o `pepe gateway telegram setup`.

Para um único grupo, sem mexer na configuração do bot inteiro, corre:

```text
/mention off   # só neste grupo, até ao /new - não precisa de @menção para responder
/mention on    # volta a exigir uma @menção
/mention       # mostra a configuração atual
```

A dispensa vive na conversa desse grupo, não no bot, por isso nunca se
propaga para nenhum outro grupo em que o mesmo bot esteja, e uma conversa
nova (`/new`) esquece-a.

Uma conversa de grupo é uma única sessão partilhada entre todos os que estão
nela, sem identificar quem disse o quê. Se o teu agente precisar de
distinguir as pessoas, indica isso no prompt dele. O bot também é cego ao que
não lhe é dirigido: uma mensagem que não o @menciona (e não está dispensada
com `/mention off`) nunca chega ao agente, nem como contexto silencioso, por
isso não consegue "pôr-se a par" do que se falou antes de ele ser trazido
para a conversa.

### Tópicos de fórum

Num grupo com **tópicos** ativados, cada tópico é uma conversa própria, e a
resposta volta ao tópico de onde veio. Podes dar a um tópico **o seu próprio
agente**: corre `/agent <nome>` dentro do tópico — ou simplesmente **pede** ao
agente para ligar este tópico a outro, que ele faz por ti — e ele fica vinculado
a esse agente, mantido através do `/new` e de reinícios. Os nomes são
correspondidos sem distinguir maiúsculas, por isso `/agent engenheiro` encontra um
agente chamado `Engenheiro`. Assim um grupo pode ter um
tópico de "suporte" respondido pelo agente de suporte e um de "engenharia" pelo
engenheiro, lado a lado. O agente de uma mensagem é o agente vinculado ao tópico,
se houver; senão o `agent` do bot; senão a predefinição global. Um tópico
vinculado ainda segue a regra de menção do grupo — põe `require_mention: false`
(ou `/mention off` nesse tópico) se quiseres que responda sem @menção.

### Muda de modelo a meio de uma conversa

`/model` mostra o modelo ativo nesse chat, com um botão **Browse models**
para escolher outro; `/models` vai direto a esse seletor. O seletor está limitado
ao teu projeto e põe um visto no modelo em uso, por isso tocas num para mudar.
Ambas estas leituras são só para formadores, já que revelam que modelos estão por
trás do bot. Utilização escrita:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem este bot fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** (para todas as conversas que este bot atende) está
reservado a **formadores** (a mesma lista que rege o `/learn` e a memória),
por isso um membro qualquer do chat não consegue reapontar todo o bot para
outro modelo em silêncio. É ao formador que é perguntado qual das duas opções
quis dizer; qualquer outra pessoa muda apenas a sua própria conversa, sem nada a
responder. Define `model_switch_locked: true` no bot para desativar por completo a
mudança de modelo para quem não é formador. Uma alteração de sessão vive só em
memória; repõe-se com `/new` ou com um reinício do servidor, voltando ao que a
configuração própria do agente disser.

### Mostrar que está a trabalhar

Enquanto uma execução decorre, o bot mostra que está ocupado. Isto é de propósito
um sinal ambiente, e não um relatório de estado que devas ler. O indicador nativo
de "a escrever..." do Telegram mantém-se vivo em todos os modos. Por cima dele, o
`tool_progress` (a opção `--progress`) escolhe um de quatro:

- `reaction`, a predefinição: uma reação 👀 na tua própria mensagem enquanto o
  agente trabalha, retirada quando a resposta chega. Não acrescenta qualquer
  mensagem à conversa, e é o mais silencioso dos quatro.
- `ambient`: uma única linha vaga ("a procurar coisas...", "a executar algo...")
  editada no sítio e apagada quando a resposta chega. Sem nomes de ferramenta, sem
  argumentos, sem registo.
- `off`: nada além do indicador nativo de escrita.
- `verbose`: o registo completo, para quem quer acompanhar a execução. Cada
  chamada de ferramenta assim que acontece e, por cima dela, a frase que o modelo
  disse antes de recorrer àquela ferramenta. O registo diz *o que* fez; a frase
  diz *porquê*, que é o que permite ver o agente a ir para o sítio errado antes
  de lá chegar. Continua a ser uma única mensagem, editada no lugar, apagada
  quando a resposta chega.

Define-o de três formas: pela linha de comandos com `--progress`; de dentro de uma
conversa com a ferramenta `manage_channel` (`set_progress`); ou no **painel**, em
Canais → o seu bot → *Editar* → "Enquanto o agente trabalha", onde cada modo é explicado.

### Heartbeat: contactos proativos

Um bot pode periodicamente dar a palavra ao seu agente para dizer alguma coisa
**por iniciativa própria** ("o deploy terminou", "pediste-me para ficar atento a
X") e, igualmente importante, o direito de **não dizer nada** na maior parte do
tempo. Vem desligado, e ativa-lo por bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

Um agente que tenha a ferramenta `manage_channel` também consegue configurar isto
sozinho, de dentro de uma conversa:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Cada pulsação executa o agente sobre o contexto vivo da sua sessão, com um prompt
que diz que esta é uma verificação automática e que deve responder exatamente
`HEARTBEAT_OK` se não houver nada que valha a pena dizer. Esse é o caso comum, e
só uma mensagem genuína chega a ser enviada para a conversa. Alimenta-lo com duas
coisas:

- Um `HEARTBEAT.md` opcional no workspace do agente, que é onde escreves o que deve
  ser vigiado.
- **Eventos de sistema**, que qualquer parte do Pepe pode colocar em fila para uma
  sessão (`Pepe.Heartbeat.Events.push/2`), e que a pulsação seguinte recolhe
  sozinha.

Um ciclo proativo descontrolado é impossível por construção. Uma barreira de
arrefecimento impõe um mínimo de 30 segundos entre pulsações, e um disjuntor de
cheia dispara com 5 disparos em 60 segundos. O `heartbeat_hours` (uma janela local
como `8-22`) mantém o bot calado fora das horas em que estás acordado.

### As conversas mortas curam-se sozinhas

Se um envio volta com falha permanente, porque o bot foi bloqueado ou porque a
conversa ou o utilizador desapareceu, essa conversa passa a ser ignorada em todos
os envios seguintes. Não há chamadas de API desperdiçadas nem ruído no registo. No
momento em que um envio para ela volta a resultar, por exemplo porque a pessoa
desbloqueou o bot, a marca é retirada automaticamente. Não há nada para repor à
mão.

### Uma resposta sobrevive a um reinício a meio do envio

Se o Pepe reiniciar (um deploy, uma falha) no momento exato em que estava a enviar a
resposta de um turno, essa resposta não se perde: é reenviada assim que o bot volta a
funcionar, antes de começar a tratar seja o que for de novo. Quando o reinício
aconteceu com o envio genuinamente em curso (por isso não há certeza se a mensagem já
chegou), a cópia reenviada leva o prefixo "♻️ Recovered reply", para que um possível
duplicado fique sempre sinalizado em vez de se repetir em silêncio. Uma resposta que
nunca chegou a ser enviada sai limpa, sem prefixo. Isto não precisa de nenhuma
configuração e não há nada para repor à mão.

### Idioma e erros

As mensagens fixas do próprio Pepe (respostas de comando, botões, recusas) seguem
o `locale` que configuraste. As respostas do agente seguem o idioma em que a
pessoa escreve, seja ele qual for. Os erros internos em bruto nunca são
derramados na conversa.

### Fá-lo pela conversa

Um agente que tenha a ferramenta `manage_channel` consegue criar e reassociar
bots do Telegram a partir de uma conversa. Como edita a configuração, cada
chamada passa pela barreira de permissão: o agente propõe a alteração e tu
confirmas antes de ela ser aplicada.

Dirias:

> Adiciona um bot do Telegram chamado sales que fale com o agente de vendas. O
> token está na variável de ambiente SALES_BOT_TOKEN.

O agente invoca `manage_channel` com `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"` e `agent: "sales"`. Aqui importam duas
salvaguardas:

- **Os segredos nunca passam pela conversa.** Fornece o *nome* de uma variável de
  ambiente que guarda o token, nunca o token em si. É armazenado como
  `${SALES_BOT_TOKEN}` e resolvido no momento da leitura, por isso o segredo em
  bruto nunca chega ao modelo nem aos registos. Um token em bruto (que contém
  dois pontos) é rejeitado. És tu que defines essa variável de ambiente.
- **O bot predefinido protegido é intocável.** A ferramenta só mexe em bots com
  nome, nunca no `default`, e não toca em mais nada da tua configuração.

Outras ações do `manage_channel` são `list`, `set_agent` (reassociar um bot a
outro agente), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`,
`disable` e `remove`. Após qualquer alteração, reconcilia os pollers em
execução, por isso um bot arranca ou pára ao vivo, sem reinício.

<div class="note"><strong>Apenas Telegram.</strong> A ferramenta de conversa
gere bots do Telegram. As ligações por webhook (WhatsApp, Slack e as restantes)
são criadas pela linha de comandos, pelo painel ou pelo <code>pepe setup</code>,
não pela conversa.</div>
