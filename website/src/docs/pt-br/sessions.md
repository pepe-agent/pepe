---
title: Sessões
description: Use memória de conversa no servidor por HTTP e WebSocket.
---

## Sessões: com estado vs sem estado

Por padrão, a API é **sem estado**: cada requisição precisa carregar o histórico completo de mensagens, exatamente como na OpenAI. Você manda tudo, o Pepe responde, nada é lembrado.

O Pepe também oferece um modo **com estado** que a maioria dos servidores da OpenAI não tem. Anexe um id de sessão e o servidor guarda a conversa para você. Em cada chamada seguinte você envia apenas a mensagem mais nova do usuário; o Pepe a acrescenta ao histórico guardado, executa o agente e lembra do resultado. Isso é conveniente para interfaces de chat e bots de mensageria em que você não quer enviar a transcrição inteira toda vez.

## CLI vs API

`pepe run` é sempre avulso: ele não aceita `session_id` e não lembra do comando
anterior. Para manter contexto no terminal, use o console:

```bash
pepe chat assistant --session minha-sessao
```

A API HTTP monta a chave de sessão a partir de **dois campos, e eles se combinam**.

- **`user`** — o campo padrão da OpenAI, então qualquer SDK oficial da OpenAI ganha memória no servidor sem sair do formato padrão. É por ele que você deve começar. Responde *quem* está falando.
- **`session_id`** no corpo JSON (ou um cabeçalho `x-session-id`) — *qual conversa* daquela pessoa. Use quando a mesma pessoa pode ter várias conversas separadas.

Como eles se combinam:

| Enviado | Chave de sessão |
| --- | --- |
| só `user` | `user` |
| só `session_id` | `session_id` |
| os dois | `user:session_id` (conversas independentes por pessoa) |
| os dois, mesmo valor | vira uma só |
| nenhum (ou vazio) | sem estado |

Assim, no WhatsApp você passa `user` = o telefone e `session_id` = um id de conversa, e cada conversa de cada contato é independente, isolada das outras.

```bash
# Turno 1: só a mensagem nova é necessária; o servidor guarda o histórico.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "Meu nome é Ada."}]
  }'

# Turno 2: mesmo id de sessão, só a pergunta nova. O agente lembra de "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "Qual é meu nome?"}]
  }'
```

No modo com estado a resposta inclui o `session_id` que você usou, para que você possa devolvê-lo na próxima chamada. Sessões com estado também funcionam com streaming; basta adicionar `"stream": true`.

### Recuperação depois de um reinício

Se o Pepe cair no meio de um turno (um deploy, um crash) com a persistência de sessões ativada, a conversa interrompida não é simplesmente perdida. Na próxima subida, o Pepe detecta qualquer sessão cujo último turno não terminou, reproduz ele como um acompanhamento interno e entrega a resposta pra onde a conversa estava acontecendo (Telegram, o painel, qualquer que seja o canal), então uma mensagem interrompida ainda recebe resposta em vez de simplesmente sumir. Isso só vale para sessões persistidas (`serve`/`gateway`), não pra chamadas avulsas de `pepe run`.

<div class="note"><strong>Isolamento entre empresas.</strong> As chaves de sessão são internamente delimitadas por empresa. O mesmo id de sessão usado sob dois tokens diferentes (duas empresas diferentes) nunca chega à mesma conversa, de modo que uma empresa nunca consegue ler a sessão de outro.</div>

Para voltar ao modo sem estado, simplesmente omita as três fontes de id e envie você mesmo o array completo de `messages`. Esse é o comportamento comum da OpenAI.
