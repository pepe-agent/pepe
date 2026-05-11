---
title: Autenticação
description: Entra no painel e protege o acesso remoto à API com tokens com âmbito.
---

O Pepe tem duas portas de entrada e cada uma tem a sua própria fechadura. O painel é para pessoas, e é guardado por uma palavra-passe opcional mais uma regra de rede que fecha por predefinição. A API HTTP `/v1` é para programas, e é guardada por tokens bearer que transportam um âmbito. Na tua própria máquina nenhuma das fechaduras te estorva, e nenhuma das portas se abre para a rede antes de ligares a fechadura dela.

## Autenticação do painel

O painel é **aberto por predefinição**, para que uma instalação local não tenha atrito nenhum: corre `pepe serve` na tua máquina e abre-o no navegador. A autenticação é **opcional, ligas tu**: no momento em que defines uma palavra-passe do painel, todas as páginas passam a exigir autenticação. Não há base de dados nem tabela de utilizadores. A palavra-passe é verificada em tempo constante e uma flag assinada viaja no cookie de sessão do Phoenix.

### Ligar a autenticação

Define uma palavra-passe de uma de duas formas. Se ambas estiverem presentes, vence o valor da configuração:

```bash
# Opção A: uma variável de ambiente, para que nada caia no ficheiro de configuração.
export PEPE_DASHBOARD_PASSWORD='uma frase secreta bem longa'

# Opção B: guarda uma referência, para que o segredo continue a vir do ambiente.
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# Vê o estado atual, ou desliga outra vez.
pepe dashboard
pepe dashboard password --clear
```

O valor é interpolado como `${ENV}` no momento da leitura, por isso, tal como todos os outros segredos no Pepe, nunca é escrito em texto simples no `~/.pepe/config.json`.

Com uma palavra-passe definida:

* todas as rotas do painel redirecionam para **`/login`** até entrares;
* o `POST /login` verifica a palavra-passe com uma comparação em tempo constante e guarda uma flag assinada `dashboard_authed` no cookie de sessão;
* aparece um link **Sign out** no rodapé da barra lateral, e o `DELETE /logout` limpa a flag.

Retira a palavra-passe, removendo a variável de ambiente ou a chave da configuração, e o painel volta a ficar aberto.

### Fecha por predefinição: o painel nunca fica aberto na rede sem palavra-passe

Ser "aberto por predefinição" só é seguro porque essa predefinição é **apenas loopback**. Uma barreira por pedido garante isso: **sem palavra-passe definida**, o painel responde apenas a clientes `localhost` genuínos. Qualquer pedido vindo de outro sítio, seja um endereço da LAN, uma máquina virtual ou um proxy inverso, recebe um **403** a dizer-te para definires uma palavra-passe. Não existe interruptor de "deixa aberto na mesma": chegar ao painel a partir de fora da máquina significa ou uma palavra-passe ou um túnel.

A regra, com precisão:

| O pedido vem de | Sem palavra-passe | Com palavra-passe |
|---|---|---|
| `localhost` (loopback, sem cabeçalhos de proxy) | permitido | exige autenticação |
| LAN, uma VM ou outra máquina | **403** | exige autenticação |
| por um proxy (com `X-Forwarded-For`) | **403** | exige autenticação |

A LAN e as gamas privadas (`192.168.x`, `10.x`, `172.16.x`) contam como **públicas**, não como de confiança. A API `/v1` e os endpoints `/webhooks` não são afetados por esta regra; têm a sua própria autenticação, descrita mais abaixo.

### Chegar ao painel a partir de outra máquina

Duas opções são seguras:

1. **Define uma palavra-passe** e expõe o painel atrás de TLS, com um proxy inverso ou um túnel, para que a palavra-passe e o cookie de sessão nunca sigam em texto simples. Quando pões um proxy à frente, mantém a palavra-passe ligada, porque um pedido vindo de proxy é tratado como público.

2. **Mantém tudo em loopback e entra por um túnel**, para que nada seja aberto na rede:

```bash
pepe serve --tunnel                        # túnel rápido da Cloudflare, embutido (precisa do cloudflared)
ssh -L 4000:localhost:4000 tu@servidor     # depois abre http://localhost:4000
tailscale serve 4000                       # uma tailnet privada, sem porta pública
```

