---
title: Webhooks
description: Configura Slack, Discord, Microsoft Teams, Google Chat e canais por webhook genéricos.
---

## Como funciona um canal por webhook

Todo o canal por webhook, seja qual for a plataforma, está acessível numa única
rota:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` é o âmbito de empresa. Usa `root` para o âmbito predefinido
  (apresentado como "Principal" no painel), ou o identificador de uma empresa
  para isolar uma ligação nessa empresa.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`, `msteams`
  ou `googlechat`.
- `<slug>` é o nome único que deste à ligação.

Um `GET` a esse URL responde ao aperto de mão de verificação do fornecedor (o
Pepe devolve o desafio que a plataforma envia quando regista o URL pela primeira
vez). Um `POST` é um evento de entrada. Num `POST`, o Pepe resolve a ligação,
verifica a assinatura do pedido contra o segredo que configuraste, extrai a
mensagem, executa o agente associado e entrega a resposta pela própria API do
fornecedor. O trabalho do agente decorre em segundo plano para que a plataforma
receba a confirmação de imediato (fornecedores como a Meta repetem um webhook
lento).

Há uma única rota genérica. Adicionar um novo fornecedor nunca acrescenta um novo
ponto de acesso.

<div class="note"><strong>Host público.</strong> Os canais por webhook precisam
de um URL que a plataforma consiga alcançar. Expõe a tua instância do Pepe atrás
de um proxy inverso ou de um túnel, e define <code>PEPE_PUBLIC_URL</code> para que
os URLs de retorno que a linha de comandos imprime fiquem completos. Para um túnel
rápido durante os testes, executa <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estes fornecedores são configurados pela configuração guiada (ou pelo painel), que
pede exatamente os campos de que cada um precisa e imprime o URL de retorno a
registar:

```bash
pepe setup
```

Escolhe a opção de canal, escolhe o fornecedor e o agente, e introduz as
credenciais (uma referência `${ENV_VAR}` é aceite para qualquer segredo). Cada
um tem a sua própria página com os campos e passos de configuração
específicos: [Slack](../slack/), [Discord](../discord/),
[Microsoft Teams](../msteams/), [Google Chat](../googlechat/); esta página
cobre o que é partilhado por todos eles (e pelo WhatsApp).

## @Menções em grupos

Slack, Microsoft Teams e Google Chat suportam conversas em grupo/canal, onde
por padrão a ligação só responde quando é @mencionada (uma mensagem direta
chega sempre ao agente, independentemente da configuração). Define
`require_mention: false` na ligação para que responda a todas as mensagens
em todos os canais em que está - ou, sem mexer nessa configuração de toda a
ligação, dispensa isso para um único canal a partir desse canal:

```text
/mention off   # só neste canal, até ao /new - não é preciso @mencionar para responder
/mention on    # volta a exigir uma @menção
/mention       # mostra a configuração atual
```

Como um comando de canal ainda tem de estar dirigido ao bot para correr, o
*primeiro* `/mention off` precisa de uma @menção real (`@bot /mention off`);
depois disso, o canal deixa de precisar até ao `/new`. A dispensa vive na
conversa desse canal, não na ligação, por isso nunca se propaga para nenhum
outro canal. WhatsApp e Discord não filtram por menção hoje (respondem
sempre), por isso `/mention` não tem efeito nenhum aí.

## Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` com `commands`
ativado (vê a comparação de modos em [Channels](../channels/)); no
`support`, são texto simples. `/models` lista os modelos disponíveis para a
empresa da ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Mudá-lo **globalmente** está reservado a **formadores** (a mesma lista que
rege a memória); qualquer outra pessoa numa conversa permitida só pode mudar a
sua própria sessão. Define `model_switch_locked: true` na ligação para
desativar isto por completo para quem não é formador. É o mesmo mecanismo
que o WhatsApp usa; a versão do Telegram acrescenta um seletor com botões em
vez de comandos escritos.
