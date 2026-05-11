---
title: API HTTP
description: Chama o Pepe pela API Chat Completions compatível com OpenAI.
---

O Pepe disponibiliza os seus agentes através de uma API HTTP que fala o protocolo Chat Completions da OpenAI. Qualquer ferramenta ou SDK capaz de comunicar com a OpenAI consegue comunicar com o Pepe sem alterar uma linha de código: aponta o respetivo `base_url` para o teu servidor Pepe e utiliza o nome de um agente onde normalmente colocarias um id de modelo. Também podes chamar o endpoint com pedidos HTTP diretos a partir dos teus próprios projetos, sites, backends, jobs ou integrações; usar um SDK de LLM é conveniente, mas não obrigatório. Existe também um WebSocket para streaming em direto, token a token, com visibilidade das chamadas de ferramenta.

As duas superfícies cobrem duas necessidades. A API HTTP é a escolha por omissão para trabalho de pedido/resposta e de servidor a servidor. O WebSocket destina-se a interfaces interativas em que o utilizador quer renderizar as chamadas de ferramenta e o texto em streaming à medida que acontecem.

## Uma primeira requisição

Inicia o servidor e depois envia uma chat completion. Isto funciona de imediato, sem autenticação (consulta [Autenticação](../auth/#autenticação-e-tokens) para o trancar):

```bash
pepe serve --port 4000
```

Estás a correr o Pepe a partir do código-fonte em vez do binário instalado? O `PHX_SERVER=true mix phx.server` serve exatamente o mesmo endpoint.

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "olá"}]
  }'
```

**JavaScript**

```javascript
const response = await fetch("http://localhost:4000/v1/chat/completions", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: "assistant",
    messages: [{ role: "user", content: "olá" }]
  })
});

const data = await response.json();
console.log(data.choices[0].message.content);
```

**Python**

```python
import requests

response = requests.post(
    "http://localhost:4000/v1/chat/completions",
    json={
        "model": "assistant",
        "messages": [{"role": "user", "content": "olá"}],
    },
)

data = response.json()
print(data["choices"][0]["message"]["content"])
```

**PHP**

```php
$ch = curl_init("http://localhost:4000/v1/chat/completions");
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => ["content-type: application/json"],
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode([
        "model" => "assistant",
        "messages" => [["role" => "user", "content" => "olá"]],
    ]),
]);

$data = json_decode(curl_exec($ch), true);
echo $data["choices"][0]["message"]["content"];
```

**Elixir (usando Req)**

```elixir
Req.post!("http://localhost:4000/v1/chat/completions",
  json: %{
    model: "assistant",
    messages: [%{role: "user", content: "olá"}]
  }
).body["choices"]
|> hd()
|> get_in(["message", "content"])
|> IO.puts()
```

A resposta é um objeto padrão de chat completion da OpenAI:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion",
  "created": 1751800000,
  "model": "assistant",
  "choices": [
    {
      "index": 0,
      "message": { "role": "assistant", "content": "Hi! How can I help?" },
      "finish_reason": "stop"
    }
  ]
}
```

O `pepe serve` corre em primeiro plano. Para um deploy a sério, vê [Painel](../dashboard/#manter-em-execução) para o instalar como serviço persistente em segundo plano.

## Endpoints

São dois:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/root scope, raw model connections)
```

Ambos ficam sob `/v1`, pelo que um cliente configurado com `base_url = http://HOST:PORT/v1` encontra-os exatamente onde um cliente da OpenAI espera.

## O campo "model" seleciona um agente

Esta é a ideia que faz todo o resto encaixar. O campo `model` de um pedido de chat não nomeia um modelo de linguagem puro. Nomeia um **agente** do Pepe. Quando o utilizador envia `"model": "assistant"`, o Pepe executa o agente chamado `assistant`, com o prompt de sistema desse agente e o próprio conjunto de ferramentas dele. O agente executa o ciclo completo de chamadas de ferramenta internamente (chama o modelo, executa as chamadas de ferramenta, devolve os resultados, repete) e retorna uma única resposta final no formato habitual de uma completion.

A resolução do campo `model` acontece por esta ordem:

