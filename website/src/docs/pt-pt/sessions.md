---
title: Sessões
description: Usa memória de conversa no servidor por HTTP e WebSocket.
---

## Sessões: com estado vs sem estado

Por predefinição, a API é **sem estado**: cada pedido tem de levar o histórico
completo de mensagens, exatamente como na OpenAI. Envias tudo, o Pepe responde e
nada fica lembrado.

O Pepe também oferece um modo **com estado**. Anexa um id de sessão e o servidor
guarda a conversa por ti. Nas chamadas seguintes envias apenas a mensagem nova; o
Pepe junta-a ao histórico guardado, executa o agente e lembra-se do resultado.

## CLI vs API

`pepe run` é sempre avulso: não aceita `session_id` e não se lembra do comando
anterior. Para manter contexto no terminal, usa a consola:

```bash
pepe chat assistant --session minha-sessao
```

A API HTTP usa `session_id`, `user` ou `x-session-id`.

Podes passar o id de sessão de três formas. O Pepe verifica-as por esta ordem:

1. Um campo `session_id` no corpo JSON.
2. O campo padrão da OpenAI `user` no corpo JSON.
3. Um cabeçalho HTTP `x-session-id`.

```bash
# Turno 1: só a mensagem nova é necessária; o servidor guarda o histórico.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "session_id": "user-42",
    "messages": [{"role": "user", "content": "O meu nome é Ada."}]
  }'

# Turno 2: mesmo id de sessão, só a pergunta nova. O agente lembra-se de "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "session_id": "user-42",
    "messages": [{"role": "user", "content": "Qual é o meu nome?"}]
  }'
```

No modo com estado, a resposta inclui o `session_id` usado para poderes devolvê-lo
na próxima chamada. Sessões com estado também funcionam com streaming; basta
adicionar `"stream": true`.

### Recuperação depois de um reinício

Se o Pepe cair a meio de um turno (um deploy, uma falha) com a persistência de
sessões activada, a conversa interrompida não fica simplesmente perdida. No
arranque seguinte, o Pepe deteta qualquer sessão cujo último turno não terminou,
reproduz-o como um seguimento interno e entrega a resposta onde a conversa
estava a decorrer - Telegram, o painel, seja qual for o canal - para que uma
mensagem interrompida ainda receba resposta em vez de desaparecer em silêncio.
Isto só se aplica a sessões persistidas (`serve`/`gateway`), não a chamadas
avulsas de `pepe run`.

Para voltar ao modo sem estado, omite as três fontes de id e envia o array
completo de `messages`.
