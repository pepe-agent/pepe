---
title: Microsoft Teams
description: Coloca um agente do Pepe no Microsoft Teams para a tua equipa falar com ele sem sair de lá.
---

## Microsoft Teams

Ligar o Teams deixa a tua equipa conversar com o agente no sítio onde já trabalha. O Teams fala com bots através do Bot Framework da Microsoft; a ligação configura-se pelo assistente guiado (ou pelo painel):

```bash
pepe setup
```

O `config` de uma ligação guarda:

- `app_id`: o id da aplicação (cliente) Microsoft do bot.
- `app_password`: o segredo do cliente. Guarda-o como `${ENV_VAR}`.
- `tenant_id`: o id do tenant do Azure (ou `botframework.com`).

As atividades recebidas chegam como pedidos `POST`. As respostas voltam para o URL de serviço indicado nessa atividade, acompanhadas de um token de acesso de aplicação gerado a partir das credenciais de cliente. A menção ao bot é removida do texto antes de o agente sequer o ver. O URL de retorno segue este formato:

```
https://YOUR_HOST/webhooks/default/msteams/<slug>
```

### Autenticar o que entra

Antes de o agente ver seja o que for, o Pepe confirma que cada pedido recebido vem mesmo da Microsoft: todo o pedido traz um token do Bot Framework em `Authorization: Bearer`, e o Pepe valida-o (a assinatura contra as chaves públicas da Microsoft, o emissor, e uma audiência igual ao `app_id` do bot). Isto permite ao endpoint aceitar pedidos `POST` diretamente da Microsoft, sem precisar de um proxy a validar nada. Se o teu proxy já fizer essa verificação, define `trust_proxy: true` na ligação para saltares a do Pepe.

Os campos comuns a qualquer ligação (`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) e o funcionamento interno da rota genérica estão explicados em [Webhooks](../webhooks/).

### Trocar de modelo

Os comandos `/model` e `/models` permitem às pessoas ver ou trocar qual o modelo de IA que lhes responde. Só funcionam numa ligação em modo `admin` com `commands` ativado; em `support`, são tratados como texto normal, sem qualquer efeito especial. O `/models` lista os modelos disponíveis para o projeto desta ligação; o `/model`, sozinho, mostra o modelo atual, e com um argumento troca-o:

```text
/model openrouter               # pergunta se a troca é só para este chat ou para todos
/model openrouter session       # troca só nesta conversa
/model openrouter global        # troca para todos com quem esta ligação fala
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da sua própria conversa. Já trocá-lo **globalmente**, para todos com quem esta ligação fala, está reservado aos **formadores**, a mesma lista de confiança que também controla a memória. Define `model_switch_locked: true` na ligação se quiseres desativar por completo a troca de modelo para quem não é formador.
