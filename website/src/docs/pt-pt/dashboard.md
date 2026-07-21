---
title: Painel
description: Usa a interface web local para inspecionar e gerir agentes, modelos, canais e execuções.
---

O painel é a interface web local iniciada por `pepe serve`. Usa-o para conversar com agentes, inspecionar traces, gerir ligações de modelo, configurar canais, rever tarefas agendadas e gerar tokens de API sem editar JSON à mão.

```bash
pepe serve          # API, painel e gateways, tudo num só processo
# depois abre http://localhost:4000
```

A partir de um clone do código-fonte, gera os assets uma vez com `mix assets.build` antes de correr `mix pepe serve`.

## Sessões e conversa

O painel abre com uma lista viva de sessões à esquerda e um painel de conversa com streaming à direita. Escolhe uma sessão para ler o histórico dela e falar com o agente dela, e a resposta chega token a token. O `New chat` inicia uma sessão nova, e cada sessão mostra o agente, o modelo e a contagem de turnos; uma sessão a correr um turno neste momento ganha um indicador em direto, com um botão `Stop` ali mesmo na lista para interromper uma que ficou presa, sem teres de a abrir primeiro.

As sessões vivem dentro do processo em execução, por isso corre tudo a partir do único processo `pepe serve`. Assim o painel vê todas as sessões, incluindo as que chegaram pelo Telegram.

As ferramentas arriscadas também são autorizadas ali mesmo. A execução pára e mostra um pedido de permitir/recusar, que é a versão web dos botões que um utilizador do Telegram recebe, a menos que o agente já tenha essa ferramenta pré-aprovada. O agente proprietário omnipotente nunca pergunta. Vê [Segurança e ambiente isolado](../security/) para perceber como a barreira decide.

## O que a barra lateral tem

A barra lateral espelha a CLI, por isso quase tudo o que fazes com o comando `pepe` também podes fazer aqui:

- **Chat**: conversar com uma sessão.
- **Projetos**: criar, editar e eliminar projetos e a margem de faturação de cada um. Vê [Projetos](../projects/).
- **Agents**: criar, editar e eliminar agentes, com persona, modelo, ferramentas, rotas, âmbito de administração e qual deles é o predefinido.
- **Models**: acrescentar, remover e editar ligações de modelo, definir um preço por modelo e escolher o predefinido.
- **Usage and billing**: utilização de tokens e custo por ciclo, por projeto. Vê [Utilização e faturação](../billing/).
- **Learning**: a linha temporal do TimeLearn. Vê [Aprendizagem](../learning/).
- **Scheduled**: criar, executar e gerir tarefas agendadas. Vê [Tarefas agendadas](../scheduled/).
- **Watches**: o "avisa-me quando X" de uma só vez. Vê [Watches](../watches/).
- **Channels**: acrescentar, remover e editar bots do Telegram, aplicado em direto. Vê [Telegram](../telegram/).
- **MCP**: servidores de ferramentas externas. Vê [Servidores MCP](../mcp/).
- **Config file**: editar o `~/.pepe/config.json` ali mesmo, com validação ao guardar.

## Manter em execução

O `pepe serve` corre em primeiro plano: fechar o terminal ou terminar sessão pára o processo, e o painel com ele. Para um deploy a sério, instala-o como serviço persistente em segundo plano: launchd no macOS, systemd `--user` no Linux. Sobrevive a logout/reboot e reinicia-se sozinho se cair.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Só funciona a partir do binário `pepe` instalado, não em `mix pepe serve install`. Se as tuas ligações de modelo referenciam segredos `${ENV_VAR}`, o `install` lista-os: o serviço arranca com um ambiente mínimo, por isso precisam de ser adicionados à mão no ficheiro gerado.

## Acesso ao painel

O painel web fica aberto em localhost por predefinição, o que é cómodo para o desenvolvimento local. No momento em que o expões para além da tua máquina, coloca-o atrás de uma palavra-passe:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Podes passar uma palavra-passe literal ou uma referência `${ENV_VAR}` para que o segredo fique fora do ficheiro. Uma vez definida a palavra-passe, o painel exige iniciar sessão em `/login`. Limpa-a com `pepe dashboard password --clear`.

A palavra-passe é lida de `dashboard.password` na configuração (interpolada), com recurso a variável de ambiente `PEPE_DASHBOARD_PASSWORD`. Duas definições relacionadas reforçam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores adicionais do cabeçalho `Host` que o painel aceita. Isto serve também de lista de permissões contra DNS rebinding.
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies inversos cujo cabeçalho `X-Forwarded-For` pode ser considerado fidedigno. Vazio por predefinição, o que significa que nenhum cabeçalho de encaminhamento é considerado fidedigno.

Vinculado a uma interface pública sem palavra-passe, o painel fecha por predefinição e bloqueia os clientes remotos até definires uma.

## Acesso remoto

Para aceder ao painel ou à API a partir de fora da tua máquina sem abrir uma porta nem montar um proxy inverso, o `pepe serve` pode abrir um túnel da [Cloudflare](https://www.cloudflare.com/) (precisa do `cloudflared` instalado):

```bash
pepe serve --tunnel
```

É um **túnel rápido**: imprime um URL aleatório `https://<algo>.trycloudflare.com` que só dura enquanto o processo corre e muda de cada vez. Não é preciso conta na Cloudflare.

Para um **URL fixo que tu escolhes** no teu próprio domínio, usa um túnel nomeado. Duas formas:

```bash
# Sem navegador (ideal num servidor): cria o túnel e o hostname público no
# painel do Cloudflare Zero Trust, aponta o serviço dele para http://localhost:4000,
# copia o token do conector e depois:
pepe serve --tunnel --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

# Ou com um início de sessão único no navegador (guarda um cert.pem), sem token:
cloudflared tunnel login
pepe serve --tunnel --hostname pepe.example.com
```

Com `--token`, o hostname e o mapeamento de serviço ficam no painel da Cloudflare; aí o `--hostname` é opcional, só para imprimir o URL no arranque. O token é um segredo, por isso passa-o como referência `${ENV_VAR}`. Um pedido pelo túnel é sempre tratado como público, por isso define uma palavra-passe do painel antes de depender de qualquer um destes modos.
