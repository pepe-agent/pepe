---
title: API HTTP
description: Chame o Pepe pela API Chat Completions compatível com OpenAI.
---

O Pepe disponibiliza seus agentes por uma API HTTP que fala o protocolo Chat Completions da OpenAI. Qualquer ferramenta ou SDK capaz de conversar com a OpenAI consegue conversar com o Pepe sem mudar uma linha de código: aponte o `base_url` dela para o seu servidor Pepe e use o nome de um agente onde você normalmente colocaria um id de modelo. Você também pode chamar o endpoint com requisições HTTP diretas a partir dos seus próprios projetos, sites, backends, jobs ou integrações; usar um SDK de LLM é conveniente, mas não obrigatório. Também existe um WebSocket para streaming ao vivo, token a token, com visibilidade das chamadas de ferramenta.

As duas superfícies cobrem necessidades diferentes. A API HTTP é a escolha padrão para trabalho de requisição/resposta e de servidor a servidor. Use o WebSocket para interfaces interativas em que você quer renderizar as chamadas de ferramenta e o texto em streaming conforme eles acontecem.

## Uma primeira requisição

Suba o servidor e então envie uma chat completion. Isso funciona de imediato, sem autenticação (veja [Autenticação](../auth/#autenticação-e-tokens) para trancar tudo):

```bash
pepe serve --port 4000
```

Está rodando o Pepe a partir do código-fonte em vez do binário instalado? O `PHX_SERVER=true mix phx.server` serve exatamente o mesmo endpoint.

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

O `pepe serve` roda em primeiro plano. Para um deploy de verdade, veja [Painel](../dashboard/#mantendo-o-painel-no-ar) e instale-o como serviço persistente em segundo plano.

## Endpoints

São dois:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/root scope, raw model connections)
```

Os dois ficam sob `/v1`, então um cliente configurado com `base_url = http://HOST:PORT/v1` os encontra exatamente onde um cliente da OpenAI espera.

## O campo "model" seleciona um agente

Essa é a ideia que faz todo o resto se encaixar. O campo `model` de uma requisição de chat não nomeia um modelo de linguagem puro. Ele nomeia um **agente** do Pepe. Quando você envia `"model": "assistant"`, o Pepe executa o agente chamado `assistant`, com o prompt de sistema desse agente e o conjunto próprio de ferramentas dele. O agente executa o loop completo de chamadas de ferramenta internamente (chama o modelo, executa as chamadas de ferramenta, devolve os resultados, repete) e retorna uma única resposta final no formato usual de uma completion.

A resolução do campo `model` acontece nesta ordem:

1. Se o nome corresponder a um agente, esse agente é executado.
2. Se nenhum agente corresponder mas o nome corresponder a uma conexão de modelo pura, o Pepe a encapsula em um agente mínimo de passagem direta (sem ferramentas, um único turno) e chama esse modelo diretamente. Essa alternativa só está disponível no escopo aberto ou raiz (veja [Escopos de token](../auth/#escopos-de-token)).
3. Se nenhum corresponder, o agente padrão é executado.

<div class="note"><strong>Conclusão prática.</strong> O conjunto de "modelos" que um cliente pode escolher é o seu conjunto de agentes. Dê a um agente um nome descritivo, conecte as ferramentas dele uma vez e todo cliente compatível com OpenAI o enxerga como um modelo selecionável.</div>

## Chat completions

### Sem streaming

Envie `messages` no formato da OpenAI. Você pode incluir uma mensagem `system`; se você omitir uma, o próprio prompt de sistema do agente é usado automaticamente.

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

Defina `"stream": true` para receber a resposta conforme ela é gerada. O formato transmitido é idêntico ao streaming da OpenAI: uma sequência de linhas `data:`, cada uma carregando um objeto `chat.completion.chunk`, terminada por `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento se parece com isto, com o texto incremental em `choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

O fragmento final carrega um delta vazio e `"finish_reason": "stop"`, seguido da linha sentinela `data: [DONE]`. Como isso bate com a OpenAI byte por byte, qualquer cliente de streaming da OpenAI o interpreta sem mudanças.

## Sessões com estado

Por padrão o endpoint é sem estado: você envia o array `messages` completo a cada chamada, exatamente como faria com a OpenAI. Em vez disso, passe um id de sessão e o servidor guarda a conversa inteira para você, então cada chamada seguinte só precisa carregar a mensagem nova do usuário.

Dois campos alimentam a chave da sessão, e eles se combinam:

* `"user": "abc"` diz **quem** está falando. É o campo padrão da OpenAI, então um SDK comum da OpenAI mantém uma conversa sem nenhum campo específico do Pepe.
* `"session_id": "xyz"`, no corpo JSON ou como cabeçalho `X-Session-Id`, diz **qual** conversa daquela pessoa.

| Enviado | Chave da sessão |
| --- | --- |
| só `user` | `abc` |
| só `session_id` | `xyz` |
| os dois | `abc:xyz` (threads independentes por pessoa) |
| os dois, com o mesmo valor | deduplicado para um só |
| nenhum, ou em branco | sem estado |

Então no WhatsApp você pode passar o `user` como o número de telefone e o `session_id` como um id de thread, e cada thread de cada contato vira a sua própria conversa. Uma string vazia (`""`) em qualquer um dos campos é tratada como sem estado.

```bash
# Turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"meu nome é John Doe"}]}'

# Turno 2, mesmo "user". O servidor lembra do turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"qual é o meu nome?"}]}'
```

Cada sessão é o seu próprio processo supervisionado, com a chave `api:<id>`. O streaming também funciona com sessões. O WebSocket e o Telegram já têm estado por natureza, por conexão e por id de chat respectivamente, então não precisam de nada disso. Veja [Sessões](../sessions/) para o quadro completo, incluindo o que acontece com um turno inacabado quando o Pepe reinicia.

## Erros

Os erros voltam no formato de erro da OpenAI (um objeto `error` de nível superior com uma `message`), então o tratamento de erros existente funciona. Os códigos de status:

* `401` quando um token é exigido mas está ausente ou inválido.
* `403` quando você nomeia um agente que existe mas está fora do escopo do seu token.
* `400` quando o campo `model` não resolve para nenhum agente nem nenhum modelo.
* `502` quando o agente ou uma sessão com estado falha durante a execução.

O `401` da camada de autenticação carrega o código `invalid_api_key` da OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Os erros de escopo e resolução (`400`, `403`, `502`) usam um tipo `pepe_error`:

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

Os agentes são marcados como `pepe:agent`. No escopo aberto ou raiz, as conexões de modelo puras também aparecem, marcadas como `pepe:model`. Como essa é uma lista de modelos padrão, as ferramentas da OpenAI que oferecem um seletor de modelo o preenchem com os seus agentes.
