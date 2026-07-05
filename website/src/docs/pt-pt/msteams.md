---
title: Microsoft Teams
description: Liga um bot do Microsoft Teams a um agente do Pepe através do Bot Framework.
---

## Microsoft Teams

O Teams usa o Bot Framework. Configura pela configuração guiada (ou pelo
painel):

```bash
pepe setup
```

O `config` de uma ligação contém:

- `app_id`: o id da aplicação (cliente) Microsoft do bot.
- `app_password`: o segredo de cliente. Guarda-o como `${ENV_VAR}`.
- `tenant_id`: o tenant ID do Azure (ou `botframework.com`).

As atividades de entrada chegam como `POST`s. As respostas voltam para o URL
de serviço da atividade com um token de acesso de aplicação gerado a partir
das credenciais de cliente. A menção ao bot é retirada do texto de entrada
antes de o agente o ver. Formato do URL de retorno:

```
https://YOUR_HOST/webhooks/default/msteams/<slug>
```

### Autenticação de entrada

Cada pedido de entrada transporta um token do Bot Framework em
`Authorization: Bearer`, e o Pepe valida-o (assinatura contra as chaves públicas
da Microsoft, emissor e uma audiência igual ao `app_id` do bot) antes de o agente
ver seja o que for. Assim o endpoint aceita `POST`s diretamente da Microsoft, sem
necessidade de um proxy que valide. Se o teu proxy já faz essa verificação, define
`trust_proxy: true` na ligação para saltar a do Pepe.

Vê [Webhooks](../webhooks/) para os campos partilhados por toda a ligação
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como funciona a rota genérica por dentro.

### Mudar de modelo

`/model` e `/models` só disparam numa ligação em modo `admin` com `commands`
ativado; no `support`, são texto simples. `/models` lista os modelos
disponíveis para o projeto desta ligação; `/model` mostra o atual, ou muda-o:

```text
/model openrouter               # pergunta se muda só este chat ou todos
/model openrouter session       # muda só para esta conversa
/model openrouter global        # muda para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode mudar a sua própria sessão;
mudá-lo **globalmente** está reservado a **formadores**, a mesma lista que
rege a memória. Define `model_switch_locked: true` na ligação para desativar
por completo a mudança de modelo para quem não é formador.
