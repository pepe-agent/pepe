---
title: Sessões
description: Memória de conversa guardada no servidor, disponível por HTTP e por WebSocket.
---

## Sessões: com estado vs sem estado

Por predefinição a API é **sem estado**: cada pedido tem de trazer o histórico
completo de mensagens, exatamente como na OpenAI. Envias tudo, o Pepe responde, e não
fica nada guardado.

Mas o Pepe também oferece um modo **com estado**, que a maioria dos servidores da
OpenAI não tem. Basta anexar um id de sessão para o servidor passar a guardar a
conversa por ti: nas chamadas seguintes envias só a mensagem mais recente, o Pepe
junta-a ao histórico já guardado, corre o agente, e fica com o resultado memorizado.

## CLI vs API

O `pepe run` é sempre avulso: não aceita `session_id` e não se lembra do comando
anterior. Para manter contexto dentro do terminal, usa a consola:

```bash
pepe chat assistant --session minha-sessao
```

Já a API HTTP monta a chave de sessão a partir de **dois campos, que se combinam
entre si**.

- **`user`** identifica *quem* está a falar. É o campo padrão da OpenAI, por isso qualquer SDK oficial já ganha memória no servidor sem sair do formato habitual; é por aqui que deves começar.
- **`session_id`**, no corpo JSON ou num cabeçalho `x-session-id`, identifica *qual* conversa dessa pessoa. Usa-o quando a mesma pessoa consegue ter várias conversas separadas.

Como se combinam:

| Enviado | Chave de sessão |
| --- | --- |
| só `user` | `user` |
| só `session_id` | `session_id` |
| os dois | `user:session_id` (conversas independentes por pessoa) |
| os dois, mesmo valor | fica só uma |
| nenhum (ou vazio) | sem estado |

Assim, no WhatsApp podes passar `user` como o número de telemóvel e `session_id` como
um id de conversa, e cada conversa de cada contacto fica isolada das restantes.

```bash
# Turno 1: só a mensagem nova é precisa; o servidor guarda o histórico.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "O meu nome é Ada."}]
  }'

# Turno 2: mesmo id de sessão, só a pergunta seguinte. O agente lembra-se de "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "Qual é o meu nome?"}]
  }'
```

No modo com estado a resposta traz de volta o `session_id` usado, para o devolveres na
chamada seguinte. Sessões com estado também funcionam com streaming, basta acrescentar
`"stream": true`.

### Recuperar depois de um reinício

Se o Pepe cair a meio de um turno (um deploy, uma falha) com a persistência de sessões
ligada, a conversa interrompida não fica simplesmente perdida. No arranque seguinte, o
Pepe repara em qualquer sessão cujo último turno nunca chegou a terminar, reproduz-o
como um seguimento interno, e entrega a resposta onde a conversa estava mesmo a
decorrer, Telegram, o painel, ou seja qual for o canal de onde veio. A mensagem
interrompida acaba por receber resposta, em vez de desaparecer em silêncio. Isto só se
aplica a sessões persistidas (`serve`/`gateway`), nunca a chamadas avulsas de `pepe
run`.

<div class="note"><strong>Isolamento entre inquilinos.</strong> As chaves de sessão ficam internamente organizadas por projeto. O mesmo id de sessão usado sob dois tokens diferentes (dois projetos diferentes) nunca chega à mesma conversa, por isso um inquilino nunca consegue ler a sessão de outro.</div>

Para voltar ao modo sem estado, basta omitir as três fontes de id e enviar tu mesmo o
array completo de `messages`.
