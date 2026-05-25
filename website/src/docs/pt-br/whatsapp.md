---
title: WhatsApp
description: Conecte webhooks da WhatsApp Cloud API a agentes do Pepe.
---

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Diferente do Telegram, que o Pepe consulta
por polling, o WhatsApp **empurra** as mensagens de entrada para um webhook,
então cada conexão ganha sua própria URL na rota de entrada genérica do Pepe:

```
/webhooks/:project/:provider/:slug        ex.:  /webhooks/acme/whatsapp/support
```

Essa rota é uma superfície de webhook genérica, apoiada em um registro de
provedores, e não um encanamento específico do WhatsApp. O segmento `:project` é
`default` quando você não cria projetos adicionais. Um `GET` nessa URL responde ao handshake de
verificação da Meta. Um `POST` é uma mensagem de entrada: o `X-Hub-Signature-256`
dela é verificado contra o app secret, o agente vinculado roda e a resposta volta
pela Graph API. O `pepe serve` serve essa rota, então não há nenhum processo
extra para rodar.

Você pode manter quantas conexões quiser, cada uma vinculada ao seu próprio
agente. É o equivalente por webhook dos vários bots do Telegram.

O WhatsApp tem uma linha de comando dedicada por ser o canal por webhook mais
comum. Adicione uma conexão:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais da conexão (guardadas dentro do `config` dela):

- `phone_number_id`: o id do ponto de envio, vindo do app da Meta.
- `access_token`: o token bearer da Graph API. Guarde como `${ENV_VAR}`.
- `app_secret`: verifica o `X-Hub-Signature-256` de entrada. Guarde como
  `${ENV_VAR}`.
- `verify_token`: qualquer texto que você escolher. A Meta o devolve durante o
  handshake de assinatura. Se você omitir a opção, o slug é usado.

Se você deixar de fora `--access-token` ou `--app-secret`, a linha de comando
grava uma referência de espaço reservado derivada do slug (por exemplo
`${WA_TOKEN_SUPPORT}` e `${WA_APP_SECRET_SUPPORT}`), para você preencher o valor
real no seu ambiente depois. O comando imprime a URL de retorno e o token de
verificação. Cole os dois na configuração de webhook do app da Meta e assine o
campo `messages`, para que a Meta de fato entregue as mensagens de entrada:

```
https://YOUR_HOST/webhooks/default/whatsapp/support
```

Gerencie conexões:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

O `whatsapp list` imprime cada conexão com a URL de retorno dela. As outras
opções do `whatsapp add` são `--project`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, que correspondem aos campos por conexão descritos
acima. O painel adiciona e edita conexões do WhatsApp pela mesma seção Channels.

### Do lado da Meta

Uma vez por número, no seu app da Meta:

1. Crie um app e adicione o produto WhatsApp a ele.
2. Anote o `phone_number_id` do número que você está conectando.
3. Gere um token de acesso permanente e coloque no seu ambiente como
   `${WA_TOKEN_<SLUG>}`.
4. Copie o App Secret e coloque no seu ambiente como `${WA_APP_SECRET_<SLUG>}`.
5. Aponte a Callback URL para o slug da sua conexão, informe o token de
   verificação e assine o campo `messages`.

### Os dois modos

O `--mode` da conexão decide quanto do Pepe ela expõe. A comparação completa está
em [Canais](../channels/); para um número de WhatsApp, ela se resume a isto:

| | **admin** (seu) | **support** (voltado ao cliente) |
|---|---|---|
| Comandos de barra | Ligados (`/new` reinicia) | Desligados, tratados como texto puro |
| Quem pode falar | `allowed_numbers`, o seu próprio número | Qualquer um |
| Aprende? (`trainers`) | Você é treinador | `[]`, então nunca aprende com um cliente |
| Ferramentas do agente | Completas | Mantenha restritas: só ferramentas seguras, já que não há um humano para aprovar uma ação arriscada |
| Sessão | Mantida | Efêmera, mais um TTL de inatividade |

### A sessão

A sessão é indexada como `whatsapp:<agent>:<phone>`. Ela é a conversa do agente
com aquele cliente específico, isolada por projeto através do handle do agente.
Duas coisas a encerram:

- O agente chama a ferramenta **`end_session`** quando a troca termina, o que
  limpa o contexto para que a próxima mensagem do cliente comece do zero.
- O **TTL de inatividade** (`--ttl-min`, ausente significa nunca) despeja uma
  conversa que ficou quieta.

Passar uma conversa para um especialista não exige nenhuma máquina extra: o
agente simplesmente chama `send_to_agent`. Veja [Roteamento](../routing/).

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite
respostas em formato livre dentro de 24 horas da última mensagem do usuário. O
suporte reativo se encaixa nisso de forma natural. Mensagens proativas fora da
janela precisam de templates de mensagem pré-aprovados, que este canal não
envia.</div>

### Trocando de modelo

`/model` e `/models` só disparam numa conexão em modo `admin` (veja a
comparação de modos acima); no `support`, viram texto puro como qualquer outro
comando de barra. `/models` lista os modelos disponíveis para o projeto dessa
conexão; `/model` mostra o que está ativo agora, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar sua própria sessão;
trocar **globalmente** é reservado para **treinadores**, a mesma lista que
controla a memória. Defina `model_switch_locked: true` na conexão para
desativar totalmente a troca de modelo por quem não é treinador. O WhatsApp
não tem um seletor com botões como o do Telegram; aqui é só digitado.
