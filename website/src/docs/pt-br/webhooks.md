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
instância do Pepe atrás de um proxy reverso ou de um túnel, e configure
<code>PEPE_PUBLIC_URL</code> para que as URLs de retorno impressas pela
linha de comando já saiam completas. Para um túnel rápido enquanto você
testa, rode <code>pepe serve --tunnel</code>.</div>

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

Slack, Microsoft Teams e Google Chat suportam conversas em grupo ou canal,
onde, por padrão, a conexão só responde quando é @mencionada (uma mensagem
direta, essa sim, sempre chega ao agente, independente dessa
configuração). Para responder a toda mensagem em qualquer canal onde
estiver, defina `require_mention: false` na conexão. Ou, sem tocar nessa
configuração geral, dá para dispensar a exigência só num canal específico,
de dentro dele mesmo:

```text
/mention off   # só nesse canal, até o /new - não precisa @mencionar para ele responder
/mention on    # volta a exigir @menção
/mention       # mostra a configuração atual
```

Como um comando de canal precisa, antes de tudo, ser endereçado ao bot para
rodar, o *primeiro* `/mention off` ainda exige uma @menção de verdade
(`@bot /mention off`); depois dele, o canal fica dispensado até o próximo
`/new`. Essa dispensa vive na conversa daquele canal específico, não na
conexão como um todo, então não vaza para nenhum outro canal. WhatsApp e
Discord, por sua vez, não filtram por menção hoje (sempre respondem a
tudo), então `/mention` simplesmente não tem efeito nenhum ali.

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
- `fetch_media` (opcional): baixa um anexo recebido que o `parse` só descreveu e devolve os bytes. Tudo que vem depois do download (transcrever, ler um documento, entregar uma imagem a um modelo com visão) é compartilhado. Um provider sem esse callback avisa quem enviou que o canal não recebe anexos, em vez de descartar o arquivo em silêncio.

Um plugin que implemente esse contrato se registra sozinho como um novo
provedor, sob o próprio `name`, e já fica acessível na mesma rota
`/webhooks/...`, sem exigir nenhuma fiação extra.
