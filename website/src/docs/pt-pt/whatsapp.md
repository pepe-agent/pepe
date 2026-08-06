---
title: WhatsApp
description: Põe um agente do Pepe atrás do teu número de WhatsApp, usando a Cloud API da Meta.
---

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Ao contrário do Telegram, em que é o
próprio Pepe que vai buscar as mensagens, o WhatsApp **entrega** cada mensagem
recebida num endereço no teu servidor, por isso o Pepe precisa de estar
acessível pela internet. Cada ligação recebe o seu próprio URL na rota de
entrada do Pepe:

```
/webhooks/:project/:provider/:slug        ex.:  /webhooks/acme/whatsapp/support
```

O segmento `:project` é `default` quando não crias outros projetos. O próprio
Pepe responde ao aperto de mão de verificação da Meta nesse URL, e cada
mensagem recebida tem a assinatura `X-Hub-Signature-256` verificada contra o
app secret antes de o agente correr, por isso um pedido forjado nunca chega ao
agente. A resposta volta pela Graph API. O `pepe serve` serve esta rota, por
isso não há qualquer processo extra a executar.

Podes manter tantas ligações quantas quiseres, cada uma associada ao seu próprio
agente. É a mesma ideia de executar vários bots do Telegram.

O WhatsApp tem uma linha de comandos dedicada por ser o canal por webhook mais
comum. Adiciona uma ligação:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais da ligação (guardadas dentro do respetivo `config`):

- `phone_number_id`: o id do ponto de envio, proveniente da aplicação da Meta.
- `access_token`: o token bearer da Graph API. Guarda-o como `${ENV_VAR}`.
- `app_secret`: verifica o `X-Hub-Signature-256` de entrada. Guarda-o como
  `${ENV_VAR}`.
- `verify_token`: qualquer texto que escolheres. A Meta devolve-o durante o aperto
  de mão de subscrição. Se omitires a opção, é usado o slug.

Se deixares de fora `--access-token` ou `--app-secret`, a linha de comandos grava
uma referência de marcador derivada do slug (por exemplo `${WA_TOKEN_SUPPORT}` e
`${WA_APP_SECRET_SUPPORT}`), para que preenchas o valor real no teu ambiente mais
tarde. O comando imprime o URL de retorno e o token de verificação. Cola ambos na
configuração de webhook da aplicação da Meta e subscreve o campo `messages`, para
que a Meta entregue de facto as mensagens de entrada:

```
https://YOUR_HOST/webhooks/default/whatsapp/support
```

Gerir ligações:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

O `whatsapp list` imprime cada ligação com o respetivo URL de retorno. As outras
opções do `whatsapp add` são `--project`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, que correspondem aos campos por ligação descritos
acima. O painel adiciona e edita ligações do WhatsApp pela mesma secção Channels.

### Do lado da Meta

Uma vez por número, na tua aplicação da Meta:

1. Cria uma aplicação e adiciona-lhe o produto WhatsApp.
2. Toma nota do `phone_number_id` do número que estás a ligar.
3. Gera um token de acesso permanente e coloca-o no teu ambiente como
   `${WA_TOKEN_<SLUG>}`.
4. Copia o App Secret e coloca-o no teu ambiente como `${WA_APP_SECRET_<SLUG>}`.
5. Aponta a Callback URL para o slug da tua ligação, indica o token de verificação
   e subscreve o campo `messages`.

### Os dois modos

O `--mode` da ligação decide quanto do Pepe é exposto. A comparação completa está
em [Canais](../channels/); para um número de WhatsApp, resume-se a isto:

| | **admin** (o teu) | **support** (virado para o cliente) |
|---|---|---|
| Comandos de barra | Ligados (`/new` reinicia) | Desligados, tratados como texto simples |
| Quem pode falar | `allowed_numbers`, o teu próprio número | Qualquer pessoa |
| Aprende? (`trainers`) | Tu és formador | `[]`, por isso nunca aprende com um cliente |
| Ferramentas do agente | Completas | Mantém-nas restringidas: só ferramentas seguras, já que não há um humano para aprovar uma ação arriscada |
| Sessão | Mantida | Efémera, mais um TTL de inatividade |

### A sessão

A sessão é indexada como `whatsapp:<agent>:<phone>`. É a conversa do agente com
aquele cliente em concreto, isolada por projeto através do handle do agente. Duas
coisas põem-lhe fim:

- O agente invoca a ferramenta **`end_session`** quando a troca termina, o que
  limpa o contexto para que a mensagem seguinte do cliente comece do zero.
- O **TTL de inatividade** (`--ttl-min`, ausente significa nunca) despeja uma
  conversa que ficou parada.

Passar uma conversa a um especialista não precisa de maquinaria extra: o agente
limita-se a invocar `send_to_agent`. Vê [Encaminhamento](../routing/).

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite respostas
em formato livre dentro de 24 horas da última mensagem do utilizador. O suporte
reativo encaixa-se nisto de forma natural. As mensagens proativas fora da janela
precisam de modelos pré-aprovados, que este canal não envia.</div>

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` (vê a comparação de
modos acima); no `support`, são texto simples como qualquer outro comando de
barra. `/models` lista os modelos disponíveis para o projeto dessa ligação;
`/model` mostra o que está ativo, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** está reservado a **formadores**, a mesma lista que
rege a memória. Define `model_switch_locked: true` na ligação para desativar
por completo a mudança de modelo para quem não é formador. O WhatsApp não tem
um seletor com botões como o do Telegram; aqui é só escrito.
