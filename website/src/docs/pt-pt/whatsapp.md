---
title: WhatsApp
description: Liga webhooks da WhatsApp Cloud API a agentes do Pepe.
---

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Tem uma linha de comandos dedicada por ser o
canal por webhook mais comum. Adiciona uma ligação:

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
uma referência de marcador derivada do slug (por exemplo `${WA_TOKEN_SUPPORT}`),
para que preenchas o valor real no teu ambiente mais tarde. O comando imprime o URL
de retorno e o token de verificação. Cola ambos na configuração de webhook da
aplicação da Meta:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gerir ligações:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

As outras opções do `whatsapp add` são `--company`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, que correspondem aos campos por ligação descritos
acima. O painel adiciona e edita ligações do WhatsApp pela mesma secção Channels.

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite respostas
em formato livre dentro de 24 horas da última mensagem do utilizador. O suporte
reativo encaixa-se nisto de forma natural. As mensagens proativas fora da janela
precisam de modelos pré-aprovados, que este canal não envia.</div>

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` (vê a
comparação de modos em [Channels](../channels/)); no `support`, são texto
simples como qualquer outro comando de barra. `/models` lista os modelos
disponíveis para a empresa dessa ligação; `/model` mostra o que está ativo,
ou muda-o:

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
