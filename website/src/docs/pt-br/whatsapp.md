---
title: WhatsApp
description: Conecte webhooks da WhatsApp Cloud API a agentes do Pepe.
---

## WhatsApp

O WhatsApp usa a Cloud API da Meta. Ele tem uma linha de comando dedicada por ser
o canal por webhook mais comum. Adicione uma conexão:

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
  aperto de mão de assinatura. Se você omitir a opção, o slug é usado.

Se você deixar de fora `--access-token` ou `--app-secret`, a linha de comando
grava uma referência de espaço reservado derivada do slug (por exemplo
`${WA_TOKEN_SUPPORT}`), para você preencher o valor real no seu ambiente depois.
O comando imprime a URL de retorno e o token de verificação. Cole os dois na
configuração de webhook do app da Meta:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gerencie conexões:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

As outras opções do `whatsapp add` são `--company`, `--trainers`, `--ttl-min`,
`--ephemeral` e `--commands`, que correspondem aos campos por conexão descritos
acima. O painel adiciona e edita conexões do WhatsApp pela mesma seção Channels.

<div class="note"><strong>Regra das 24 horas.</strong> A Meta só permite
respostas em formato livre dentro de 24 horas da última mensagem do usuário. O
suporte reativo se encaixa nisso de forma natural. Mensagens proativas fora da
janela precisam de modelos pré-aprovados, que este canal não envia.</div>
