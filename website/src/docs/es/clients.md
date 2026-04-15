---
title: Ejemplos de clientes
description: Llama a Pepe desde JavaScript, Python, Ruby, PHP, Java, Elixir y WebSocket directo.
---

## Ejemplos de cliente

Cada ejemplo apunta al servidor local. Donde se muestre un token, quitalo si tu API está abierta.

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hola"}] }'
```

**Node (fetch simple)**

```javascript
const res = await fetch("http://localhost:4000/v1/chat/completions", {
  method: "POST",
  headers: {
    "content-type": "application/json",
    authorization: "Bearer pepe_your_token_here",
  },
  body: JSON.stringify({
    model: "assistant",
    messages: [{ role: "user", content: "hola" }],
  }),
});
const data = await res.json();
console.log(data.choices[0].message.content);
```

**Node (SDK de openai)**

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:4000/v1",
  apiKey: "pepe_your_token_here", // any non-empty string if your API is open
});

const completion = await client.chat.completions.create({
  model: "assistant",
  messages: [{ role: "user", content: "hola" }],
});
console.log(completion.choices[0].message.content);
```

**Python (SDK de openai)**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000/v1",
    api_key="pepe_your_token_here",  # any non-empty string if your API is open
)

completion = client.chat.completions.create(
    model="assistant",
    messages=[{"role": "user", "content": "hola"}],
)
print(completion.choices[0].message.content)
```

**Python (requests simple)**

```python
import requests

res = requests.post(
    "http://localhost:4000/v1/chat/completions",
    headers={"authorization": "Bearer pepe_your_token_here"},
    json={"model": "assistant", "messages": [{"role": "user", "content": "hola"}]},
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
req["authorization"] = "Bearer pepe_your_token_here"
req.body = { model: "assistant", messages: [{ role: "user", content: "hola" }] }.to_json

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
        "authorization: Bearer pepe_your_token_here",
    ],
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode([
        "model" => "assistant",
        "messages" => [["role" => "user", "content" => "hola"]],
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
    { "model": "assistant", "messages": [{"role":"user","content":"hola"}] }
    """;

var request = HttpRequest.newBuilder(URI.create("http://localhost:4000/v1/chat/completions"))
    .header("content-type", "application/json")
    .header("authorization", "Bearer pepe_your_token_here")
    .POST(HttpRequest.BodyPublishers.ofString(body))
    .build();

var response = HttpClient.newHttpClient()
    .send(request, HttpResponse.BodyHandlers.ofString());
System.out.println(response.body());
```

**Elixir (usando Req)**

```elixir
Req.post!("http://localhost:4000/v1/chat/completions",
  headers: [{"authorization", "Bearer pepe_your_token_here"}],
  json: %{
    model: "assistant",
    messages: [%{role: "user", content: "hola"}]
  }
).body["choices"]
|> hd()
|> get_in(["message", "content"])
|> IO.puts()
```
