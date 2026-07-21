---
title: Painel
description: Use a interface web local para inspecionar e gerenciar agentes, modelos, canais e execuções.
---

O painel é a interface web local iniciada por `pepe serve`. Use-o para conversar com agentes, inspecionar traces, gerenciar conexões de modelo, configurar canais, revisar tarefas agendadas e gerar tokens de API sem editar JSON à mão.

```bash
pepe serve          # API, painel e gateways, tudo em um processo só
# depois abra http://localhost:4000
```

A partir de um clone do código-fonte, gere os assets uma vez com `mix assets.build` antes de rodar `mix pepe serve`.

## Sessões e conversa

O painel abre com uma lista viva de sessões à esquerda e um painel de conversa com streaming à direita. Escolha uma sessão para ler o histórico dela e falar com o agente dela, e a resposta chega token a token. O `New chat` começa uma sessão nova, e cada sessão mostra o agente, o modelo e a contagem de turnos; uma sessão que está rodando um turno agora ganha um indicador ao vivo, com um botão `Stop` ali mesmo na lista para interromper uma que travou, sem precisar abrir primeiro.

As sessões vivem dentro do processo em execução, então rode tudo a partir do único processo `pepe serve`. Assim o painel enxerga todas as sessões, inclusive as que chegaram pelo Telegram.

As ferramentas arriscadas também são autorizadas ali mesmo. A execução pausa e mostra um pedido de permitir/negar, que é a versão web dos botões que um usuário do Telegram recebe, a menos que o agente já tenha aquela ferramenta pré-aprovada. O agente dono onipotente nunca pergunta. Veja [Segurança e ambiente isolado](../security/) para entender como a barreira decide.

## O que tem na barra lateral

A barra lateral espelha a CLI, então quase tudo que você faz com o comando `pepe` também dá para fazer aqui:

- **Chat**: conversar com uma sessão.
- **Projects**: criar, editar e excluir projetos e a margem de cobrança de cada um, inclusive o projeto default. Veja [Projetos](../projects/).
- **Agents**: criar, editar e excluir agentes, com persona, modelo, ferramentas, rotas, escopo de administração e qual deles é o padrão.
- **Models**: adicionar, remover e editar conexões de modelo, definir um preço por modelo e escolher o padrão.
- **Usage and billing**: uso de tokens e custo por ciclo, por projeto. Veja [Uso e cobrança](../billing/).
- **Learning**: a linha do tempo do TimeLearn. Veja [Aprendizado](../learning/).
- **Scheduled**: criar, rodar e gerenciar tarefas agendadas. Veja [Tarefas agendadas](../scheduled/).
- **Watches**: o "me avise quando X" de uma vez só. Veja [Watches](../watches/).
- **Channels**: adicionar, remover e editar bots do Telegram, aplicado ao vivo. Veja [Telegram](../telegram/).
- **MCP**: servidores de ferramentas externas. Veja [Servidores MCP](../mcp/).
- **Config file**: editar o `~/.pepe/config.json` na hora, com validação ao salvar.

## Mantendo o painel no ar

O `pepe serve` roda em primeiro plano: fechar o terminal ou sair da sessão encerra o processo, e o painel junto. Para um deploy de verdade, instale como serviço persistente em segundo plano: launchd no macOS, systemd `--user` no Linux. Ele sobrevive a logout/reboot e reinicia sozinho se cair.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Só funciona no binário `pepe` instalado, não em `mix pepe serve install`. Se suas conexões de modelo referenciam segredos `${ENV_VAR}`, o `install` lista quais são, porque o serviço sobe com um ambiente mínimo e eles precisam ser adicionados à mão no arquivo gerado.

## Acesso ao painel

O painel web fica aberto em localhost por padrão, o que é conveniente para o desenvolvimento local. No momento em que você o expõe além da sua máquina, coloque-o atrás de uma senha:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Você pode passar uma senha literal ou uma referência `${ENV_VAR}` para que o segredo fique fora do arquivo. Uma vez definida a senha, o painel exige entrar em `/login`. Limpe-a com `pepe dashboard password --clear`.

A senha é lida de `dashboard.password` na configuração (interpolada), com fallback para a variável de ambiente `PEPE_DASHBOARD_PASSWORD`. Dois ajustes relacionados reforçam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores extras do cabeçalho `Host` que o painel aceita. Isso serve também como a lista de permissão contra DNS rebinding.
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies reversos cujo cabeçalho `X-Forwarded-For` pode ser considerado confiável. Vazio por padrão, o que significa que nenhum cabeçalho de encaminhamento é confiável.

Vinculado a uma interface pública sem senha, o painel se fecha por padrão e bloqueia clientes remotos até que você defina uma.

## Acesso remoto

Para acessar o painel ou a API de fora da sua máquina sem abrir uma porta nem montar um proxy reverso, o `pepe serve` pode abrir um túnel da [Cloudflare](https://www.cloudflare.com/) (precisa do `cloudflared` instalado):

```bash
pepe serve --tunnel
```

É um **túnel rápido**: imprime uma URL aleatória `https://<algo>.trycloudflare.com` que só dura enquanto o processo roda e muda a cada vez. Não precisa de conta na Cloudflare.

Para uma **URL fixa que você escolhe** no seu próprio domínio, use um túnel nomeado. Duas formas:

```bash
# Sem navegador (ideal em um servidor): crie o túnel e o hostname público no
# painel do Cloudflare Zero Trust, aponte o serviço dele para http://localhost:4000,
# copie o token do conector e então:
pepe serve --tunnel --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

# Ou com um login único no navegador (salva um cert.pem), sem token:
cloudflared tunnel login
pepe serve --tunnel --hostname pepe.example.com
```

Com `--token`, o hostname e o mapeamento de serviço ficam no painel da Cloudflare; ali o `--hostname` é opcional, só para imprimir a URL no boot. O token é um segredo, então passe como referência `${ENV_VAR}`. Uma requisição pelo túnel é sempre tratada como pública, então defina uma senha do painel antes de depender de qualquer um desses modos.
