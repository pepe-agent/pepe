---
title: Autenticação
description: Protege o acesso remoto à API com tokens com âmbito.
---

## Autenticação e tokens

Com **zero tokens configurados, a API responde apenas a quem chama a partir da própria máquina (loopback)**. Um `curl` local ou o painel funcionam sem token, mas qualquer chamador remoto é recusado com `401`, pelo que um servidor exposto numa rede nunca fica anônimo.

Criar o primeiro token muda tudo para toda a gente. Assim que existe qualquer token, cada pedido, local ou remoto, tem de apresentar um válido, ou é recusado com `401`. Criar o primeiro token é o que desbloqueia o acesso remoto.

### Gerar e gerir tokens

Pode gerar, listar e revogar tokens de três formas: a CLI, o painel ou por conversa.

A partir da CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

No painel, a página de tokens de API tem um formulário para gerar um token (com uma empresa e um âmbito de agente opcional) e uma lista para revogar os existentes.

Um token é uma cadeia aleatória com o prefixo `pepe_`. No ficheiro de configuração apenas fica guardado o respetivo hash SHA-256; o token em bruto é impresso uma vez na criação e nunca mais. Copia-o nesse momento. Se o perder, revogue-o e gere um novo.

#### Faca-o por conversa

Um agente ao qual seja concedida a ferramenta protegida `manage_token` pode gerar, listar e revogar tokens a partir de uma conversa. Como um token concede acesso à API, a ferramenta não é apenas de leitura: passa pela barreira de permissões, pelo que confirma antes de um token ser criado, e o segredo em bruto é devolvido uma vez para o copiar.

> Você: Cria um token para a empresa buskaza, com o rótulo chatwoot.
>
> Agente: (pede-lhe para confirmar e depois gera-o) Token de API criado, âmbito empresa buskaza. Copia-o agora, não voltará a ser mostrado: `pepe_9f2a...`

### Apresentar um token

Envie-o de qualquer uma das duas formas que um cliente ao estilo OpenAI usaria:

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

Qualquer SDK da OpenAI envia a forma `Authorization: Bearer` quando define a respetiva `api_key`, pelo que a autenticação não precisa de tratamento especial no cliente.

### Âmbitos de token

Um token transporta um âmbito que decide a que agentes consegue chegar. Do mais estreito ao mais amplo:

* **Fixado num agente** (`--agent HANDLE`): executa sempre exatamente esse agente. O campo `model` do pedido é ignorado. Entregue isto a quem só deve alcançar um agente especifico.
* **Empresa** (`--company CO`): qualquer agente dentro dessa empresa. Um nome de `model` puro qualifica-se dentro dessa empresa automaticamente, e um pedido por um agente que pertence a outra empresa é recusado com `403`.
* **Nenhum**: o âmbito raiz (sem empresa). É sobre o que cada comando opera quando não lhe dá âmbito. Consegue alcançar os agentes raiz (aqueles com nome puro, sem espaço de nomes) e, de forma única, recorrer a ligações de modelo puras pelo nome.

`GET /v1/models` respeita o âmbito: um token de empresa ou de agente vê apenas os seus próprios agentes, nunca os de outra empresa, e nunca as ligações de modelo puras.

## Encaminhamento multiempresa: de a empresa X o seu próprio acesso

Os âmbitos são a forma de distribuir acesso à API por empresa. Para dar a uma empresa a sua própria chave, gere um token com âmbito de empresa:

```bash
pepe token add --company acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quem detem esse token:

* consegue alcançar pelo nome qualquer agente que pertença a `acme`;
* consegue enviar um nome de `model` puro e ele resolve-se dentro de `acme`;
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

Para prender um token a exatamente um agente (o campo `model` passa então a ser totalmente ignorado), acrescente `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "widget de apoio da Acme"
```
