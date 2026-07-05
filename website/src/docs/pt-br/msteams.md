---
title: Microsoft Teams
description: Conecte um bot do Microsoft Teams a um agente do Pepe pelo Bot Framework.
---

## Microsoft Teams

O Teams usa o Bot Framework. Configure pela configuração guiada (ou pelo
painel):

```bash
pepe setup
```

O `config` de uma conexão contém:

- `app_id`: o id do app (cliente) Microsoft do bot.
- `app_password`: o segredo de cliente. Guarde como `${ENV_VAR}`.
- `tenant_id`: o tenant ID do Azure (ou `botframework.com`).

As atividades de entrada chegam como `POST`s. As respostas voltam para a URL de
serviço da atividade com um token de acesso de app gerado a partir das
credenciais de cliente. A menção ao bot é retirada do texto de entrada antes
de o agente ver. Formato da URL de retorno:

```
https://YOUR_HOST/webhooks/default/msteams/<slug>
```

### Autenticação de entrada

Cada requisição de entrada carrega um token do Bot Framework em
`Authorization: Bearer`, e o Pepe o valida (assinatura contra as chaves públicas
da Microsoft, emissor e uma audiência igual ao `app_id` do bot) antes de o agente
ver qualquer coisa. Assim o endpoint aceita `POST`s direto da Microsoft, sem
precisar de um proxy que valide. Se o seu proxy já faz essa checagem, defina
`trust_proxy: true` na conexão para pular a do Pepe.

Veja [Webhooks](../webhooks/) para os campos compartilhados por toda conexão
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como a rota genérica funciona por baixo dos panos.

### Trocando de modelo

`/model` e `/models` só disparam numa conexão em modo `admin` com `commands`
habilitado; no `support`, viram texto puro. `/models` lista os modelos
disponíveis para o projeto dessa conexão; `/model` mostra o atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar sua própria sessão;
trocar **globalmente** é reservado para **treinadores**, a mesma lista que
controla a memória. Defina `model_switch_locked: true` na conexão para
desativar totalmente a troca de modelo por quem não é treinador.
