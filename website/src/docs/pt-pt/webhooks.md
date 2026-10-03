---
title: Webhooks
description: Configura Slack, Discord, Microsoft Teams, Google Chat e canais por webhook genéricos.
---

## Como funciona um canal por webhook

Seja qual for a plataforma, todo o canal por webhook fica acessível numa única rota:

```
https://YOUR_HOST/webhooks/<project>/<provider>/<slug>
```

- `<project>` é o projeto a que a ligação pertence: usa `default` para o projeto default, ou o slug de outro projeto para manter essa ligação isolada nele.
- `<provider>` é o nome da plataforma: `whatsapp`, `slack`, `discord`, `msteams` ou `googlechat`.
- `<slug>` é o nome único que atribuíste à ligação.

Um `GET` a esse URL responde ao aperto de mão de verificação do fornecedor (o Pepe devolve o desafio que a plataforma envia quando registas o URL pela primeira vez). Um `POST`, por sua vez, é um evento de entrada: o Pepe resolve a ligação, verifica a assinatura do pedido contra o segredo configurado, extrai a mensagem, corre o agente associado, e entrega a resposta pela própria API do fornecedor. Todo este trabalho decorre em segundo plano, para a plataforma receber a confirmação de imediato, já que fornecedores como a Meta voltam a tentar um webhook lento.

Há uma única rota genérica: adicionar um novo fornecedor nunca implica um novo ponto de acesso.

<div class="note"><strong>Precisa de um host público.</strong> Os canais por webhook exigem um URL que a plataforma consiga alcançar. Expõe a tua instância do Pepe atrás de um proxy inverso ou de um túnel. Se o <code>PHX_HOST</code> já estiver definido (vê <a href="../deploy/">Publicar num servidor</a>), os URLs de retorno já saem certos; define <code>PEPE_PUBLIC_URL</code> para sobrepor isso ou preenchê-lo quando não estiver. Para um túnel rápido enquanto testas, corre <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estes fornecedores configuram-se pela configuração guiada (ou pelo painel), que pede exatamente os campos que cada um precisa e imprime o URL de retorno a registar:

```bash
pepe setup
```

Escolhe a opção de canal, seleciona o fornecedor e o agente, e introduz as credenciais (qualquer segredo aceita uma referência `${ENV_VAR}`). Cada plataforma tem a sua própria página, com os campos e passos específicos: [Slack](../slack/), [Discord](../discord/), [Microsoft Teams](../msteams/), [Google Chat](../googlechat/). Esta página cobre apenas o que é comum a todas elas, e ao WhatsApp.

## @Menções em grupos

Slack, Discord (no modo ligado por gateway, vê [Discord](../discord/)), Microsoft Teams e Google Chat suportam conversas em grupo ou canal, onde, por predefinição, a ligação só responde quando é @mencionada (uma mensagem direta chega sempre ao agente, independentemente disso). Define `require_mention: false` na ligação para responder a todas as mensagens em todos os canais onde participa; em alternativa, sem tocar nessa configuração geral, dispensa a exigência para um único canal a partir de dentro dele:

```text
/mention off   # só neste canal, até ao /new - não é preciso @mencionar para responder
/mention on    # volta a exigir uma @menção
/mention       # mostra a configuração atual
```

Como um comando de canal tem sempre de estar dirigido ao bot para correr em primeiro lugar, o *primeiro* `/mention off` ainda precisa de uma @menção genuína (`@bot /mention off`); depois disso, o canal deixa de precisar até ao próximo `/new`. Essa dispensa fica presa à conversa daquele canal, não à ligação, por isso nunca se propaga a nenhum outro canal. O WhatsApp, esse, não filtra por menção hoje em dia (responde sempre), por isso `/mention` não tem efeito nenhum lá.

Ligar ou desligar está reservado aos **trainers** do canal (a mesma lista de confiança do `/agent`), porque muda o comportamento do canal para todos os que lá estão. Qualquer pessoa pode na mesma enviar `/mention` para ver a definição atual.

<div class="note"><strong>Escrever um comando no Slack.</strong> O próprio cliente do Slack trata tudo o que comece por <code>/</code> como uma tentativa de correr um dos seus próprios comandos de barra, e recusa-se a enviar sequer a mensagem quando não há nenhum registado com esse nome - por isso <code>/mention off</code> escrito diretamente é rejeitado pelo Slack antes de chegar ao Pepe. Escreve um espaço antes da barra (<code> /mention off</code>) para o enviar como texto normal; o Pepe remove esse espaço antes de comparar com o comando, tal como sempre fez.</div>

## Vincular um canal a um agente

`/agent NOME` vincula esta conversa a um agente de forma permanente - um grupo pode encaminhar o canal "suporte" para o agente de suporte e o canal "engenharia" para o engenheiro, lado a lado, tal como um tópico de fórum do Telegram já consegue (vê [Telegram](../telegram/)). Mantém-se depois de `/new` e de reinícios, e é reafirmado a cada mensagem, por isso ganha sempre, seja para onde for que a conversa tenha andado:

