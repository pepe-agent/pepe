---
title: Webhooks
description: Configure Slack, Discord, Microsoft Teams, Google Chat e canais por webhook genéricos.
---

## Como funciona um canal por webhook

Todo canal por webhook, seja qual for a plataforma, é acessível em uma única
rota:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` é o escopo de empresa. Use `root` para o escopo padrão
  (mostrado como "Principal" no painel), ou o identificador de uma empresa para
  isolar uma conexão naquela empresa.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` ou `googlechat`.
- `<slug>` é o nome único que você deu à conexão.

Um `GET` para essa URL responde ao aperto de mão de verificação do provedor (o
Pepe devolve o desafio que a plataforma envia quando você registra a URL pela
primeira vez). Um `POST` é um evento de entrada. Em um `POST`, o Pepe resolve a
conexão, verifica a assinatura da requisição contra o segredo que você
configurou, extrai a mensagem, executa o agente vinculado e entrega a resposta
pela própria API do provedor. O trabalho do agente roda em segundo plano para
que a plataforma receba o retorno na hora (provedores como a Meta repetem um
webhook lento).

Há uma única rota genérica. Adicionar um novo provedor nunca adiciona um novo
ponto de acesso.

<div class="note"><strong>Host público.</strong> Canais por webhook precisam de
uma URL que a plataforma consiga alcançar. Exponha sua instância do Pepe atrás
de um proxy reverso ou de um túnel, e defina <code>PEPE_PUBLIC_URL</code> para
que as URLs de retorno que a linha de comando imprime fiquem completas. Para um
túnel rápido durante os testes, rode <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Esses provedores são configurados pela configuração guiada (ou pelo painel), que
pede exatamente os campos de que cada um precisa e imprime a URL de retorno para
registrar:

```bash
pepe setup
```

Escolha a opção de canal, escolha o provedor e o agente, e informe as
credenciais (uma referência `${ENV_VAR}` é aceita para qualquer segredo). Cada
um tem sua própria página com os campos e passos de configuração específicos:
[Slack](../slack/), [Discord](../discord/), [Microsoft Teams](../msteams/),
[Google Chat](../googlechat/). Esta página cobre o que é compartilhado por
todos eles (e pelo WhatsApp).

## Trocando de modelo

`/model` e `/models` só disparam numa conexão em modo `admin` com `commands`
habilitado (veja a comparação de modos em [Channels](../channels/)); no
`support`, viram texto puro. `/models` lista os modelos disponíveis para a
empresa da conexão; `/model` mostra o atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Trocar **globalmente** é reservado para **treinadores** (a mesma lista que
controla a memória); qualquer outra pessoa numa conversa permitida só pode
trocar sua própria sessão. Defina `model_switch_locked: true` na conexão para
desativar isso totalmente para quem não é treinador. É o mesmo mecanismo que o
WhatsApp usa; a versão do Telegram acrescenta um seletor com botões em vez de
comandos digitados.

## Por baixo dos panos: o contrato do provedor

Cada canal por webhook é um pequeno módulo que implementa o mesmo contrato, então
todos se comportam de forma coerente e uma nova plataforma é um novo módulo em
vez de uma nova rota. As funções de retorno são:

- `name` e `label`: o segmento de URL do provedor e seu nome para pessoas.
- `config_schema`: os campos que o painel mostra para configurar uma conexão.
- `verify`: responder ao aperto de mão de verificação do `GET`.
- `authenticate`: verificar a assinatura em um `POST` de entrada contra o segredo
  da conexão e o corpo cru da requisição. Uma requisição que falha é descartada.
- `parse`: normalizar a carga da plataforma em zero ou mais mensagens simples.
  Atualizações de estado e recibos de entrega são ignorados.
- `respond` (opcional): produzir uma resposta síncrona quando o protocolo exige
  uma antes de qualquer trabalho do agente, como o desafio `url_verification` do
  Slack ou o ping e o retorno adiado do Discord.
- `deliver`: enviar uma resposta de texto de volta ao remetente.
- `deliver_file` (opcional): enviar um arquivo como anexo.

Se você escrever um plugin que implementa esse contrato, ele se registra como um
novo provedor sob o próprio `name`, acessível na mesma rota `/webhooks/...` sem
fiação extra.