O `pepe serve --tunnel` corre o `cloudflared` e imprime um URL público `https://<...>.trycloudflare.com` que dura enquanto o processo viver. Como o túnel é um proxy, um pedido vindo por ele conta como público, por isso define uma palavra-passe do painel antes de o usares. O percurso completo, incluindo túneis nomeados com um URL estável escolhido por ti, está na página do [Painel](../dashboard/#acesso-remoto).

Já o `ssh -L` e um reencaminhamento de porta do Multipass chegam pelo loopback, por isso funcionam sem palavra-passe nenhuma. Uma VM alcançada através da sua rede virtual parece remota e é bloqueada, por isso reencaminha a porta dela para o `localhost`.

### Servir atrás de um domínio ou de um proxy inverso

Duas definições opcionais fazem um deploy a sério comportar-se corretamente:

```bash
# Os valores do cabeçalho Host aos quais o painel deve responder (nomes de loopback funcionam sempre).
pepe dashboard hosts dash.example.com

# Os proxies inversos cujo X-Forwarded-For pode ser de confiança (CIDRs ou IPs simples).
pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8

# Mostra a postura atual: autenticação, hosts, proxies.
pepe dashboard
```

* Os **hosts permitidos** são uma defesa contra DNS rebinding. Sem palavra-passe, o painel aceita apenas um `Host` de **loopback** (`localhost`, `127.0.0.1`, `::1`) e recusa qualquer outro nome com **400**, o que impede uma página maliciosa de reapontar um domínio para a tua máquina e conduzir o painel local. Quando serves sob um domínio a sério, lista-o aqui, com uma palavra-passe ligada. Uma lista vazia mais uma palavra-passe aceita qualquer host, porque aí a palavra-passe é a barreira.
* Os **proxies de confiança** decidem quando o `X-Forwarded-For` é acreditado. Por predefinição é ignorado e um pedido vindo de proxy é tratado como remoto, que é a escolha que fecha por omissão. Lista aqui o teu proxy e o Pepe passa a tirar o IP real do cliente da cadeia reencaminhada, para que tanto a regra de loopback contra remoto como o limite de tentativas de autenticação vejam o par verdadeiro em vez do proxy.

### Proteção contra força bruta

O `POST /login` tem limite de taxa por IP de cliente, por predefinição 10 tentativas a cada 60 segundos, e uma autenticação bem-sucedida repõe o contador. Isso assenta em cima da comparação de palavra-passe em tempo constante e de um pequeno atraso a cada falha. Passar do limite devolve **429** com um cabeçalho `Retry-After`.

### Estender a autenticação

A barreira é deliberadamente pequena e componível: um hook `on_mount` (`PepeWeb.Auth`), um plug (`PepeWeb.NetworkGuard`, apoiado em `Pepe.Net` e `PepeWeb.RemoteClient`) e o limitador de autenticação. Esquemas mais ricos, como OAuth, cabeçalhos de identidade vindos de um proxy de confiança ou contas por operador, encaixam sem mexer em cada LiveView.

## Autenticação e tokens

Com **zero tokens configurados, a API responde apenas a quem chama a partir da própria máquina (loopback)**. Um `curl` local ou o painel funcionam sem token, mas qualquer chamador remoto é recusado com `401`, pelo que um servidor exposto numa rede nunca fica anónimo.

Criar o primeiro token muda tudo para toda a gente. Assim que existe qualquer token, cada pedido, local ou remoto, tem de apresentar um válido, ou é recusado com `401`. Criar o primeiro token é o que desbloqueia o acesso remoto.

### Gerar e gerir tokens

Podes gerar, listar e revogar tokens de três formas: a CLI, o painel ou por conversa.

A partir da CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

No painel, a página de tokens de API tem um formulário para gerar um token (com uma empresa e um âmbito de agente opcional) e uma lista para revogar os existentes.

Um token é uma cadeia aleatória com o prefixo `pepe_`. No ficheiro de configuração apenas fica guardado o respetivo hash SHA-256; o token em bruto é impresso uma vez na criação e nunca mais. Copia-o nesse momento. Se o perderes, revoga-o e gera um novo.

#### Fá-lo pela conversa

Um agente ao qual seja concedida a ferramenta protegida `manage_token` pode gerar, listar e revogar tokens a partir de uma conversa. Como um token concede acesso à API, a ferramenta não é apenas de leitura: passa pela barreira de permissão, pelo que confirma antes de um token ser criado, e o segredo em bruto é devolvido uma vez para o copiar.

> Tu: Cria um token para a empresa acme, com o rótulo chatwoot.
>
> Agente: (pede-te para confirmar e depois gera-o) Token de API criado, âmbito empresa acme. Copia-o agora, não voltará a ser mostrado: `pepe_9f2a...`

### Apresentar um token

Envia-o de qualquer uma das duas formas que um cliente ao estilo OpenAI usaria:

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

* **Fixado num agente** (`--agent HANDLE`): executa sempre exatamente esse agente. O campo `model` do pedido é ignorado. Entrega isto a quem só deve alcançar um agente específico.
* **Empresa** (`--company CO`): qualquer agente dentro dessa empresa. Um nome de `model` puro qualifica-se dentro dessa empresa automaticamente, e um pedido por um agente que pertence a outra empresa é recusado com `403`.
* **Nenhum**: o âmbito raiz (sem empresa). É sobre o que cada comando opera quando não lhe dás âmbito. Consegue alcançar os agentes raiz (aqueles com nome puro, sem espaço de nomes) e, de forma única, recorrer a ligações de modelo puras pelo nome.

`GET /v1/models` respeita o âmbito: um token de empresa ou de agente vê apenas os seus próprios agentes, nunca os de outra empresa, e nunca as ligações de modelo puras.

## Encaminhamento multiempresa: dá à empresa X o seu próprio acesso

Os âmbitos são a forma de distribuir acesso à API por empresa. Para dar a uma empresa a sua própria chave, gera um token com âmbito de empresa:

```bash
pepe token add --company acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quem detém esse token:

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

Para prender um token a exatamente um agente (o campo `model` passa então a ser totalmente ignorado), acrescenta `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "widget de apoio da Acme"
```
