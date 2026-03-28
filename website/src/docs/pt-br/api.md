---
title: API HTTP e WebSocket
description: Sirva seus agentes por uma API HTTP compativel com OpenAI e um WebSocket com streaming. Aponte qualquer SDK da OpenAI para o Pepe e trate cada agente como um modelo.
---

O Pepe serve seus agentes por uma API HTTP que fala o protocolo Chat Completions da OpenAI. Qualquer ferramenta ou SDK capaz de conversar com a OpenAI consegue conversar com o Pepe sem mudar uma linha de codigo: aponte o `base_url` dela para o seu servidor Pepe e use o nome de um agente onde voce normalmente colocaria um id de modelo. Tambem existe um WebSocket para streaming ao vivo, token a token, com visibilidade das chamadas de ferramenta.

As duas superficies cobrem duas necessidades. A API HTTP e a escolha padrao para trabalho de requisicao/resposta e de servidor para servidor. O WebSocket e para interfaces interativas em que voce quer renderizar as chamadas de ferramenta e o texto em streaming conforme eles acontecem.

## Uma primeira chamada

Suba o servidor e entao envie uma chat completion. Isso funciona de imediato, sem autenticacao (veja [Autenticacao](#autenticacao-e-tokens) para trancar tudo):

```bash
pepe serve --port 4000
```

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

A resposta e um objeto padrao de chat completion da OpenAI:

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

## Endpoints

Sao dois:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/root scope, raw model connections)
```

Os dois ficam sob `/v1`, entao um cliente configurado com `base_url = http://HOST:PORT/v1` os encontra exatamente onde um cliente da OpenAI espera.

## O campo "model" seleciona um agente

Essa e a ideia que faz todo o resto se encaixar. O campo `model` de uma requisicao de chat nao nomeia um modelo de linguagem puro. Ele nomeia um **agente** do Pepe. Quando voce envia `"model": "assistant"`, o Pepe executa o agente chamado `assistant`, com o prompt de sistema desse agente e o conjunto proprio de ferramentas dele. O agente executa o laco completo de chamadas de ferramenta internamente (chama o modelo, executa as chamadas de ferramenta, devolve os resultados, repete) e retorna uma unica resposta final no formato usual de uma completion.

A resolucao do campo `model` acontece nesta ordem:

1. Se o nome corresponder a um agente, esse agente executa.
2. Se nenhum agente corresponder mas o nome corresponder a uma conexao de modelo pura, o Pepe a embrulha em um agente minimo de passagem direta (sem ferramentas, um unico turno) e chama esse modelo diretamente. Essa alternativa so esta disponivel no escopo aberto ou raiz (veja [Escopos de token](#escopos-de-token)).
3. Se nenhum corresponder, o agente padrao executa.

<div class="note"><strong>Conclusao pratica.</strong> O conjunto de "modelos" que um cliente pode escolher e o seu conjunto de agentes. De a um agente um nome descritivo, conecte as ferramentas dele uma vez e todo cliente compativel com OpenAI o enxerga como um modelo selecionavel.</div>

## Chat completions

### Sem streaming

Envie `messages` no formato da OpenAI. Voce pode incluir uma mensagem `system`; se voce omitir uma, o proprio prompt de sistema do agente e usado automaticamente.

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

Defina `"stream": true` para receber a resposta conforme ela e gerada. O formato no fio e identico ao streaming da OpenAI: uma sequencia de linhas `data:`, cada uma carregando um objeto `chat.completion.chunk`, terminada por `data: [DONE]`.

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

O fragmento final carrega um delta vazio e `"finish_reason": "stop"`, seguido da linha sentinela `data: [DONE]`. Como isso bate com a OpenAI byte por byte, qualquer cliente de streaming da OpenAI o interpreta sem mudancas.

## Sessoes: com estado vs sem estado

Por padrao a API e **sem estado**: cada requisicao precisa carregar o historico completo de mensagens, exatamente como na OpenAI. Voce manda tudo, o Pepe responde, nada e lembrado.

O Pepe tambem oferece um modo **com estado** que a maioria dos servidores da OpenAI nao tem. Anexe um id de sessao e o servidor guarda a conversa para voce. Em cada chamada seguinte voce envia apenas a mensagem mais nova do usuario; o Pepe a acrescenta ao historico guardado, executa o agente e lembra do resultado. Isso e conveniente para interfaces de chat e bots de mensageria em que voce nao quer enviar a transcricao inteira toda vez.

Voce pode passar o id de sessao de tres formas. O Pepe as verifica nesta ordem:

1. Um campo `session_id` no corpo JSON.
2. O campo padrao da OpenAI `user` no corpo JSON.
3. Um cabecalho HTTP `x-session-id`.

O caminho do `user` e o interessante: `user` e um campo real no esquema de chat-completions da OpenAI, entao voce pode reutiliza-lo como chave de sessao a partir de qualquer SDK padrao da OpenAI e ganhar memoria no lado do servidor sem sair do formato padrao.

```bash
# Turn 1: only the new message is needed; the server keeps the history.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "session_id": "user-42",
    "messages": [{"role": "user", "content": "My name is Ada."}]
  }'

# Turn 2: same session id, just the follow-up. The agent remembers "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "session_id": "user-42",
    "messages": [{"role": "user", "content": "What is my name?"}]
  }'
```

No modo com estado a resposta inclui o `session_id` que voce usou, para que voce possa devolve-lo na proxima chamada. Sessoes com estado tambem funcionam com streaming; basta adicionar `"stream": true`.

<div class="note"><strong>Isolamento entre inquilinos.</strong> As chaves de sessao sao internamente delimitadas por empresa. O mesmo id de sessao usado sob dois tokens diferentes (duas empresas diferentes) nunca chega a mesma conversa, de modo que um inquilino nunca consegue ler a sessao de outro.</div>

Para voltar ao modo sem estado, simplesmente omita as tres fontes de id e envie voce mesmo o array completo de `messages`. Esse e o comportamento comum da OpenAI.

## Autenticacao e tokens

Com **zero tokens configurados, a API fica aberta**. Esse e o padrao de inquilino unico: rode na sua propria maquina ou dentro de uma rede confiavel e pule a autenticacao por completo.

Criar o primeiro token vira uma chave. Assim que qualquer token existe, cada requisicao precisa apresentar um valido, ou e recusada com `401`. Nao ha estado meio aberto; o primeiro token que voce cunha tranca a porta.

### Cunhar e gerenciar tokens

Os tokens sao criados pela CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

Um token e uma string aleatoria com o prefixo `ctx_`. No arquivo de configuracao so fica guardado o hash SHA-256 dele; o token bruto e impresso uma vez na criacao e nunca mais. Copie naquele momento. Se voce perde-lo, revogue-o e cunhe um novo.

### Apresentar um token

Envie de qualquer uma das duas formas que um cliente estilo OpenAI usaria:

```bash
# OpenAI standard: Authorization: Bearer
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hi"}] }'
```

```bash
# Azure OpenAI style: api-key header (accepted as a fallback)
curl http://localhost:4000/v1/chat/completions \
  -H 'api-key: ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hi"}] }'
```

Qualquer SDK da OpenAI envia a forma `Authorization: Bearer` quando voce define a `api_key` dele, entao a autenticacao nao precisa de tratamento especial no cliente.

### Escopos de token

Um token carrega um escopo que decide quais agentes ele pode alcancar. Do mais estreito ao mais amplo:

* **Fixado em um agente** (`--agent HANDLE`): sempre executa exatamente aquele agente. O campo `model` da requisicao e ignorado. Entregue isso a quem so deve alcancar um agente especifico.
* **Empresa** (`--company CO`): qualquer agente dentro daquela empresa. Um nome de `model` puro se qualifica dentro daquela empresa automaticamente, e uma requisicao por um agente que pertence a outra empresa e recusada com `403`.
* **Nenhum**: o escopo raiz (sem empresa). E sobre o que todo comando opera quando voce nao lhe da escopo. Ele consegue alcancar os agentes raiz (aqueles com nome puro, sem espaco de nomes) e, de forma unica, recorrer a conexoes de modelo puras pelo nome.

`GET /v1/models` respeita o escopo: um token de empresa ou de agente ve apenas os proprios agentes, nunca os de outro inquilino, e nunca as conexoes de modelo puras.

## Roteamento multi-inquilino: de a empresa X seu proprio acesso

Escopos sao a forma de distribuir acesso a API por inquilino. Para dar a uma empresa a chave dela, cunhe um token com escopo de empresa:

```bash
pepe token add --company acme --label "Acme production"
# prints: ctx_9f2a... (copy it now, shown once)
```

Quem possui esse token:

* consegue alcancar pelo nome qualquer agente que pertenca a `acme`;
* consegue enviar um nome de `model` puro e ele se resolve dentro de `acme`;
* e recusado com `403` se nomear um agente de outra empresa;
* ve apenas os agentes de `acme` a partir de `GET /v1/models`.

```bash
# Allowed: an agent inside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "support", "messages": [{"role":"user","content":"hi"}] }'

# Refused with 403: an agent outside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "some-other-company-agent", "messages": [{"role":"user","content":"hi"}] }'
```

Para prender um token a exatamente um agente (o campo `model` e entao ignorado por completo), adicione `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "Acme support widget"
```

## Erros

Os erros voltam no formato de erro da OpenAI (um objeto `error` de nivel superior com uma `message`), entao o tratamento de erros existente funciona. Os codigos de status:

* `401` quando um token e exigido mas esta ausente ou invalido.
* `403` quando voce nomeia um agente que existe mas esta fora do escopo do seu token.
* `400` quando o campo `model` nao resolve para nenhum agente nem nenhum modelo.
* `502` quando o agente ou uma sessao com estado falha durante a execucao.

O `401` da camada de autenticacao carrega o codigo `invalid_api_key` da OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Os erros de escopo e resolucao (`400`, `403`, `502`) usam um tipo `pepe_error`:

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
  -H 'authorization: Bearer ctx_your_token_here'
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

Os agentes sao marcados como `pepe:agent`. No escopo aberto ou raiz, as conexoes de modelo puras tambem aparecem, marcadas como `pepe:model`. Como essa e uma lista de modelos padrao, as ferramentas da OpenAI que oferecem um seletor de modelo o preenchem com os seus agentes.

## Exemplos de cliente

Cada exemplo aponta para o servidor local. Onde um token e mostrado, remova-o se a sua API estiver aberta.

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hello"}] }'
```

**Node (fetch simples)**

```javascript
const res = await fetch("http://localhost:4000/v1/chat/completions", {
  method: "POST",
  headers: {
    "content-type": "application/json",
    authorization: "Bearer ctx_your_token_here",
  },
  body: JSON.stringify({
    model: "assistant",
    messages: [{ role: "user", content: "hello" }],
  }),
});
const data = await res.json();
console.log(data.choices[0].message.content);
```

**Node (SDK openai)**

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:4000/v1",
  apiKey: "ctx_your_token_here", // any non-empty string if your API is open
});

const completion = await client.chat.completions.create({
  model: "assistant",
  messages: [{ role: "user", content: "hello" }],
});
console.log(completion.choices[0].message.content);
```

**Python (SDK openai)**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000/v1",
    api_key="ctx_your_token_here",  # any non-empty string if your API is open
)

completion = client.chat.completions.create(
    model="assistant",
    messages=[{"role": "user", "content": "hello"}],
)
print(completion.choices[0].message.content)
```

**Python (requests simples)**

```python
import requests

res = requests.post(
    "http://localhost:4000/v1/chat/completions",
    headers={"authorization": "Bearer ctx_your_token_here"},
    json={"model": "assistant", "messages": [{"role": "user", "content": "hello"}]},
)
print(res.json()["choices"][0]["message"]["content"])
```

**Ruby**

```ruby
require "net/http"
require "json"

uri = URI("http://localhost:4000/v1/chat/completions")
req = Net::HTTP::Post.new(uri)
req["content-type"] = "application/json"
req["authorization"] = "Bearer ctx_your_token_here"
req.body = { model: "assistant", messages: [{ role: "user", content: "hello" }] }.to_json

res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
puts JSON.parse(res.body)["choices"][0]["message"]["content"]
```

**PHP**

```php
<?php
$ch = curl_init("http://localhost:4000/v1/chat/completions");
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => [
        "content-type: application/json",
        "authorization: Bearer ctx_your_token_here",
    ],
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode([
        "model" => "assistant",
        "messages" => [["role" => "user", "content" => "hello"]],
    ]),
]);
$data = json_decode(curl_exec($ch), true);
echo $data["choices"][0]["message"]["content"], "\n";
```

**Java**

```java
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