1. Se o nome corresponder a um agente, esse agente é executado.
2. Se nenhum agente corresponder mas o nome corresponder a uma ligação de modelo pura, o Pepe embrulha-a num agente mínimo de passagem direta (sem ferramentas, um único turno) e chama esse modelo diretamente. Esta alternativa só está disponível no âmbito aberto ou raiz (consulta [Âmbitos de token](../auth/#âmbitos-de-token)).
3. Se nenhum corresponder, o agente por omissão é executado.

<div class="note"><strong>Conclusão prática.</strong> O conjunto de "modelos" que um cliente pode escolher é o teu conjunto de agentes. Dá a um agente um nome descritivo, liga as ferramentas dele uma vez e todos os clientes compatíveis com OpenAI passam a vê-lo como um modelo selecionável.</div>

## Chat completions

### Sem streaming

Envia `messages` no formato da OpenAI. Podes incluir uma mensagem `system`; se a omitires, o próprio prompt de sistema do agente é utilizado automaticamente.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [
      {"role": "user", "content": "Summarize the README in one sentence."}
    ]
  }'
```

### Streaming (Server-Sent Events)

Define `"stream": true` para receber a resposta à medida que é gerada. O formato no fio é idêntico ao streaming da OpenAI: uma sequência de linhas `data:`, cada uma transportando um objeto `chat.completion.chunk`, terminada por `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento tem este aspeto, com o texto incremental em `choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

O fragmento final transporta um delta vazio e `"finish_reason": "stop"`, seguido da linha sentinela `data: [DONE]`. Como isto coincide com a OpenAI byte a byte, qualquer cliente de streaming da OpenAI o interpreta sem alterações.

## Sessões com estado

Por predefinição o endpoint é sem estado: envias o array `messages` completo em cada chamada, exatamente como farias à OpenAI. Em alternativa, passa um id de sessão e o servidor guarda a conversa inteira por ti, para que cada chamada seguinte só tenha de transportar a nova mensagem do utilizador.

Dois campos alimentam a chave da sessão, e compõem-se entre si:

* `"user": "abc"` diz **quem** está a falar. É o campo padrão da OpenAI, por isso um SDK comum da OpenAI mantém uma conversa sem qualquer campo específico do Pepe.
* `"session_id": "xyz"`, no corpo JSON ou como cabeçalho `X-Session-Id`, diz **qual** conversa dessa pessoa.

| Enviado | Chave da sessão |
| --- | --- |
| só `user` | `abc` |
| só `session_id` | `xyz` |
| ambos | `abc:xyz` (threads independentes por pessoa) |
| ambos, com o mesmo valor | reduzido a um só |
| nenhum, ou em branco | sem estado |

Assim, no WhatsApp podes passar o `user` como o número de telefone e o `session_id` como um id de thread, e cada thread de cada contacto torna-se a sua própria conversa. Uma cadeia vazia (`""`) em qualquer um dos campos é tratada como sem estado.

```bash
# Turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"o meu nome é John Doe"}]}'

# Turno 2, mesmo "user". O servidor lembra-se do turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"qual é o meu nome?"}]}'
```

Cada sessão é o seu próprio processo supervisionado, com a chave `api:<id>`. O streaming também funciona com sessões. O WebSocket e o Telegram têm estado por natureza, por ligação e por id de conversa respetivamente, por isso não precisam de nada disto. Vê [Sessões](../sessions/) para o quadro completo, incluindo o que acontece a um turno inacabado quando o Pepe reinicia.

## Erros

Os erros regressam no formato de erro da OpenAI (um objeto `error` de nível superior com uma `message`), pelo que o tratamento de erros existente funciona. Os códigos de estado:

* `401` quando um token é exigido mas está ausente ou inválido.
* `403` quando nomeias um agente que existe mas está fora do âmbito do teu token.
* `400` quando o campo `model` não resolve para nenhum agente nem nenhum modelo.
* `502` quando o agente ou uma sessão com estado falha durante a execução.

O `401` da camada de autenticação transporta o código `invalid_api_key` da OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Os erros de âmbito e resolução (`400`, `403`, `502`) usam um tipo `pepe_error`:

```json
{
  "error": {
    "message": "agent not accessible with this token",
    "type": "pepe_error"
  }
}
```

## Listar modelos

```bash
curl http://localhost:4000/v1/models \
  -H 'authorization: Bearer pepe_your_token_here'
```

```json
{
  "object": "list",
  "data": [
    { "id": "assistant", "object": "model", "created": 0, "owned_by": "pepe:agent" },
    { "id": "support",   "object": "model", "created": 0, "owned_by": "pepe:agent" }
  ]
}
```

Os agentes são etiquetados como `pepe:agent`. No âmbito aberto ou raiz, as ligações de modelo puras também aparecem, etiquetadas como `pepe:model`. Como isto é uma lista de modelos padrão, as ferramentas da OpenAI que oferecem um seletor de modelo preenchem-no com os teus agentes.
