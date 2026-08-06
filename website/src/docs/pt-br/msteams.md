---
title: Microsoft Teams
description: Coloque um agente do Pepe no Microsoft Teams para sua equipe conversar com ele por lá.
---

## Microsoft Teams

Conectar o Teams permite que sua equipe converse com o agente onde ela já
trabalha. O Teams fala com bots pelo Bot Framework da Microsoft; configure a
conexão pela configuração guiada (ou pelo painel):

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

O Pepe confere que cada requisição recebida veio mesmo da Microsoft antes de
o agente ver qualquer coisa: cada requisição carrega um token do Bot Framework
em `Authorization: Bearer`, e o Pepe o valida (assinatura contra as chaves
públicas da Microsoft, emissor e uma audiência igual ao `app_id` do bot).
Assim o endpoint aceita `POST`s direto da Microsoft, sem precisar de um proxy
que valide. Se o seu proxy já faz essa checagem, defina `trust_proxy: true`
na conexão para pular a do Pepe.

Veja [Webhooks](../webhooks/) para os campos compartilhados por toda conexão
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e
como a rota genérica funciona por baixo dos panos.

### Trocando de modelo

Os comandos `/model` e `/models` deixam as pessoas ver ou trocar qual modelo
de IA responde a elas. Eles só funcionam numa conexão em modo `admin` com
`commands` habilitado; no `support`, são tratados como texto comum. `/models`
lista os modelos disponíveis para o projeto dessa conexão; `/model` mostra o
atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da própria
conversa. Trocar **globalmente**, para todos com quem essa conexão fala, é
reservado aos **treinadores**, a mesma lista de confiança que controla a
memória. Defina `model_switch_locked: true` na conexão para desativar
totalmente a troca de modelo por quem não é treinador.