var body = """
    { "model": "assistant", "messages": [{"role":"user","content":"hello"}] }
    """;

var request = HttpRequest.newBuilder(URI.create("http://localhost:4000/v1/chat/completions"))
    .header("content-type", "application/json")
    .header("authorization", "Bearer ctx_your_token_here")
    .POST(HttpRequest.BodyPublishers.ofString(body))
    .build();

var response = HttpClient.newHttpClient()
    .send(request, HttpResponse.BodyHandlers.ofString());
System.out.println(response.body());
```

**Elixir (usando Req)**

```elixir
Req.post!("http://localhost:4000/v1/chat/completions",
  headers: [{"authorization", "Bearer ctx_your_token_here"}],
  json: %{
    model: "assistant",
    messages: [%{role: "user", content: "hello"}]
  }
).body["choices"]
|> hd()
|> get_in(["message", "content"])
|> IO.puts()
```

## WebSocket: streaming ao vivo

O stream SSE por HTTP acima ja basta para a maior parte do streaming de servidor para servidor, e e mais simples de consumir. Recorra ao WebSocket quando estiver construindo uma interface interativa e quiser mais do que texto: ele revela cada chamada de ferramenta e cada resultado de ferramenta conforme acontece, e consegue empurrar uma notificacao de vigilancia disparada de volta para a mesma conexao.

### Conectar

Conecte em `ws://HOST:PORT/socket/websocket` (use `wss://` sobre TLS). A autenticacao espelha a API HTTP: quando tokens sao exigidos, passe o token como parametro de consulta, porque os navegadores nao conseguem definir cabecalhos em um WebSocket:

