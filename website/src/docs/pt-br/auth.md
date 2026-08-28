---
title: Autenticação
description: Entre no painel e proteja o acesso remoto à API com tokens de escopo definido.
---

O Pepe tem duas portas de entrada, cada uma com a própria fechadura. O painel é
para pessoas, protegido por uma senha opcional mais uma regra de rede que fecha
por padrão. Já a API HTTP `/v1` é para programas, protegida por tokens bearer
que carregam um escopo. Na sua própria máquina nenhuma das duas fechaduras
atrapalha, e nenhuma das portas se abre para a rede antes de você mesmo ligar a
fechadura dela.

## Autenticação do painel

O painel vem **aberto por padrão**, para que uma instalação local não tenha
nenhum atrito: basta rodar `pepe serve` na sua máquina e acessar pelo
navegador. A autenticação é **opcional, e você quem liga**: no instante em que
você define uma senha do painel, toda página passa a exigir login. Não existe
banco de dados nem tabela de usuários por trás disso; a senha é conferida em
tempo constante e uma flag assinada viaja dentro do cookie de sessão do
Phoenix.

### Ligando a autenticação

Defina uma senha de um dos dois jeitos abaixo. Se os dois estiverem presentes,
o valor da configuração ganha:

```bash
# Opção A: uma variável de ambiente, então nada cai no arquivo de configuração.
export PEPE_DASHBOARD_PASSWORD='uma frase secreta bem longa'

# Opção B: guarde uma referência, então o segredo continua vindo do ambiente.
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# Veja o estado atual, ou desligue de novo.
pepe dashboard
pepe dashboard password --clear
```

O valor é interpolado como `${ENV}` no momento da leitura, então, como todo
segredo no Pepe, nunca é gravado em texto puro dentro do
`~/.pepe/config.json`.

Com uma senha definida:

* toda rota do painel redireciona para **`/login`** até você entrar;
* o `POST /login` confere a senha com uma comparação em tempo constante e
  guarda uma flag assinada `dashboard_authed` no cookie de sessão;
* um link **Sign out** passa a aparecer no rodapé da barra lateral, e o
  `DELETE /logout` limpa a flag.

Tire a senha, removendo a variável de ambiente ou a chave da configuração, e o
painel volta a ficar aberto.

### Fecha por padrão: o painel nunca fica aberto na rede sem senha

Ser "aberto por padrão" só é seguro porque esse padrão é **restrito ao
loopback**. Uma barreira por requisição garante isso: **sem senha definida**, o
painel só responde a clientes `localhost` de verdade. Qualquer requisição vinda
de outro lugar, seja um endereço de LAN, uma máquina virtual ou um proxy
reverso, recebe um **403** dizendo para você definir uma senha. Não existe
nenhuma chave de "deixa aberto assim mesmo": chegar ao painel de fora da
máquina exige uma senha ou um túnel.

A regra, com precisão:

| A requisição vem de | Sem senha | Com senha |
|---|---|---|
| `localhost` (loopback, sem cabeçalhos de proxy) | permitida | exige login |
| LAN, uma VM ou outra máquina | **403** | exige login |
| por um proxy (com `X-Forwarded-For`) | **403** | exige login |

A LAN e as faixas privadas (`192.168.x`, `10.x`, `172.16.x`) contam como
**públicas**, não como confiáveis. A API `/v1` e os endpoints `/webhooks` não
são afetados por essa regra; eles têm a própria autenticação, descrita mais
abaixo.

### Alcançando o painel de outra máquina

Duas opções são seguras:

1. **Defina uma senha** e exponha o painel atrás de TLS, por um proxy reverso
   ou um túnel, de modo que a senha e o cookie de sessão nunca trafeguem em
   texto puro. Ao colocar um proxy na frente, mantenha a senha ligada, porque
   uma requisição vinda de proxy é tratada como pública.

2. **Mantenha tudo em loopback e entre por um túnel**, sem abrir nada na rede:

