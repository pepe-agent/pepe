---
title: Webhooks
description: Configure Slack, Discord, Microsoft Teams, Google Chat e canais por webhook genéricos.
---

## Como funciona um canal por webhook

Não importa a plataforma, todo canal por webhook fica acessível numa única
rota:

```
https://YOUR_HOST/webhooks/<project>/<provider>/<slug>
```

- `<project>` é o projeto ao qual a conexão pertence. Use `default` para o
  projeto padrão, ou o slug de outro projeto para manter essa conexão
  isolada só nele.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` ou `googlechat`.
- `<slug>` é o nome único que você escolheu para a conexão.

Um `GET` nessa URL responde ao handshake de verificação do provedor (o
Pepe simplesmente devolve o desafio que a plataforma manda na primeira vez
que você registra a URL). Um `POST`, por outro lado, é um evento chegando:
o Pepe resolve a conexão correspondente, confere a assinatura da requisição
contra o segredo configurado, extrai a mensagem, roda o agente vinculado e
entrega a resposta pela própria API do provedor. Todo esse trabalho do
agente roda em segundo plano, para a plataforma já receber a confirmação na
hora (provedores como a Meta tentam de novo um webhook que demora demais
para responder).

Existe uma única rota genérica para tudo isso. Adicionar um provedor novo
nunca implica em criar um endpoint novo.

<div class="note"><strong>Host público.</strong> Um canal por webhook
precisa de uma URL que a plataforma consiga alcançar de fato. Exponha sua
instância do Pepe atrás de um proxy reverso ou de um túnel. Se
<code>PHX_HOST</code> já estiver definido (veja
<a href="../deploy/">Publicando em um servidor</a>), as URLs de retorno já
saem certas; defina <code>PEPE_PUBLIC_URL</code> para sobrescrever isso ou
preencher quando não estiver. Para um túnel rápido enquanto testa, rode
<code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Esses provedores se configuram pela configuração guiada (ou pelo painel),
que pergunta exatamente os campos que cada um precisa e já imprime a URL de
retorno para você registrar na plataforma:

```bash
pepe setup
```

Escolha a opção de canal, escolha o provedor e o agente, e informe as
credenciais pedidas (para qualquer segredo, uma referência `${ENV_VAR}`
também é aceita). Cada provedor tem sua própria página, com os campos e
passos específicos dele: [Slack](../slack/), [Discord](../discord/),
[Microsoft Teams](../msteams/), [Google Chat](../googlechat/). O que está
aqui nesta página é justamente o que todos eles têm em comum, e que também
vale para o WhatsApp.

## @Menções em grupo

Slack, Discord (no modo conectado por gateway, veja [Discord](../discord/)), Microsoft Teams e Google Chat suportam conversas em grupo e em canal. Ali o bot só responde quando é @mencionado (uma mensagem direta sempre chega ao agente). Um canal que deve responder a tudo, como o que recebe chamados de outro sistema, é configurado de dentro dele:

```text
/mention off          # responde sem menção, até o /new
/mention on           # volta a exigir menção, até o /new
/mention off always   # responde sem menção, mantido após o /new e ao reiniciar
/mention on always    # volta a exigir menção de vez (o padrão)
/mention              # mostra o que vale aqui
```

Um `/mention off` ou `/mention on` simples vale para esta conversa e é esquecido no `/new`. Com `always`, fica gravado para o canal, seja qual for o agente que responde nele. O que foi dito na conversa vence o que foi gravado para o canal, e o `/new` devolve a decisão ao canal. Uma configuração nunca chega a outro canal.

A regra tem dois níveis, como toda configuração de canal. A **conexão** guarda o padrão para todos os seus canais: *Responder sem ser mencionado* no formulário da conexão no painel (`mention_optional` na configuração, `pepe gateway mention SLUG --set optional|required` na linha de comando), desligado até você ligar. Um **canal** pode ter a sua própria resposta, em qualquer direção, e ela vence só naquele canal: `/mention off always` abre um canal de uma conexão que exige menção, `/mention on always` fecha um canal de uma conexão que responde a tudo. Quando a resposta do canal só repetiria o padrão da conexão, `/mention on always` apenas remove a configuração própria do canal. O que vale, do mais forte para o mais fraco: esta conversa (até o `/new`), a configuração própria do canal, o padrão da conexão e, por fim, menção obrigatória. `/mention` sozinho diz qual desses está em vigor. A linha de cada canal na página Channels mostra a mesma coisa, com a etiqueta *próprio* ou *da conexão* e um caminho de volta para o da conexão; `pepe gateway mention SLUG --channel C --set optional|required` e `--default` fazem isso pela linha de comando. O modelo não consegue mudar nada disso.

Um canal que responde sem menção continua fora de uma mensagem escrita para outra pessoa. No Slack, Discord, Microsoft Teams e Google Chat, uma mensagem que marca uma pessoa, um grupo de usuários ou o canal inteiro (`@here`, `@channel`) e não marca o bot é para eles, então o bot a ignora; marcar o bot, sozinho ou junto com outros, faz ele voltar. Uma mensagem de outro aplicativo fica de fora da regra, porque o cartão de um ticket pode citar pessoas e continuar sendo trabalho do agente.

Como um comando de canal precisa, antes de tudo, ser endereçado ao bot para rodar, o *primeiro* `/mention off` exige uma @menção de verdade (`@bot /mention off`). Depois disso, o canal não precisa mais. O WhatsApp não filtra por menção (responde a tudo), então `/mention` não tem efeito lá.

Mudar isso é reservado aos **trainers** do canal (a mesma lista de confiança do `/agent`), porque muda o comportamento do canal para todos que estão nele. Qualquer pessoa ainda pode mandar `/mention` para ver a configuração atual.

<div class="note"><strong>Digitando um comando no Slack.</strong> O próprio
cliente do Slack trata qualquer coisa que comece com <code>/</code> como uma
tentativa de rodar um dos comandos de barra dele, e recusa nem enviar a
mensagem quando não existe nenhum registrado com esse nome - então
<code>/mention off</code> digitado direto é rejeitado pelo próprio Slack
antes de chegar no Pepe. Digite um espaço antes da barra
(<code> /mention off</code>) para mandar como texto comum; o Pepe remove
esse espaço antes de casar o comando, do jeito que sempre fez.</div>

## Quem pode treinar um canal

O `trainers` da conexão diz quem pode transformar uma conversa em memória, e também quem pode mudar `/agent`, `/model ... global`, `/mention` e esta mesma configuração. Ele vale para todos os canais da conexão. Quando um canal precisa de outra regra, dê a ele uma lista própria, de dentro dele:

```text
/trainers                  # mostra quem pode treinar aqui e de onde isso vem
/trainers *                # todos neste canal
/trainers none             # ninguém
/trainers @ana @bruno      # só essas pessoas (uma marcação do Slack ou um id)
/trainers default          # volta para a lista da conexão
```

A lista própria do canal é a mais forte: ela **substitui** a da conexão só naquele canal, não se soma a ela. Só quem pode treinar o canal agora consegue mudá-la, então ninguém se promove sozinho. Ela é mantida depois do `/new` e de reinícios. O modelo não consegue mudá-la: é uma decisão de uma pessoa, digitada no chat, no painel (a lista de canais de cada conexão, veja abaixo) ou com `pepe gateway trainers SLUG --channel C --set ...`.

No Slack os trainers são as pessoas (os ids de usuário delas), porque cada mensagem agora diz quem a escreveu. Uma lista que citava o id do canal continua funcionando.

## Onde cada conexão está

Na página Channels do painel, o card de cada conexão diz de quantos canais, grupos e mensagens diretas já chegou mensagem ("12 canais"). Abra para ver quais são: o nome, quando a plataforma informou um (senão, o id), se é um grupo ou uma mensagem direta, e quando chegou a última mensagem. Um canal entra na lista a partir da primeira mensagem que chega nele, tenha o bot respondido ou não. Por isso um canal em que o bot só escuta também aparece.

Cada linha traz as configurações daquele canal, que você muda ali mesmo:

- **Agente**: o agente a que o canal está vinculado, o mesmo vínculo que `/agent` cria no chat, ou o da conexão enquanto ele não tiver um.
- **Menção**: a resposta própria do canal para "precisa de @menção?", ou o padrão da conexão enquanto ele não tiver uma (veja [@Menções em grupo](#menções-em-grupo)). Só para provedores que filtram por menção.
- **Quem pode treinar**: os treinadores próprios do canal (veja acima), ou os da conexão enquanto ele não tiver lista própria.

Cada configuração recebe a etiqueta *próprio* quando o canal tem valor próprio e *da conexão* quando herda o padrão; *Usar o da conexão* remove só o valor próprio do canal. Uma mensagem direta também é um canal, listada e configurável do mesmo jeito.

O nome vem junto com a mensagem no Microsoft Teams, no Google Chat, no WhatsApp (o nome do contato) e no Telegram (o título do grupo). No Slack ele é consultado uma vez, na primeira mensagem que chega do canal, e precisa do escopo `channels:read` (`groups:read` para canal privado); sem ele, aparece o id. Mensagens diretas do Slack mostram o id.

O card de um bot do Telegram lista do mesmo jeito os grupos, os tópicos de fórum e as conversas privadas, só com o vínculo de agente: no Telegram, menção e treinadores são definidos por bot.

## Vinculando um canal a um agente

`/agent NOME` vincula essa conversa a um agente de forma permanente - um grupo pode
rotear o canal "suporte" pro agente de suporte e o canal "engenharia" pro engenheiro,
lado a lado, do mesmo jeito que um tópico de fórum do Telegram já consegue (veja
[Telegram](../telegram/)). Fica valendo mesmo depois de `/new` e de reinicializações,
e é reafirmado a cada mensagem, então sempre vence, não importa pra onde a conversa
tenha ido:

```text
/agent engenheiro   # vincula esse canal, a partir de agora
/agent              # mostra o vínculo atual
/agent none         # desvincula, volta pro agente padrão da conexão
```

Isso é uma decisão permanente, que vale pro canal inteiro, não uma escolha pontual de
roteamento - por isso é restrito a **treinadores** (a mesma lista de confiança que já
controla o `/model ... global`); qualquer outra pessoa recebe só um "você não tem
permissão". Um agente com a ferramenta `manage_channel` consegue fazer a mesma coisa
por linguagem natural ("vincula esse canal ao engenheiro, permanentemente") com as
ações `bind_topic`/`unbind_topic` dela - veja
[Roteamento entre agentes](../routing/) pra entender a diferença entre isso e o
`switch_agent`, que é propositalmente temporário e desfeito pelo `/new`.

Pra um canal onde ninguém deve poder trocar qual agente responde - nem temporária
nem permanentemente - defina `agent_switch_locked: true` na conexão. Isso recusa
`/agent NOME` de cara, mesmo para um treinador, além do `switch_agent` e das ações
`bind_topic`/`unbind_topic` do `manage_channel`, em qualquer conversa dessa conexão.
`/agent` sem argumento (status), `/mention`, `/model` e `/new` continuam funcionando
normalmente. Defina com `--agent-switch-locked` no `mix pepe gateway whatsapp add` /
`discord add`, ou direto no `config.json`.

## Trocando de modelo

Os comandos `/model` e `/models` deixam qualquer pessoa consultar ou trocar
qual modelo de IA está respondendo. Eles só funcionam numa conexão em modo
`admin` com `commands` habilitado (veja a comparação de modos em
[Canais](../channels/)); no modo `support`, viram apenas texto comum sem
efeito nenhum. `/models` lista os modelos disponíveis para o projeto
daquela conexão; `/model` mostra o modelo atual, ou troca para outro:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Trocar **globalmente**, valendo para todo mundo que fala com aquela
conexão, é reservado aos **treinadores**, a mesma lista de confiança que
controla a memória; qualquer outra pessoa numa conversa liberada só
consegue trocar o modelo da própria conversa. Para desligar isso
completamente para quem não é treinador, defina `model_switch_locked: true`
na conexão. É exatamente o mesmo mecanismo usado pelo WhatsApp; já a versão
do Telegram acrescenta um seletor por botões, em vez de depender só de
comandos digitados.

## Aprovando ferramentas de risco no chat

Por padrão, um canal por webhook não tem ninguém para perguntar, então uma ferramenta de risco que não está no `auto_approve` do agente é recusada e fica guardada para um operador aprovar pela linha de comando (`mix pepe approvals`). Para que as pessoas da conversa decidam ali mesmo, informe os **trainers** na conexão: uma lista explícita, ou `["*"]` para todos da conversa. Aí, quando o agente quer fazer algo arriscado, ele pergunta no próprio chat, mostra o comando de verdade e espera uma resposta digitada:

```text
Reply with: allow / allow all / allow session / deny
```

Só vale a resposta exata de um trainer, e ela não é repassada ao agente como mensagem. A resposta de qualquer outra pessoa, ou uma frase mais longa que contenha "allow", é só uma mensagem. As duas respostas mais amplas ("permitir tudo na sessão" e "sempre") não podem ser digitadas aqui; use uma superfície com botões para elas. Se ninguém responder em cinco minutos, conta como um não, e o agente é avisado de que ninguém respondeu, em vez de que foi recusado.

Sem trainers informados nada muda: só roda o que o agente já tem pré-aprovado.

## Por baixo dos panos: o contrato do provedor

Cada canal por webhook nada mais é do que um módulo pequeno implementando o
mesmo contrato, o que garante um comportamento coerente entre todos eles e
faz com que uma plataforma nova signifique um módulo novo, nunca uma rota
nova. Os callbacks desse contrato são:

- `name` e `label`: o segmento de URL do provedor e o nome legível para
  humanos.
- `config_schema`: os campos que o painel renderiza para configurar uma
  conexão.
- `verify`: responde ao handshake de verificação feito via `GET`.
- `authenticate`: confere a assinatura de um `POST` recebido contra o
  segredo da conexão e o corpo cru da requisição. Uma requisição que falha
  nessa checagem é descartada sem mais.
- `parse`: normaliza o payload da plataforma em zero ou mais mensagens
  simples, descartando pelo caminho atualizações de status e recibos de
  entrega.
- `respond` (opcional): produz uma resposta síncrona quando o protocolo
  exige isso antes de qualquer trabalho do agente, como o desafio
  `url_verification` do Slack, ou o ping seguido de confirmação adiada do
  Discord.
- `deliver`: envia uma resposta em texto de volta para quem mandou a
  mensagem.
- `deliver_file` (opcional): envia um arquivo como anexo.

Um plugin que implemente esse contrato se registra sozinho como um novo
provedor, sob o próprio `name`, e já fica acessível na mesma rota
`/webhooks/...`, sem exigir nenhuma fiação extra.
