---
title: Microsoft Teams
description: Coloque um agente do Pepe dentro do Microsoft Teams para sua equipe conversar com ele sem sair de lá.
---

## Microsoft Teams

Conectar o Teams deixa sua equipe falar com o agente no mesmo lugar onde ela já trabalha. O Teams conversa com bots pelo Bot Framework da Microsoft, e você configura essa conexão pela configuração guiada (ou pelo painel):

```bash
pepe setup
```

O `config` de uma conexão guarda:

- `app_id`: o id do app (cliente) do bot na Microsoft.
- `app_password`: o segredo do cliente. Guarde como `${ENV_VAR}`.
- `tenant_id`: o id do tenant no Azure (ou `botframework.com`).

As atividades chegam como `POST`s de entrada, e as respostas voltam para a URL de serviço daquela atividade, usando um token de acesso de app gerado a partir das credenciais de cliente. A menção ao bot é removida do texto antes mesmo de o agente vê-lo. O formato da URL de retorno é:

```
https://YOUR_HOST/webhooks/default/msteams/<slug>
```

### Autenticação de entrada

Antes de deixar o agente ver qualquer coisa, o Pepe confirma que a requisição realmente veio da Microsoft: cada requisição chega com um token do Bot Framework em `Authorization: Bearer`, e o Pepe o valida conferindo a assinatura contra as chaves públicas da Microsoft, o emissor, e uma audiência que precisa bater com o `app_id` do bot. Com isso o endpoint aceita `POST`s direto da Microsoft, sem precisar de um proxy validando nada no meio do caminho. Se o seu proxy já faz essa checagem, defina `trust_proxy: true` na conexão para pular a do Pepe.

Os campos que toda conexão compartilha (`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e como a rota genérica funciona por trás estão em [Webhooks](../webhooks/).

### Trocando de modelo

Os comandos `/model` e `/models` deixam as pessoas conferirem ou trocarem qual modelo de IA está respondendo. Só funcionam numa conexão em modo `admin` com `commands` habilitado; no modo `support`, viram texto comum e nada mais. `/models` lista os modelos disponíveis para o projeto dessa conexão; `/model` mostra o modelo atual, ou troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todo mundo
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todo mundo com quem essa conexão fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da própria conversa. Já trocar **globalmente**, para todos com quem essa conexão fala, fica reservado aos **treinadores**, a mesma lista de confiança que controla a memória. Defina `model_switch_locked: true` na conexão para desligar de vez a troca de modelo por quem não é treinador.
