---
title: Google Chat
description: Coloque um agente do Pepe no Google Chat para a sua equipe conversar com ele em espaços e mensagens diretas.
---

## Google Chat

Ao conectar o Google Chat, qualquer pessoa passa a poder falar com o agente tanto nos espaços quanto nas mensagens diretas. Cada mensagem chega até a URL de retorno do Pepe pelo próprio Google Chat; configure essa conexão pela configuração guiada, ou direto pelo painel:

```bash
pepe setup
```

O `config` de uma conexão traz:

- `access_token`: um token OAuth para a Chat API, usado como bearer nas respostas. Guarde como `${ENV_VAR}` e renove por fora do Pepe.
- `project_number`: o número do projeto no Cloud em que o app do Chat está registrado. Na página de configuração desse app, o **Authentication Audience** precisa estar como **Project Number**. A outra opção (HTTP endpoint URL) envia um token num formato que o Pepe não sabe validar, e aí toda mensagem recebida acabaria rejeitada.

Só eventos `MESSAGE` vindos de uma pessoa de verdade são atendidos. As respostas voltam para o espaço pela Chat REST API. O formato da URL de retorno é este:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticação de entrada

Antes de o agente ver qualquer coisa, o Pepe confere se a requisição realmente veio do Google: cada requisição chega com um token assinado pelo Google no cabeçalho `Authorization: Bearer`, e o Pepe valida esse token contra as chaves públicas do Google, o emissor, e uma audiência que precisa bater com o `project_number`. Com isso, o endpoint aceita `POST`s direto do Google, sem precisar de um proxy fazendo essa checagem por fora. Se o seu próprio proxy já faz essa validação, defina `trust_proxy: true` na conexão para pular a do Pepe.

Os campos que toda conexão compartilha (`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e como a rota genérica funciona por trás disso tudo estão explicados em [Webhooks](../webhooks/).

### Trocando de modelo

Os comandos `/model` e `/models` deixam qualquer pessoa ver, ou trocar, qual modelo de IA está respondendo. Eles só funcionam numa conexão em modo `admin` com `commands` habilitado; no `support`, são tratados como texto comum, sem efeito nenhum. `/models` lista os modelos disponíveis para o projeto daquela conexão; `/model` mostra o atual, ou faz a troca:

```text
/model openrouter               # pergunta se troca só esse chat ou todos
/model openrouter session       # troca só para esta conversa
/model openrouter global        # troca para todos que falam com essa conexão
```

Qualquer pessoa numa conversa autorizada pode trocar o modelo da própria conversa. Já trocar **globalmente**, afetando todo mundo que fala com essa conexão, fica reservado aos **treinadores**, a mesma lista de confiança que controla a memória. Para desativar de vez a troca de modelo por quem não é treinador, defina `model_switch_locked: true` na conexão.
