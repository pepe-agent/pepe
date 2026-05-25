---
title: Autenticação
description: Entre no painel e proteja o acesso remoto à API com tokens com escopo.
---

O Pepe tem duas portas de entrada e cada uma tem a sua própria fechadura. O painel é para pessoas, e é guardado por uma senha opcional mais uma regra de rede que se fecha por padrão. A API HTTP `/v1` é para programas, e é guardada por tokens bearer que carregam um escopo. Na sua própria máquina nenhuma das duas fechaduras te atrapalha, e nenhuma das portas se abre para a rede antes de você ligar a fechadura dela.

## Autenticação do painel

O painel é **aberto por padrão**, então uma instalação local não tem atrito nenhum: rode `pepe serve` na sua máquina e acesse pelo navegador. A autenticação é **opcional, você que liga**: no momento em que você define uma senha do painel, toda página passa a exigir login. Não há banco de dados nem tabela de usuários. A senha é conferida em tempo constante e uma flag assinada viaja no cookie de sessão do Phoenix.

### Ligando a autenticação

Defina uma senha de um dos dois jeitos. Se os dois estiverem presentes, o valor da configuração vence:

```bash
# Opção A: uma variável de ambiente, então nada cai no arquivo de configuração.
export PEPE_DASHBOARD_PASSWORD='uma frase secreta bem longa'

# Opção B: guarde uma referência, então o segredo continua vindo do ambiente.
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# Veja o estado atual, ou desligue de novo.
pepe dashboard
pepe dashboard password --clear
```

O valor é interpolado como `${ENV}` no momento da leitura, então, como todo segredo no Pepe, ele nunca é escrito em texto puro no `~/.pepe/config.json`.

Com uma senha definida:

* toda rota do painel redireciona para **`/login`** até você entrar;
* o `POST /login` confere a senha com uma comparação em tempo constante e guarda uma flag assinada `dashboard_authed` no cookie de sessão;
* um link **Sign out** aparece no rodapé da barra lateral, e o `DELETE /logout` limpa a flag.

Tire a senha, removendo a variável de ambiente ou a chave da configuração, e o painel volta a ficar aberto.

### Fecha por padrão: o painel nunca fica aberto na rede sem senha

Ser "aberto por padrão" só é seguro porque esse padrão é **apenas loopback**. Uma barreira por requisição garante isso: **sem senha definida**, o painel responde apenas a clientes `localhost` de verdade. Qualquer requisição vinda de outro lugar, seja um endereço da LAN, uma máquina virtual ou um proxy reverso, recebe um **403** dizendo para você definir uma senha. Não existe chave de "deixa aberto assim mesmo": alcançar o painel de fora da máquina significa ou uma senha ou um túnel.

A regra, com precisão:

| A requisição vem de | Sem senha | Com senha |
|---|---|---|
| `localhost` (loopback, sem cabeçalhos de proxy) | permitida | exige login |
| LAN, uma VM ou outra máquina | **403** | exige login |
| por um proxy (com `X-Forwarded-For`) | **403** | exige login |

A LAN e as faixas privadas (`192.168.x`, `10.x`, `172.16.x`) contam como **públicas**, não como confiáveis. A API `/v1` e os endpoints `/webhooks` não são afetados por essa regra; eles têm a própria autenticação, descrita abaixo.

### Alcançando o painel de outra máquina

Duas opções são seguras:

1. **Defina uma senha** e exponha o painel atrás de TLS, com um proxy reverso ou um túnel, para que a senha e o cookie de sessão nunca trafeguem em texto puro. Quando você põe um proxy na frente, mantenha a senha ligada, porque uma requisição vinda de proxy é tratada como pública.

2. **Mantenha tudo em loopback e entre por um túnel**, para que nada seja aberto na rede:

```bash
pepe serve --tunnel                     # túnel rápido da Cloudflare, embutido (precisa do cloudflared)
ssh -L 4000:localhost:4000 voce@servidor  # depois acesse http://localhost:4000
tailscale serve 4000                    # uma tailnet privada, sem porta pública
```