```bash
pepe serve --tunnel                     # túnel rápido da Cloudflare, embutido (precisa do cloudflared)
ssh -L 4000:localhost:4000 voce@servidor  # depois acesse http://localhost:4000
tailscale serve 4000                    # uma tailnet privada, sem porta pública
```

O `pepe serve --tunnel` roda o `cloudflared` e imprime uma URL pública
`https://<...>.trycloudflare.com`, válida enquanto o processo estiver de pé.
Como o túnel é um proxy, uma requisição vinda por ele conta como pública, então
defina uma senha do painel antes de usá-lo. O passo a passo completo, incluindo
túneis nomeados com uma URL estável escolhida por você, está na página do
[Painel](../dashboard/#acesso-remoto).

Já o `ssh -L` e um redirecionamento de porta do Multipass chegam pelo loopback,
então funcionam sem senha nenhuma. Uma VM acessada pela própria rede virtual
parece remota e acaba bloqueada, então redirecione a porta dela para o
`localhost`.

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

* Os **hosts permitidos** funcionam como defesa contra DNS rebinding. Sem
  senha, o painel aceita só um `Host` de **loopback** (`localhost`,
  `127.0.0.1`, `::1`) e recusa qualquer outro nome com **400**, o que impede
  uma página maliciosa de reapontar um domínio para a sua máquina e dirigir o
  painel local. Ao servir sob um domínio de verdade, liste-o aqui, com uma
  senha ligada. Uma lista vazia junto com uma senha aceita qualquer host,
  porque nesse caso a senha já é a barreira.
* Os **proxies confiáveis** decidem quando o `X-Forwarded-For` é acreditado.
  Por padrão ele é ignorado e uma requisição vinda de proxy é tratada como
  remota, a escolha que fecha por padrão. Liste seu proxy aqui e o Pepe passa
  a tirar o IP real do cliente da cadeia encaminhada, de modo que tanto a
  regra de loopback contra remoto quanto o limite de tentativas de login
  enxerguem o par verdadeiro, em vez do proxy.

### Proteção contra força bruta

O `POST /login` tem limite de taxa por IP de cliente, 10 tentativas a cada 60
segundos por padrão, e um login bem-sucedido zera o contador. Isso soma-se à
comparação de senha em tempo constante e a um pequeno atraso a cada falha.
Passar do limite devolve **429** com um cabeçalho `Retry-After`.

### Estendendo a autenticação

A barreira é pequena e componível de propósito: um hook `on_mount`
(`PepeWeb.Auth`), um plug (`PepeWeb.NetworkGuard`, apoiado em `Pepe.Net` e
`PepeWeb.RemoteClient`) e o limitador de login. Esquemas mais ricos, como
OAuth, cabeçalhos de identidade vindos de um proxy confiável ou contas por
operador, encaixam sem precisar mexer em cada LiveView.

## Autenticação e tokens

Com **zero tokens configurados, a API só responde a chamadas vindas da própria
máquina (loopback)**. Um `curl` local ou o painel funcionam sem token nenhum,
mas qualquer chamada remota é recusada com `401`, então um servidor exposto
numa rede nunca fica anônimo.

Criar o primeiro token muda esse jogo para todo mundo: a partir do momento em
que qualquer token existe, toda requisição, local ou remota, precisa
apresentar um válido, ou é recusada com `401`. É gerar o primeiro token que
libera o acesso remoto.

### Gerar e gerenciar tokens

Dá para gerar, listar e revogar tokens de três formas: pela CLI, pelo painel
ou pela conversa.

Pela CLI:

```bash
pepe token add [--project PROJ] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

No painel, a página de tokens da API traz um formulário para gerar um token
(com um projeto e um escopo de agente opcional) e uma lista para revogar os já
existentes.

Um token é uma string aleatória com o prefixo `pepe_`. No arquivo de
configuração fica guardado só o hash SHA-256 dele; o token bruto é impresso
uma única vez, na criação, e nunca mais aparece. Copie naquele momento; se
perdê-lo, revogue-o e gere um novo.

#### Faça pela conversa

Um agente com a ferramenta protegida `manage_token` consegue gerar, listar e
revogar tokens direto de uma conversa. Como um token dá acesso à API, essa
ferramenta não é somente leitura: ela passa pela barreira de permissão, então
você confirma antes de um token ser criado, e o segredo bruto é devolvido uma
única vez para você copiar.

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

Qualquer SDK da OpenAI já envia a forma `Authorization: Bearer` ao definir a
`api_key` dele, então a autenticação não pede nenhum tratamento especial do
lado do cliente.

### Escopos de token

Um token carrega um escopo, e é ele que decide quais agentes o token consegue
alcançar. Do mais estreito ao mais amplo:

* **Fixado em um agente** (`--agent HANDLE`): roda sempre exatamente aquele
  agente, ignorando o campo `model` da requisição. Entregue isso a quem só
  deve alcançar um agente específico.
* **Projeto** (`--project PROJ`): qualquer agente dentro daquele projeto. Um
  nome de `model` puro se qualifica automaticamente dentro daquele projeto, e
  uma requisição para um agente de outro projeto é recusada com `403`.
* **Nenhum dos dois**: o projeto default, o escopo em que opera todo comando
  quando você não especifica nada. Alcança os agentes do default (aqueles com
  nome puro, sem namespace) e, de forma única entre os três, ainda recorre a
  conexões de modelo puras pelo nome.

### Permissões de token

O escopo diz *de quem* são os dados que o token alcança. Um conjunto separado
de permissões diz *o que ele pode fazer* com eles. Os padrões deixam todo
token que você já criou exatamente como estava: ele **pode** rodar agentes e
**não pode** ler consumo.

| Flag | Padrão | O que libera |
| --- | --- | --- |
| `--chat` / `--no-chat` | ligado | rodar agentes (`/v1/chat/completions`, o WebSocket) |
| `--usage` | desligado | ler o `/v1/usage`, os números de cobrança |
| `--prices` | `billable` | quanto dos valores uma leitura de consumo mostra |
| `--content` | desligado | o detalhe de uma execução pode incluir o prompt e os argumentos e a saída das ferramentas |

```bash
# token de cobrança somente leitura para um cliente: lê os números, não gasta seu orçamento
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions abc123 --prices list    # muda no lugar, sem mexer no segredo
```

As duas metades são independentes de propósito. Sem essa separação, dar a um
cliente visibilidade do próprio gasto significaria entregar junto uma
credencial capaz de rodar agentes na sua conta. Veja a
[API de consumo](../usage-api/) para o que essas leituras devolvem.

### O que cada escopo enxerga em `GET /v1/models`

| Token | Retorna |
|---|---|
| `--project acme` | só os agentes de `acme` |
| `--project globex` | só os agentes de `globex` |
| `--agent acme/support` | só aquele agente |
| projeto default (sem flag) | os agentes do projeto default, mais as conexões de modelo puras |
| sem token (só loopback) | todos os agentes, de todos os projetos, mais as conexões de modelo puras |

Um token nunca atravessa essa fronteira: um token de `acme` jamais lista nem
alcança um agente de `globex`. Não existe token que nomeie outro projeto para
lê-lo; para pegar os agentes de outro projeto, gere o próprio token daquele
projeto. Para uma visão de operador que cruze projetos, use a CLI
(`pepe agent list`) ou o painel, nunca um token de tenant.

## Roteamento multiprojeto: dê ao projeto X seu próprio acesso

Os escopos são a forma de distribuir acesso à API por tenant. Para dar a um
projeto a própria chave, gere um token com escopo de projeto:

```bash
pepe token add --project acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quem tiver esse token:

* consegue alcançar pelo nome qualquer agente que pertença a `acme`;
* consegue enviar um nome de `model` puro e vê-lo se resolver dentro de
  `acme`;
* é recusado com `403` ao nomear um agente de outro projeto;
* enxerga só os agentes de `acme` em `GET /v1/models`.

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

Para prender um token a exatamente um agente (o campo `model` passa então a
ser totalmente ignorado), adicione `--agent`:

```bash
pepe token add --project acme --agent acme/support --label "widget de suporte da Acme"
```