```
ws://localhost:4000/socket/websocket?token=ctx_your_token_here
```

Se a sua API estiver aberta, remova o parametro `token`.

### O protocolo de frames

O socket fala um protocolo simples de frames JSON. Cada mensagem, nas duas direcoes, e um array JSON de cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` e `ref` sao strings que voce escolhe para correlacionar respostas com requisicoes. `topic` nomeia com o que voce esta conversando. O ciclo de vida e: entrar em um topico, enviar prompts, opcionalmente reiniciar, e enviar um heartbeat a cada 30 segundos, mais ou menos, para manter a conexao viva.

```json
// 1. Join a topic. "agent:<name>", or "agent:default" for the default agent.
//    The join payload may carry a stable session to keep the same
//    notification channel across reconnects.
["1", "1", "agent:default", "phx_join", {}]

// 2. Send a prompt. The reply streams back as separate frames.
["1", "2", "agent:default", "prompt", { "text": "hello" }]

// 3. Reset the conversation history for this topic.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, every ~30s, so the connection is not dropped.
[null, "h", "phoenix", "heartbeat", {}]
```

Entrar em `agent:<name>` seleciona e autoriza aquele agente contra o escopo do seu token, exatamente como o campo `model` por HTTP. Um topico no qual voce nao tem permissao de entrar e recusado. Passe `{"session": "some-stable-id"}` no payload de entrada para manter o mesmo canal de vigilancia/notificacao entre reconexoes; caso contrario, um id novo por conexao e usado.

### Eventos

Voce **envia** dois eventos de entrada:

* `prompt` com `{ "text": "..." }`: envia uma mensagem e transmite a resposta.
* `reset` com `{}`: limpa o historico da conversa.

Voce **recebe** estes eventos de saida, cada um chegando como um frame cujo payload e mostrado:

* `delta` `{ "text": "..." }`: um fragmento em streaming da resposta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: o agente esta invocando uma ferramenta.
* `tool_result` `{ "name": "...", "output": "..." }`: a saida daquela ferramenta.
* `done` `{ "content": "..." }`: a resposta final; o turno esta completo.
* `watch` `{ "text": "..." }`: uma vigilancia criada a partir desta conexao foi disparada.
* `error` `{ "reason": "..." }`: algo deu errado neste turno.

### JavaScript (o cliente phoenix)

Em JavaScript a forma ergonomica de consumir isso e o pacote npm `phoenix`, que cuida dos frames, dos refs e dos heartbeats para voce:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: "ctx_your_token_here" }, // omit if your API is open
});
socket.connect();

const channel = socket.channel("agent:default", { session: "user-42" });
channel.join()
  .receive("ok", () => console.log("joined"))
  .receive("error", (err) => console.error("join failed", err));

channel.on("delta", ({ text }) => process.stdout.write(text));
channel.on("tool_call", ({ name, arguments: args }) =>
  console.log(`\n[tool ${name}]`, args));
channel.on("tool_result", ({ name, output }) =>
  console.log(`[tool ${name} result]`, output));
channel.on("done", ({ content }) => console.log("\n[final]", content));
channel.on("watch", ({ text }) => console.log("[watch]", text));
channel.on("error", ({ reason }) => console.error("[error]", reason));

channel.push("prompt", { text: "What files are in the current directory?" });
```