O `pepe serve --tunnel` roda o `cloudflared` e imprime uma URL pública `https://<...>.trycloudflare.com` que dura enquanto o processo viver. Como o túnel é um proxy, uma requisição vinda por ele conta como pública, então defina uma senha do painel antes de usá-lo. O passo a passo completo, incluindo túneis nomeados com uma URL estável escolhida por você, está na página do [Painel](../dashboard/#acesso-remoto).

Já o `ssh -L` e um redirecionamento de porta do Multipass chegam pelo loopback, então funcionam sem senha nenhuma. Uma VM acessada pela rede virtual dela parece remota e é bloqueada, então redirecione a porta dela para o `localhost`.

### Servindo atrás de um domínio ou de um proxy reverso

Dois ajustes opcionais fazem um deploy de verdade se comportar direito:

```bash
# Os valores do cabeçalho Host aos quais o painel deve responder (nomes de loopback sempre funcionam).
pepe dashboard hosts dash.example.com

# Os proxies reversos cujo X-Forwarded-For pode ser confiável (CIDRs ou IPs puros).
pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8

# Mostra a postura atual: autenticação, hosts, proxies.
pepe dashboard
```

* Os **hosts permitidos** são uma defesa contra DNS rebinding. Sem senha, o painel aceita apenas um `Host` de **loopback** (`localhost`, `127.0.0.1`, `::1`) e recusa qualquer outro nome com **400**, o que impede uma página maliciosa de reapontar um domínio para a sua máquina e dirigir o painel local. Quando você serve sob um domínio de verdade, liste-o aqui, com uma senha ligada. Uma lista vazia mais uma senha aceita qualquer host, porque aí a senha é a barreira.
* Os **proxies confiáveis** decidem quando o `X-Forwarded-For` é acreditado. Por padrão ele é ignorado e uma requisição vinda de proxy é tratada como remota, que é a escolha que fecha por padrão. Liste o seu proxy aqui e o Pepe passa a tirar o IP real do cliente da cadeia encaminhada, então tanto a regra de loopback contra remoto quanto o limite de tentativas de login enxergam o par verdadeiro em vez do proxy.

### Proteção contra força bruta

O `POST /login` tem limite de taxa por IP de cliente, por padrão 10 tentativas a cada 60 segundos, e um login bem-sucedido zera o contador. Isso fica em cima da comparação de senha em tempo constante e de um pequeno atraso a cada falha. Passar do limite devolve **429** com um cabeçalho `Retry-After`.

### Estendendo a autenticação

A barreira é de propósito pequena e componível: um hook `on_mount` (`PepeWeb.Auth`), um plug (`PepeWeb.NetworkGuard`, apoiado em `Pepe.Net` e `PepeWeb.RemoteClient`) e o limitador de login. Esquemas mais ricos, como OAuth, cabeçalhos de identidade vindos de um proxy confiável ou contas por operador, encaixam sem mexer em cada LiveView.

## Autenticação e tokens

Com **zero tokens configurados, a API responde apenas a chamadas da mesma máquina (loopback)**. Um `curl` local ou o painel funcionam sem token, mas qualquer chamada remota é recusada com `401`, então um servidor que você expõe numa rede nunca fica anônimo.

Criar o primeiro token muda o jogo para todo mundo. Assim que qualquer token existe, cada requisição, local ou remota, precisa apresentar um válido, ou é recusada com `401`. Criar o primeiro token é o que libera o acesso remoto.

### Gerar e gerenciar tokens

Você pode gerar, listar e revogar tokens de três formas: pela CLI, pelo painel ou pela conversa.

Pela CLI:

```bash
pepe token add [--project PROJ] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

No painel, a página de tokens da API tem um formulário para gerar um token (com um projeto e um escopo de agente opcional) e uma lista para revogar os existentes.

Um token é uma string aleatória com o prefixo `pepe_`. No arquivo de configuração só fica guardado o hash SHA-256 dele; o token bruto é impresso uma vez na criação e nunca mais. Copie naquele momento. Se você perdê-lo, revogue-o e gere um novo.

#### Faça pela conversa

Um agente que recebe a ferramenta protegida `manage_token` consegue gerar, listar e revogar tokens a partir de uma conversa. Como um token concede acesso à API, a ferramenta não é somente leitura: ela passa pela barreira de permissão, então você confirma antes de um token ser criado, e o segredo bruto é retornado uma vez para você copiar.

> Você: Crie um token para o projeto acme, com o rótulo chatwoot.
>
> Agente: (pede para você confirmar e então o gera) Token da API criado, escopo projeto acme. Copie agora, ele não será mostrado de novo: `pepe_9f2a...`

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
* **Projeto** (`--project PROJ`): qualquer agente dentro daquele projeto. Um nome de `model` puro se qualifica dentro daquele projeto automaticamente, e uma requisição por um agente que pertence a outro projeto é recusada com `403`.
* **Nenhum**: o projeto default. É o escopo em que todo comando opera quando você não especifica nenhum. Ele consegue alcançar os agentes do default (aqueles com nome puro, sem espaço de nomes) e, de forma única, recorrer a conexões de modelo puras pelo nome.

`GET /v1/models` respeita o escopo: um token de projeto ou de agente vê apenas os próprios agentes, nunca os de outro projeto, e nunca as conexões de modelo puras.

## Roteamento multiprojeto: dê ao projeto X seu próprio acesso

Escopos são a forma de distribuir acesso à API por projeto. Para dar a um projeto a chave dele, gere um token com escopo de projeto:

```bash
pepe token add --project acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quem possui esse token:

* consegue alcançar pelo nome qualquer agente que pertença a `acme`;
* consegue enviar um nome de `model` puro e ele se resolve dentro de `acme`;
* é recusado com `403` se nomear um agente de outro projeto;
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
  -d '{ "model": "some-other-project-agent", "messages": [{"role":"user","content":"olá"}] }'
```

Para prender um token a exatamente um agente (o campo `model` é então ignorado por completo), adicione `--agent`:

```bash
pepe token add --project acme --agent acme/support --label "widget de suporte da Acme"
```