```text
/agent engenheiro   # vincula este canal, a partir de agora
/agent              # mostra o vínculo atual
/agent none         # desvincula, volta ao agente predefinido da ligação
```

É uma decisão permanente, que vale para o canal inteiro, não uma escolha pontual de encaminhamento - por isso está reservada a **formadores** (a mesma lista de confiança que já controla o `/model ... global`); qualquer outra pessoa recebe só um "não tens permissão". Um agente com a ferramenta `manage_channel` consegue fazer o mesmo por linguagem natural ("vincula este canal ao engenheiro, de forma permanente") com as ações `bind_topic`/`unbind_topic` dela - vê [Encaminhamento entre agentes](../routing/) para perceberes a diferença entre isto e o `switch_agent`, que é propositadamente temporário e é desfeito pelo `/new`.

Para um canal onde ninguém deve poder trocar o agente que responde - nem temporária nem permanentemente - define `agent_switch_locked: true` na ligação. Recusa logo o `/agent NOME`, mesmo para um formador, além do `switch_agent` e das ações `bind_topic`/`unbind_topic` do `manage_channel`, em qualquer conversa dessa ligação. O `/agent` sem argumento (estado), `/mention`, `/model` e `/new` continuam a funcionar normalmente. Define com `--agent-switch-locked` no `mix pepe gateway whatsapp add` / `discord add`, ou diretamente no `config.json`.

## Mudar de modelo

Os comandos `/model` e `/models` permitem ver ou trocar o modelo de IA que responde, mas só funcionam numa ligação em modo `admin` com `commands` ativado (vê a comparação de modos em [Canais](../channels/)); em `support`, são tratados como texto simples. O `/models` lista os modelos disponíveis para o projeto da ligação; o `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Mudar **globalmente**, para todos com quem a ligação fala, fica reservado aos **formadores** (a mesma lista de confiança que controla a memória); qualquer outra pessoa numa conversa permitida só consegue mudar a sua própria conversa. Define `model_switch_locked: true` na ligação para desligar isto por completo para quem não é formador. É o mesmo mecanismo usado pelo WhatsApp; a versão do Telegram acrescenta apenas um seletor com botões em vez de comandos escritos.

## Aprovar ferramentas de risco na conversa

Por predefinição, um canal por webhook não tem ninguém a quem perguntar, pelo que uma ferramenta de risco que não esteja no `auto_approve` do agente é recusada e fica guardada para um operador aprovar pela linha de comandos (`mix pepe approvals`). Para que as pessoas da conversa decidam ali mesmo, indica os **trainers** na ligação: uma lista explícita, ou `["*"]` para todos os da conversa. Assim, quando o agente quer fazer algo arriscado, pergunta na própria conversa, mostra o comando verdadeiro e espera uma resposta escrita:

```text
Reply with: allow / allow all / allow session / deny
```

Só conta a resposta exata de um trainer, e ela não é passada ao agente como mensagem. A resposta de qualquer outra pessoa, ou uma frase mais longa que contenha "allow", é apenas uma mensagem. As duas respostas mais abrangentes ("permitir tudo na sessão" e "sempre") não podem ser escritas aqui; usa uma superfície com botões para essas. Se ninguém responder em cinco minutos, conta como um não, e o agente é avisado de que ninguém respondeu, e não de que foi recusado.

Sem trainers indicados, nada muda: só corre o que o agente já tem pré-aprovado.

## Por baixo do capô: o contrato do fornecedor

Cada canal por webhook não passa de um pequeno módulo que implementa o mesmo contrato, o que garante que todos se comportam de forma consistente, e faz com que uma plataforma nova seja apenas mais um módulo, nunca uma rota nova. Os callbacks são:

- `name` e `label`: o segmento de URL do fornecedor e o seu nome legível.
- `config_schema`: os campos que o painel apresenta para configurar uma ligação.
- `verify`: responde ao aperto de mão de verificação num `GET`.
- `authenticate`: verifica a assinatura de um `POST` de entrada contra o segredo da ligação e o corpo bruto do pedido; um pedido que falhe é simplesmente descartado.
- `parse`: normaliza o payload da plataforma em zero ou mais mensagens simples, ignorando atualizações de estado e confirmações de entrega.
- `respond` (opcional): produz uma resposta síncrona quando o protocolo a exige antes de qualquer trabalho do agente, como o desafio `url_verification` do Slack ou o ping com confirmação adiada do Discord.
- `deliver`: envia uma resposta em texto de volta ao remetente.
- `deliver_file` (opcional): envia um ficheiro como anexo.

Um plugin que implemente este contrato regista-se automaticamente como um novo fornecedor sob o seu próprio `name`, alcançável pela mesma rota `/webhooks/...`, sem qualquer ligação extra a fazer.
