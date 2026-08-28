---
title: Painel
description: A interface web local para inspecionar e gerir agentes, modelos, canais e execuções.
---

O painel é a interface web local que o `pepe serve` arranca. Serve para conversar com
agentes, inspecionar traces, gerir ligações de modelo, configurar canais, rever tarefas
agendadas e gerar tokens de API sem teres de editar JSON à mão.

```bash
pepe serve          # API, painel e gateways, tudo no mesmo processo
# depois abre http://localhost:4000
```

A partir de um checkout do código-fonte, gera os assets uma vez com `mix assets.build`
antes de correres `mix pepe serve`.

## Sessões e conversa

O painel abre já com uma lista de sessões ao vivo à esquerda, e um painel de conversa
com streaming à direita. Escolhe uma sessão para ler o histórico e falar com o agente
dela: a resposta vai chegando token a token. O botão "New chat" arranca uma sessão nova,
e cada sessão mostra o seu agente, o seu modelo e quantos turnos já teve; uma que esteja a
correr um turno neste preciso momento ganha um pequeno indicador ao vivo, com um botão
"Stop" logo ali na lista para interromperes uma que tenha ficado presa sem precisares de
a abrir primeiro.

As sessões vivem dentro do processo em execução, por isso corre tudo a partir do mesmo
`pepe serve`; assim o painel vê todas as sessões, incluindo as que chegaram pelo
Telegram.

As ferramentas arriscadas também se autorizam por aqui: a execução pára e mostra um
pedido de permitir ou recusar, a versão web dos botões que um utilizador do Telegram já
recebe, a menos que o agente já tenha essa ferramenta pré-aprovada. O agente
proprietário, esse omnipotente, nunca pergunta nada. Como a barreira decide isto está em
[Segurança e sandbox](../security/).

## O que a barra lateral traz

A barra lateral espelha a CLI: praticamente tudo o que dá para fazer com o comando `pepe`
também dá para fazer por aqui.

- **Chat**: conversar com uma sessão.
- **Projetos**: criar, editar e apagar âmbitos de cliente e a respetiva margem de
  faturação. Ver [Projetos](../projects/).
- **Agents**: criar, editar e apagar agentes, incluindo a sua persona, modelo,
  ferramentas, rotas, âmbito de administração, e qual deles é o predefinido.
- **Models**: acrescentar, remover e editar ligações de modelo, definir um preço por
  modelo, e escolher qual é a predefinida.
- **Usage and billing**: utilização de tokens e custo por ciclo, por projeto. Ver
  [Utilização e faturação](../billing/).
- **Learning**: a linha temporal do TimeLearn. Ver [Aprendizagem](../learning/).
- **Scheduled**: criar, correr e gerir tarefas agendadas. Ver [Tarefas
  agendadas](../scheduled/).
- **Watches**: o "avisa-me quando X" que dispara uma única vez. Ver
  [Watches](../watches/).
- **Channels**: acrescentar, remover e editar bots do Telegram, com efeito imediato. Ver
  [Telegram](../telegram/).
- **MCP**: os servidores de ferramentas externas. Ver [Servidores MCP](../mcp/).
- **Config file**: editar o `~/.pepe/config.json` diretamente ali, com validação ao
  gravar.

## Manter em execução

O `pepe serve` corre em primeiro plano: fechar o terminal, ou terminar sessão, pára o
processo e o painel junto com ele. Para um deployment a sério, o certo é instalá-lo
como serviço persistente em segundo plano, launchd no macOS, systemd `--user` no Linux.
Assim sobrevive a um logout ou reinício, e volta a arrancar sozinho se cair.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Isto só funciona a partir do binário `pepe` já instalado, nunca com
`mix pepe serve install`. Se alguma das tuas ligações de modelo referenciar segredos
`${ENV_VAR}`, o `install` lista-os, porque o serviço arranca com um ambiente mínimo e
essas variáveis têm de ser acrescentadas à mão no unit/plist gerado.

## Acesso ao painel

Por predefinição, o painel está aberto em localhost, o que é prático para
desenvolvimento local. No instante em que o expões para lá da tua própria máquina,
coloca-o atrás de uma palavra-passe:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Dá para passar uma palavra-passe literal ou uma referência `${ENV_VAR}`, para o segredo
ficar fora do ficheiro. Uma palavra-passe literal passa por hash antes de ser gravada na
configuração, por isso deixa de ser legível a partir do ficheiro (ou de uma cópia de
segurança dele) assim que é definida. Já uma referência `${ENV_VAR}` não tem nada para
fazer hash, porque o segredo verdadeiro já vive fora do ficheiro à partida. Depois de
definida a palavra-passe, o painel passa a exigir login em `/login`. Para a remover,
usa `pepe dashboard password --clear`.

Corre `pepe dashboard password` sem valor nenhum e é-te pedida de forma interativa, com o
que escreves escondido no ecrã, útil para a palavra-passe nunca aparecer no histórico da
shell nem numa listagem de `ps`:

```bash
pepe dashboard password
```

A palavra-passe é lida de `dashboard.password` na configuração (já interpolada), com a
variável de ambiente `PEPE_DASHBOARD_PASSWORD` como alternativa. Há duas definições
relacionadas que reforçam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores extra do
  cabeçalho `Host` que o painel aceita, servindo ao mesmo tempo de lista branca contra
  DNS rebinding.
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies inversos cujo
  cabeçalho `X-Forwarded-For` pode ser considerado de confiança. Por predefinição está
  vazia, o que significa que nenhum cabeçalho de encaminhamento é confiado.

Se ficar acessível a partir de fora da tua máquina sem nenhuma palavra-passe definida, o
painel bloqueia por predefinição todos os clientes remotos até definires uma: só a
própria máquina consegue abri-lo, e uma VM, um proxy, ou a rede do escritório contam como
"fora" (falha fechado, não aberto).

## Acesso remoto

Para chegar ao painel ou à API vindo de fora da tua máquina sem abrir uma porta nem
montar um proxy inverso, o `pepe serve` consegue abrir um túnel da
[Cloudflare](https://www.cloudflare.com/) (precisa do `cloudflared` instalado):

```bash
pepe serve --tunnel
```

Isto é um **túnel rápido**: mostra um URL aleatório `https://<algo>.trycloudflare.com`
que só dura enquanto o processo estiver a correr, e muda sempre que arrancas de novo. Não
precisa de conta na Cloudflare.

Para um **URL estável, escolhido por ti**, no teu próprio domínio, usa antes um túnel
nomeado. Há duas formas:

```bash
# Sem interface (ideal num servidor): cria o túnel e o seu hostname público no
# dashboard do Cloudflare Zero Trust, aponta o serviço dele para http://localhost:4000,
# copia o token do conector, e depois:
pepe serve --tunnel --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

# Ou com um login único pelo browser (fica guardado um cert.pem), sem token nenhum:
cloudflared tunnel login
pepe serve --tunnel --hostname pepe.example.com
```

Com `--token`, o hostname e o mapeamento do serviço ficam definidos no dashboard da
Cloudflare, e por isso o `--hostname` passa a ser opcional, servindo só para mostrar o
URL no arranque. O token é um segredo, por isso passa-o sempre como referência
`${ENV_VAR}`. Um pedido que passe pelo túnel é sempre tratado como público, por isso
define uma palavra-passe do painel antes de confiares em qualquer uma destas opções.
