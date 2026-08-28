---
title: Sessões
description: Memória de conversa guardada no próprio servidor, disponível por HTTP e WebSocket.
---

## Sessões: com estado ou sem estado

Por padrão a API é **sem estado**: cada requisição precisa trazer o histórico
completo de mensagens, exatamente como na OpenAI. Você manda tudo, o Pepe responde, e
nada fica guardado depois disso.

Só que o Pepe também tem um modo **com estado**, algo que a maioria dos servidores
compatíveis com OpenAI não oferece. Basta anexar um id de sessão e o próprio servidor
passa a guardar a conversa por você: nas chamadas seguintes, você manda só a mensagem
mais recente, o Pepe a encaixa no histórico já guardado, roda o agente e memoriza o
resultado de novo. É bem prático para interfaces de chat e bots de mensageria, onde
reenviar a transcrição inteira a cada mensagem seria um desperdício.

## CLI ou API

O `pepe run` é sempre avulso: não aceita `session_id` e esquece o comando anterior
assim que termina. Se você quer manter contexto direto no terminal, use o console:

```bash
pepe chat assistant --session minha-sessao
```

Já a API HTTP monta a chave de sessão a partir de **dois campos que se combinam entre
si**.

- **`user`** identifica *quem* está falando. É o campo padrão da OpenAI, então qualquer SDK oficial já ganha memória no servidor sem precisar sair do formato que já conhece. Comece por ele.
- **`session_id`**, seja no corpo JSON ou num cabeçalho `x-session-id`, identifica *qual conversa* daquela pessoa. Use quando uma mesma pessoa pode manter várias conversas em paralelo.

A combinação dos dois funciona assim:

| Enviado | Chave de sessão |
| --- | --- |
| só `user` | `user` |
| só `session_id` | `session_id` |
| os dois | `user:session_id` (conversas independentes por pessoa) |
| os dois, com o mesmo valor | vira uma chave só |
| nenhum dos dois (ou em branco) | sem estado |

No WhatsApp, por exemplo, dá para passar `user` como o número de telefone e
`session_id` como o id de uma conversa específica, deixando cada conversa de cada
contato isolada das demais.

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

No modo com estado a resposta traz de volta o `session_id` usado, então basta você
reenviá-lo na próxima chamada. Sessões com estado também funcionam com streaming,
bastando acrescentar `"stream": true`.

### Recuperando de um reinício

Se o Pepe cair no meio de um turno, seja por um deploy ou por um crash, com a
persistência de sessões ligada, a conversa interrompida não fica simplesmente
perdida. Na subida seguinte, o Pepe detecta qualquer sessão cujo último turno não
chegou a terminar, roda esse turno de novo internamente como uma continuação, e
entrega a resposta exatamente onde a conversa estava acontecendo, seja Telegram,
painel, ou qualquer outro canal de origem. A mensagem interrompida acaba respondida em
vez de simplesmente sumir no meio do caminho. Isso vale só para sessões persistidas
(`serve`/`gateway`); uma chamada avulsa de `pepe run` não entra nessa recuperação.

<div class="note"><strong>Isolamento entre projetos.</strong> Internamente, toda chave de sessão carrega o namespace do projeto. Isso quer dizer que o mesmo id de sessão, usado sob dois tokens de projetos diferentes, nunca leva à mesma conversa, então um projeto jamais consegue ler a sessão de outro.</div>

Para voltar ao modo sem estado, basta omitir as três fontes de id e enviar você mesmo
o array completo de `messages`, o comportamento padrão da OpenAI.
