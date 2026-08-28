---
title: API HTTP
description: Chame o Pepe pela API Chat Completions, compatível com a OpenAI.
---

O Pepe expõe seus agentes por uma API HTTP que fala o protocolo Chat Completions
da OpenAI. Qualquer ferramenta ou SDK que já saiba conversar com a OpenAI
conversa com o Pepe sem precisar mudar uma linha de código: basta apontar o
`base_url` dele para o seu servidor Pepe e usar o nome de um agente onde
normalmente entraria um id de modelo. Também dá para chamar o endpoint com
requisições HTTP puras, direto dos seus próprios projetos, sites, backends,
jobs ou integrações; um SDK de LLM é conveniente, mas não é obrigatório. Existe
ainda um WebSocket para streaming ao vivo, token a token, com visibilidade das
chamadas de ferramenta.

As duas superfícies atendem necessidades diferentes. A API HTTP é a escolha
natural para trabalho de requisição/resposta e de servidor para servidor. Já o
WebSocket serve para interfaces interativas, onde você quer renderizar as
chamadas de ferramenta e o texto em streaming conforme acontecem.

## Uma primeira chamada

Suba o servidor e mande uma chat completion. Isso já funciona sem nenhuma
autenticação (veja [Autenticação](../auth/#autenticação-e-tokens) para trancar
isso):

```bash
pepe serve --port 4000
```

Rodando o Pepe a partir do código-fonte, em vez do binário instalado?
`PHX_SERVER=true mix phx.server` serve exatamente o mesmo endpoint.

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

A resposta vem no formato padrão de chat completion da OpenAI:

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

O `pepe serve` roda em primeiro plano. Para um deploy de verdade, veja
[Painel](../dashboard/#mantendo-o-painel-no-ar) e instale-o como serviço
persistente em segundo plano.

## Endpoints

São só dois:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/default scope, raw model connections)
```

Os dois ficam sob `/v1`, então um cliente configurado com
`base_url = http://HOST:PORT/v1` os encontra exatamente onde um cliente da
OpenAI espera achá-los.

## O campo "model" seleciona um agente

Essa é a ideia que faz tudo o mais se encaixar. O campo `model` de uma
requisição de chat não nomeia um modelo de linguagem puro, e sim um
**agente** do Pepe. Ao enviar `"model": "assistant"`, o Pepe roda o agente
chamado `assistant`, com o prompt de sistema e o conjunto de ferramentas dele.
Esse agente executa por conta própria o loop completo de chamadas de
ferramenta (chama o modelo, roda as chamadas de ferramenta, devolve os
resultados, repete) e retorna uma única resposta final, no formato usual de
uma completion.

O Pepe resolve o campo `model` nesta ordem:

1. Se o nome bater com um agente, esse agente roda.
2. Se nenhum agente bater, mas o nome bater com uma conexão de modelo pura, o
   Pepe encapsula essa conexão num agente mínimo de passagem direta (sem
   ferramentas, um único turno) e chama esse modelo diretamente. Essa
   alternativa só existe no escopo aberto ou de projeto default (veja
   [Escopos de token](../auth/#escopos-de-token)).
3. Se nenhum dos dois bater, roda o agente padrão.

<div class="note"><strong>Conclusão prática.</strong> O conjunto de "modelos"
que um cliente pode escolher é o seu conjunto de agentes. Dê a um agente um
nome descritivo, conecte as ferramentas dele uma vez, e qualquer cliente
compatível com OpenAI passa a enxergá-lo como um modelo selecionável.</div>

## Chat completions

### Sem streaming

Envie `messages` no formato da OpenAI. Você pode incluir uma mensagem
`system`; se você não incluir, o próprio prompt de sistema do agente entra
automaticamente no lugar.

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

Defina `"stream": true` para receber a resposta conforme ela vai sendo gerada.
O formato transmitido é idêntico ao streaming da OpenAI: uma sequência de
linhas `data:`, cada uma carregando um objeto `chat.completion.chunk`,
terminada por `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento tem essa cara, com o texto incremental em
`choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

O fragmento final vem com um delta vazio e `"finish_reason": "stop"`, seguido
pela linha sentinela `data: [DONE]`. Como isso bate byte a byte com a OpenAI,
qualquer cliente de streaming da OpenAI interpreta sem precisar de nenhuma
mudança.

## Sessões com estado

Por padrão o endpoint não guarda estado nenhum: você manda o array `messages`
completo em cada chamada, exatamente como faria com a OpenAI. Mas, se você
passar um id de sessão, o servidor guarda a conversa inteira para você, e cada
chamada seguinte só precisa carregar a mensagem nova do usuário.

Dois campos alimentam a chave da sessão, e eles se combinam:

* `"user": "abc"` diz **quem** está falando. É o campo padrão da OpenAI, então
  um SDK comum da OpenAI já mantém uma conversa sem precisar de nenhum campo
  específico do Pepe.
* `"session_id": "xyz"`, no corpo JSON ou no cabeçalho `X-Session-Id`, diz
  **qual** conversa daquela pessoa.

| Enviado | Chave da sessão |
| --- | --- |
| só `user` | `abc` |
| só `session_id` | `xyz` |
| os dois | `abc:xyz` (threads independentes por pessoa) |
| os dois, com o mesmo valor | deduplicado para um só |
| nenhum, ou em branco | sem estado |

No WhatsApp, por exemplo, dá para passar o `user` como o número de telefone e
o `session_id` como um id de thread, e cada thread de cada contato vira a
própria conversa. Uma string vazia (`""`) em qualquer um dos dois campos é
tratada como sem estado.

```bash
# Turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"meu nome é John Doe"}]}'

# Turno 2, mesmo "user". O servidor lembra do turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"qual é o meu nome?"}]}'
```

Cada sessão vira seu próprio processo supervisionado, com a chave `api:<id>`,
e o streaming funciona igual com sessões. O WebSocket e o Telegram já têm
estado por natureza (por conexão e por id de chat, respectivamente), então não
precisam de nada disso. Veja [Sessões](../sessions/) para o quadro completo,
incluindo o que acontece com um turno inacabado quando o Pepe reinicia.

## Erros

Os erros voltam no formato de erro da OpenAI (um objeto `error` de nível
superior com uma `message`), então o tratamento de erros que você já tem
continua funcionando. Os códigos de status:

* `401` quando um token é exigido mas está ausente ou inválido.
* `403` quando você nomeia um agente que existe, mas está fora do escopo do
  seu token.
* `400` quando o campo `model` não resolve para nenhum agente e para nenhum
  modelo.
* `502` quando o agente ou uma sessão com estado falha durante a execução.

O `401` vindo da camada de autenticação carrega o código `invalid_api_key` da
OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Já os erros de escopo e resolução (`400`, `403`, `502`) usam um tipo
`pepe_error`:

```json
{
  "error": {
    "message": "agent not accessible with this token",
    "type": "pepe_error"
  }
}
```

## Verificação de saúde

`GET /health` (também `/healthz`) é uma sonda de vida e prontidão sem
autenticação, pensada para load balancers e verificações de uptime.
Propositalmente mínima, ela nunca lista agentes nem modelos, então não vaza
nenhum dado de tenant:

```bash
curl http://localhost:4000/health
```

```json
{ "status": "ok", "service": "pepe", "ready": true }
```

`ready` fica `true` assim que existe pelo menos uma conexão de modelo e um
agente, ou seja, quando o serviço já consegue de fato responder. Para
descobrir quais agentes e modelos um chamador específico consegue alcançar,
use o `GET /v1/models` a seguir, que é autenticado e respeita escopo.

## Listando modelos

`GET /v1/models` devolve os agentes (e, no escopo aberto ou de projeto
default, também as conexões de modelo puras) que o chamador consegue
alcançar, no formato de modelos da OpenAI. É a forma correta e com escopo de
descobrir o que está disponível: com um token de projeto, a lista traz só os
agentes daquele projeto, nunca os de outro tenant, e nunca as conexões de
modelo puras.

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

Os agentes vêm marcados como `pepe:agent`. No escopo aberto ou de projeto
default, as conexões de modelo puras também aparecem, marcadas como
`pepe:model`. Como essa é uma lista de modelos no formato padrão, qualquer
ferramenta da OpenAI que ofereça um seletor de modelo já preenche esse
seletor com os seus agentes.
