---
title: WhatsApp
description: Liga webhooks da WhatsApp Cloud API a agentes do Pepe.
---

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Tem uma linha de comandos dedicada por ser o
canal por webhook mais comum. Adicione uma ligação:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

As credenciais da ligação (guardadas dentro do respectivo `config`):

- `phone_number_id`: o id do ponto de envio, proveniente da aplicação da Meta.
- `access_token`: o token bearer da Graph API. Guarde-o como `${ENV_VAR}`.
- `app_secret`: verifica o `X-Hub-Signature-256` de entrada. Guarde-o como
  `${ENV_VAR}`.
- `verify_token`: qualquer texto que escolher. A Meta devolve-o durante o aperto
  de mão de subscrição. Se omitir a opção, é usado o slug.

Se deixar de fora `--access-token` ou `--app-secret`, a linha de comandos grava
uma referência de marcador derivada do slug (por exemplo `${WA_TOKEN_SUPPORT}`),
para que preencha o valor real no seu ambiente mais tarde. O comando imprime o URL
de retorno e o token de verificação. Cole ambos na configuração de webhook da
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
reactivo encaixa-se nisto de forma natural. As mensagens proactivas fora da janela
precisam de modelos pré-aprovados, que este canal não envia.</div>
