---
title: Autenticação
description: Proteja o acesso remoto à API com tokens com escopo.
---

## Autenticação e tokens

Com **zero tokens configurados, a API responde apenas a chamadas da mesma máquina (loopback)**. Um `curl` local ou o painel funcionam sem token, mas qualquer chamada remota é recusada com `401`, então um servidor que você expõe numa rede nunca fica anônimo.

Criar o primeiro token muda o jogo para todo mundo. Assim que qualquer token existe, cada requisição, local ou remota, precisa apresentar um válido, ou é recusada com `401`. Criar o primeiro token é o que libera o acesso remoto.

### Gerar e gerenciar tokens

Você pode gerar, listar e revogar tokens de três formas: pela CLI, pelo painel ou pela conversa.

Pela CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

No painel, a página de tokens da API tem um formulário para gerar um token (com uma empresa e um escopo de agente opcional) e uma lista para revogar os existentes.

Um token é uma string aleatória com o prefixo `pepe_`. No arquivo de configuração só fica guardado o hash SHA-256 dele; o token bruto é impresso uma vez na criação e nunca mais. Copie naquele momento. Se você perdê-lo, revogue-o e gere um novo.

#### Faça pela conversa

Um agente que recebe a ferramenta protegida `manage_token` consegue gerar, listar e revogar tokens a partir de uma conversa. Como um token concede acesso à API, a ferramenta não é somente leitura: ela passa pela barreira de permissão, então você confirma antes de um token ser criado, e o segredo bruto é retornado uma vez para você copiar.

> Você: Crie um token para a empresa acme, com o rótulo chatwoot.
>
> Agente: (pede para você confirmar e então o gera) Token da API criado, escopo empresa acme. Copie agora, ele não será mostrado de novo: `pepe_9f2a...`

### Apresentar um token

Envie de qualquer uma das duas formas que um cliente estilo OpenAI usaria:

```bash
# OpenAI standard: Authorization: Bearer
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"olá"}] }'
```

```bash
# Azure OpenAI style: api-key header (accepted as a fallback)
curl http://localhost:4000/v1/chat/completions \
  -H 'api-key: pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"olá"}] }'
```

Qualquer SDK da OpenAI envia a forma `Authorization: Bearer` quando você define a `api_key` dele, então a autenticação não precisa de tratamento especial no cliente.

### Escopos de token

Um token carrega um escopo que decide quais agentes ele pode alcançar. Do mais estreito ao mais amplo:

* **Fixado em um agente** (`--agent HANDLE`): sempre executa exatamente aquele agente. O campo `model` da requisição é ignorado. Entregue isso a quem só deve alcançar um agente específico.
* **Empresa** (`--company CO`): qualquer agente dentro daquela empresa. Um nome de `model` puro se qualifica dentro daquela empresa automaticamente, e uma requisição por um agente que pertence a outra empresa é recusada com `403`.
* **Nenhum**: o escopo raiz (sem empresa). É o escopo em que todo comando opera quando você não especifica nenhum. Ele consegue alcançar os agentes raiz (aqueles com nome puro, sem espaço de nomes) e, de forma única, recorrer a conexões de modelo puras pelo nome.

`GET /v1/models` respeita o escopo: um token de empresa ou de agente vê apenas os próprios agentes, nunca os de outra empresa, e nunca as conexões de modelo puras.

## Roteamento multiempresa: dê à empresa X seu próprio acesso

Escopos são a forma de distribuir acesso à API por empresa. Para dar a uma empresa a chave dela, gere um token com escopo de empresa:

```bash
pepe token add --company acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quem possui esse token:

* consegue alcançar pelo nome qualquer agente que pertença a `acme`;
* consegue enviar um nome de `model` puro e ele se resolve dentro de `acme`;
* é recusado com `403` se nomear um agente de outra empresa;
* vê apenas os agentes de `acme` a partir de `GET /v1/models`.

```bash
# Allowed: an agent inside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "support", "messages": [{"role":"user","content":"olá"}] }'

# Refused with 403: an agent outside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "some-other-company-agent", "messages": [{"role":"user","content":"olá"}] }'
```

Para prender um token a exatamente um agente (o campo `model` é então ignorado por completo), adicione `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "widget de suporte da Acme"
```
