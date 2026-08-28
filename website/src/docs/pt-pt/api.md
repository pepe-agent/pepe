---
title: API HTTP
description: Fala com o Pepe através da API Chat Completions, compatível com a OpenAI.
---

O Pepe expõe os teus agentes através de uma API HTTP que fala o protocolo Chat Completions da OpenAI. Qualquer ferramenta ou SDK que já saiba falar com a OpenAI sabe falar com o Pepe sem mudares nada no código: basta apontar o `base_url` para o teu servidor Pepe e usar o nome de um agente onde normalmente colocarias o id de um modelo. Também podes chamar o endpoint com pedidos HTTP simples a partir dos teus próprios projetos, sites, backends, jobs ou integrações; um SDK de LLM é conveniente, mas nunca obrigatório. Há também um WebSocket para streaming ao vivo, token a token, com visibilidade sobre as chamadas de ferramenta.

Estas duas superfícies servem propósitos diferentes. A API HTTP é a escolha natural para trabalho de pedido/resposta e de servidor para servidor. O WebSocket serve interfaces interativas, onde queres desenhar as chamadas de ferramenta e o texto em streaming à medida que vão acontecendo.

## Um primeiro pedido

Arranca o servidor e envia uma chat completion. Isto funciona logo de início, sem qualquer autenticação (consulta [Autenticação](../auth/#autenticação-e-tokens) para o fechar):

```bash
pepe serve --port 4000
```

Se estiveres a correr o Pepe a partir do código-fonte em vez do binário instalado, `PHX_SERVER=true mix phx.server` serve exatamente o mesmo endpoint.

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

A resposta é um objeto de chat completion no formato padrão da OpenAI:

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

O `pepe serve` corre em primeiro plano. Para um deploy a sério, consulta [Painel](../dashboard/#manter-em-execução) e vê como o instalar como serviço persistente em segundo plano.

## Endpoints

São só dois:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/default-project scope, raw model connections)
```

Ambos vivem debaixo de `/v1`, por isso um cliente configurado com `base_url = http://HOST:PORT/v1` encontra-os exatamente onde um cliente da OpenAI espera encontrá-los.

## O campo "model" escolhe um agente

Esta é a única ideia que faz todo o resto encaixar. No pedido de chat, o campo `model` não nomeia um modelo de linguagem puro e simples: nomeia um **agente** do Pepe. Ao enviares `"model": "assistant"`, é o agente chamado `assistant` que corre, com o prompt de sistema e o conjunto de ferramentas próprios dele. O agente trata internamente de todo o ciclo de chamada de ferramentas (chama o modelo, executa as chamadas pedidas, devolve os resultados, repete) e o que te chega de volta é uma única resposta final, no formato habitual de uma completion.

O Pepe resolve o campo `model` por esta ordem:

1. Se o nome corresponder a um agente, é esse agente que corre.
2. Se nenhum agente corresponder mas o nome coincidir com uma ligação de modelo pura, o Pepe embrulha-a num agente mínimo, de passagem direta (sem ferramentas, um único turno) e chama esse modelo diretamente. Esta alternativa só existe no âmbito aberto ou no do projeto default (consulta [Âmbitos de token](../auth/#âmbitos-de-token)).
3. Se nada corresponder, é o agente predefinido que corre.

<div class="note"><strong>Na prática.</strong> O conjunto de "modelos" entre os quais um cliente pode escolher é, no fundo, o teu conjunto de agentes. Dá a um agente um nome descritivo, liga-lhe as ferramentas uma única vez, e qualquer cliente compatível com a OpenAI passa a mostrá-lo como um modelo selecionável.</div>

## Chat completions

### Sem streaming

Envia `messages` no formato da OpenAI. Podes incluir uma mensagem `system`; se a omitires, entra automaticamente o próprio prompt de sistema do agente.

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

Define `"stream": true` para receberes a resposta à medida que vai sendo gerada. O formato no fio é idêntico ao streaming da OpenAI: uma sequência de linhas `data:`, cada uma carregando um objeto `chat.completion.chunk`, terminada por `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento tem este aspeto, com o texto incremental dentro de `choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

O último fragmento traz um delta vazio e `"finish_reason": "stop"`, seguido da linha sentinela `data: [DONE]`. Como isto reproduz a OpenAI byte a byte, qualquer cliente de streaming feito para a OpenAI consegue lê-lo sem qualquer alteração.

## Sessões com estado

Por omissão o endpoint não guarda estado nenhum: envias o array `messages` completo em cada chamada, tal como farias contra a OpenAI. Se preferires, passa um id de sessão e o servidor guarda a conversa inteira por ti, de forma que cada chamada seguinte só precisa de trazer a mensagem mais recente do utilizador.

Dois campos alimentam a chave da sessão, e combinam-se entre si:

* `"user": "abc"` identifica **quem** está a falar. É o campo padrão da OpenAI, por isso um SDK comum da OpenAI mantém uma conversa sem precisar de nenhum campo específico do Pepe.
* `"session_id": "xyz"`, quer no corpo JSON quer como cabeçalho `X-Session-Id`, identifica **qual** das conversas dessa pessoa.

| Enviado | Chave da sessão |
| --- | --- |
| só `user` | `abc` |
| só `session_id` | `xyz` |
| ambos | `abc:xyz` (threads independentes por pessoa) |
| ambos, com o mesmo valor | reduzidos a um só |
| nenhum, ou em branco | sem estado |

No WhatsApp, por exemplo, podes passar o número de telefone em `user` e um id de thread em `session_id`, e cada thread de cada contacto passa a ser a sua própria conversa. Uma cadeia vazia (`""`) em qualquer um dos dois campos é tratada como se não houvesse estado nenhum.

```bash
# Turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"o meu nome é John Doe"}]}'

# Turno 2, mesmo "user". O servidor já se lembra do turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"qual é o meu nome?"}]}'
```

Cada sessão corre no seu próprio processo supervisionado, identificado por `api:<id>`. O streaming também funciona dentro de sessões. O WebSocket e o Telegram já têm estado por natureza (por ligação, e por id de conversa respetivamente), por isso não precisam de nada disto. Consulta [Sessões](../sessions/) para o quadro completo, incluindo o que acontece a um turno por terminar quando o Pepe reinicia.

## Erros

Os erros voltam no formato da OpenAI (um objeto `error` no nível de topo, com uma `message`), o que significa que o tratamento de erros que já tens continua a funcionar. Os códigos de estado usados são:

* `401` quando é preciso um token e ele falta, ou é inválido.
* `403` quando nomeias um agente que existe, mas está fora do âmbito do teu token.
* `400` quando o campo `model` não resolve nem para um agente nem para um modelo.
* `502` quando o agente, ou uma sessão com estado, falha durante a execução.

O `401` vindo da camada de autenticação transporta o código `invalid_api_key` da própria OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Já os erros de âmbito e de resolução (`400`, `403`, `502`) usam um tipo próprio, `pepe_error`:

```json
{
  "error": {
    "message": "agent not accessible with this token",
    "type": "pepe_error"
  }
}
```

## Verificação de saúde

`GET /health` (também disponível em `/healthz`) é uma sonda de vida e prontidão sem autenticação, pensada para balanceadores de carga e verificações de disponibilidade. É deliberadamente mínima e nunca lista agentes nem modelos, por isso não expõe nenhum dado de nenhum inquilino:

```bash
curl http://localhost:4000/health
```

```json
{ "status": "ok", "service": "pepe", "ready": true }
```

`ready` passa a `true` assim que existir pelo menos uma ligação de modelo e um agente, ou seja, assim que o serviço tiver mesmo condições para responder. Para descobrires a que agentes e modelos um chamador em concreto consegue chegar, usa antes o `GET /v1/models` abaixo, que exige autenticação e respeita o âmbito.

## Listar modelos

`GET /v1/models` devolve os agentes (e, no âmbito aberto ou no do projeto default, também as ligações de modelo puras) a que quem está a chamar tem acesso, no formato de modelos da OpenAI. É esta a forma correta e limitada por projeto de descobrir o que está disponível: com um token de projeto, a lista mostra só os agentes desse projeto, nunca os de outro inquilino, e nunca as ligações de modelo puras.

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

Os agentes vêm etiquetados como `pepe:agent`. No âmbito aberto ou no do projeto default, aparecem também as ligações de modelo puras, etiquetadas como `pepe:model`. Como isto é uma lista de modelos absolutamente padrão, qualquer ferramenta da OpenAI que ofereça um seletor de modelo acaba por preenchê-lo com os teus agentes.
