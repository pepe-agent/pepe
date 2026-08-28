---
title: Discord
description: Como responder a comandos de barra no teu servidor de Discord através de um agente do Pepe.
---

## Discord

No Discord, as pessoas falam com o agente através de um comando de barra, por exemplo
`/ask`. O Discord entrega esses comandos pelo seu endpoint de Interactions, o que
encaixa melhor no gateway de webhook do Pepe do que numa ligação persistente. A
configuração faz-se pelo assistente guiado (ou pelo painel):

```bash
pepe setup
```

O `config` de uma ligação guarda:

- `public_key`: a chave pública da aplicação (em hex), exigida para verificar a
  assinatura Ed25519.
- `application_id`: usado para publicar a resposta de seguimento.

Na aplicação do Discord, aponta "Interactions Endpoint URL" para o URL da ligação, e
acrescenta um comando de barra com uma opção de texto, por exemplo `/ask prompt:...`. O
Discord exige uma confirmação dentro de três segundos, por isso o Pepe responde primeiro
com uma resposta diferida, e só publica a resposta real como seguimento assim que o
agente terminar. O formato do URL de retorno é:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Os campos partilhados por qualquer ligação (`agent`, `mode`, `trainers`,
`session_ttl_min`, `ephemeral`, `commands`) e o funcionamento interno da rota genérica
estão descritos em [Webhooks](../webhooks/).

### Trocar de modelo

Os comandos `/model` e `/models` deixam qualquer pessoa ver ou mudar o modelo de IA que
lhe responde. No Discord chegam ao Pepe através do comando que já tens registado (o
`/ask` acima): tudo o que escreveres na opção `prompt:` é a mensagem que o Pepe recebe.
Só funcionam numa ligação em modo `admin` com `commands` ativado; em modo `support`
passam a ser tratados como texto normal. O `/models` lista os modelos disponíveis para o
projeto dessa ligação, e o `/model` mostra qual está ativo ou muda para outro:

```text
/model openrouter               # pergunta se a troca é só deste chat ou de todos
/model openrouter session       # troca só nesta conversa
/model openrouter global        # troca para todas as conversas desta ligação
```

Qualquer pessoa numa conversa permitida pode trocar o modelo da sua própria conversa.
Trocá-lo **globalmente**, afetando todas as conversas dessa ligação, fica reservado aos
**formadores**, a mesma lista de confiança que já controla a memória. Define
`model_switch_locked: true` na ligação para desligar por completo essa troca de modelo a
quem não for formador.