### Frames crus (qualquer linguagem)

Sem o pacote `phoenix`, fale o protocolo de frames diretamente sobre qualquer cliente WebSocket. Este exemplo em Python entra, envia um prompt, imprime os deltas em streaming e para quando `done` chega. Repare no heartbeat que voce deve enviar periodicamente em uma conexao de longa duracao.

```python
import json
import websocket  # pip install websocket-client

ws = websocket.create_connection(
    "ws://localhost:4000/socket/websocket?token=ctx_your_token_here"
)

# Join the default agent's topic.
ws.send(json.dumps(["1", "1", "agent:default", "phx_join", {}]))

# Send a prompt.
ws.send(json.dumps(["1", "2", "agent:default", "prompt", {"text": "hello"}]))

while True:
    _join_ref, _ref, _topic, event, payload = json.loads(ws.recv())
    if event == "delta":
        print(payload["text"], end="", flush=True)
    elif event == "tool_call":
        print(f"\n[tool {payload['name']}] {payload['arguments']}")
    elif event == "done":
        print("\n[final]", payload["content"])
        break
    elif event == "error":
        print("\n[error]", payload["reason"])
        break

ws.close()
```

Envie um frame de heartbeat, `[null, "h", "phoenix", "heartbeat", {}]`, mais ou menos a cada 30 segundos para manter aberta uma conexao de longa duracao.
