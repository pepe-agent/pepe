---
title: Google Chat
description: Põe um agente do Pepe no Google Chat para a tua equipa falar com ele em espaços e mensagens diretas.
---

## Google Chat

Ligar o Google Chat permite que as pessoas falem com o agente nos espaços e
nas mensagens diretas. O Google Chat entrega cada mensagem no URL de retorno
do Pepe; configura a ligação pela configuração guiada (ou pelo painel):

```bash
pepe setup
```

O `config` de uma ligação contém:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas
  respostas. Guarda-o como `${ENV_VAR}` e renova-o por fora.
- `project_number`: o número do projeto Cloud em que a aplicação do Chat
  está registada. Na página de configuração da aplicação do Chat, define
  **Authentication Audience** como **Project Number**. A outra opção (HTTP
  endpoint URL) envia um token com formato diferente, que o Pepe não valida,
  pelo que todas as mensagens recebidas seriam rejeitadas.

Apenas os eventos `MESSAGE` de uma pessoa são atendidos. As respostas são
publicadas de volta no espaço pela Chat REST API. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticação de entrada

O Pepe confirma que cada pedido recebido vem mesmo da Google antes de o
agente ver seja o que for: cada pedido traz um token assinado pela Google no
`Authorization: Bearer`, e o Pepe valida-o (assinatura contra as chaves
publicadas pela Google, emissor e uma audiência igual a `project_number`).
Assim o endpoint aceita `POST`s diretamente da Google, sem precisar de um
proxy que valide. Se o teu proxy já faz essa verificação, define
`trust_proxy: true` na ligação para saltar a do Pepe.

Vê [Webhooks](../webhooks/) para os campos partilhados por toda a ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como funciona a rota genérica por dentro.

### Mudar de modelo

Os comandos `/model` e `/models` permitem ver ou mudar o modelo de IA que
responde. Só funcionam numa ligação em modo `admin` com `commands` ativado;
no `support`, são tratados como texto normal. `/models` lista os modelos
disponíveis para o projeto desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar o modelo da sua própria
conversa. Mudá-lo **globalmente**, para todos com quem esta ligação fala,
está reservado aos **formadores**, a mesma lista de confiança que rege a
memória. Define `model_switch_locked: true` na ligação para desativar por
completo a mudança de modelo para quem não é formador.
