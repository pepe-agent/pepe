---
title: Referência da CLI
description: Todos os comandos do pepe, organizados pelo que cada um gerencia, conexões de modelo, agentes, projetos, tokens, o dashboard, e mais.
---

Tudo o que o Pepe faz está acessível pela linha de comando, e a organização aqui segue a
lógica de uso, não a ordem alfabética: primeiro o que você quer fazer, depois o comando.
Os exemplos usam o binário `pepe` já instalado; rodando a partir de um checkout do
código-fonte, troque por `mix pepe` no lugar, os subcomandos são idênticos nos dois casos.

```bash
pepe help              # a lista completa de comandos
pepe help <grupo>       # ex.: pepe help agent
```

## Configuração inicial

```bash
pepe setup   # na primeira execução: assistente guiado (idioma -> modelo -> agente -> Telegram)
              # nas seguintes: um menu para adicionar ou reconfigurar qualquer parte
```

## Conexões de modelo

```bash
pepe model                       # mostra o padrão, troca entre os salvos, ou adiciona um novo
pepe model add openai            # guiado: escolhe provedor -> método de login -> modelo
pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # totalmente manual
pepe model providers             # lista provedores conhecidos (OpenAI, Anthropic, Gemini, ...)
pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
pepe model list                  # lista as conexões salvas
pepe model test [NOME]           # testa uma conexão para confirmar que a chave e o endpoint funcionam
pepe model reconnect openai      # refaz o login para consertar uma conexão quebrada, sem tocar no resto
pepe model remove openrouter
pepe model default openai
```

Já assina o ChatGPT/Codex ou o Claude Pro/Max? Em vez de colar uma chave de API, dá para
adicionar **entrando com essa conta**: `pepe model add openai` -> "ChatGPT / Codex
subscription" abre o navegador, você faz login, e o Pepe assume dali para frente. Veja
[Modelos](../models/).

Quando uma conexão dessas para de funcionar (um login que expirou, ou uma saída de conta
em outro lugar), `pepe model reconnect NOME` refaz o login e conserta no lugar, sem mudar
mais nada: todo agente que já usava essa conexão segue funcionando sem precisar de ajuste
nenhum. Remover e recriar não é a solução aqui, isso recomeça do zero e joga fora qualquer
preço ou configuração personalizada que você tinha guardado.

## Agentes

```bash
pepe agent add assistant \
  --prompt "Você é um agente de programação útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # deixa o assistant mandar mensagem para o helper (ver Rotas)
pepe agent manage boss assistant     # deixa o boss administrar o assistant ("*" = todos)
pepe agent rename assistant helper   # renomeia + move a pasta de trabalho dele
pepe agent remove helper
pepe agent default assistant
```

Veja [Agentes](../agents/) para o que cada opção faz.

## Projetos (rodando mais de um cliente ou time)

Quem roda o Pepe para vários clientes ou times numa mesma instalação separa cada um em um
**projeto**, com agentes e dados próprios, isolados dos demais. Sem `--project`, tudo cai
no projeto padrão, exatamente como sempre funcionou uma instalação de cliente único. Veja
[Projetos](../projects/).

```bash
pepe project add acme --description "Acme Inc"     # cria um novo cliente/projeto
pepe project list
pepe project rename acme umbrella                  # renomeia; nada mais quebra
pepe agent add sales --project acme --prompt "..."  # agente "acme/sales"
pepe agent list --project acme                     # só os agentes da Acme
pepe agent list --all                              # todos os projetos
pepe run acme/sales "olá"                          # roda pelo handle dele
pepe project remove acme --force                   # apaga o projeto + os agentes dele
```

## Executando

```bash
pepe run "liste os arquivos aqui e resuma o projeto"   # one-shot, transmite para o stdout
pepe run assistant "olá"                                # escolhendo um agente específico
pepe chat                            # conversa interativa, lembra o que foi dito antes
pepe chat --agent assistant          # ...com um agente específico (ou: pepe chat assistant)
pepe goal "publica as notas de versão" \
  --criteria "CHANGELOG tem uma seção datada" --max-attempts 5   # insiste até dar certo de verdade
pepe serve --port 4000               # sobe API, dashboard e WebSocket juntos
pepe serve --port 4000 --bind lan     # ...acessível de outras máquinas, não só desta
pepe serve install [--port 4000]     # deixa rodando em segundo plano para sempre
pepe serve status                    # está instalado e rodando?
pepe serve uninstall                 # para e remove
```

`goal` não se dá por satisfeito na primeira tentativa: um revisor independente confere o
resultado contra `--criteria`, e o Pepe tenta de novo (até `--max-attempts` vezes) enquanto
não passar de verdade. Para revisar com outro modelo, use `--judge MODELO`. Veja
[Metas](../goals/).

`serve install` faz o Pepe subir sozinho no boot e continuar rodando em segundo plano por
logout, reinício ou queda. Só funciona a partir do app `pepe` instalado, não de um checkout
do código-fonte, e o `--bind` também se aplica a ele (`serve install --bind lan`).

Por padrão, `serve` escuta só em `127.0.0.1`: só esta máquina consegue chegar até ele, já
que um `serve` puro não tem proxy reverso na frente, e a API `/v1` fica aberta sem
autenticação enquanto nenhum token for configurado. `--bind lan` abre para todas as
interfaces de rede; antes disso, configure uma senha do dashboard (`pepe dashboard
password`), ou use `--tunnel` para expor publicamente sem alargar o bind. Esse padrão não
vale para a imagem Docker oficial, que sempre escuta em todas as interfaces, veja
[Publicando em um servidor](../deploy/) para entender o motivo.

`chat` (também chamado de `tui`) abre uma conversa direto no terminal, mantendo o contexto
conforme você segue usando. Digite `/help` lá dentro para ver todos os atalhos disponíveis:
nova conversa, desfazer, voltar algumas trocas, trocar de agente ou modelo, entre outros.

## Gateway do Telegram

```bash
pepe gateway telegram setup      # interativo: token do bot, quem pode falar com ele, qual agente
pepe gateway telegram            # roda em primeiro plano
```

Veja [Telegram](../telegram/) para como funcionam o acesso e vários bots ao mesmo tempo.

## Tokens de acesso à API

São as chaves que outros apps usam para falar com o Pepe por HTTP ou WebSocket. Sem
nenhuma criada, só pedidos vindos da própria máquina são aceitos; assim que a primeira
existe, todo pedido passa a exigir um token válido. Um token pode ficar limitado a um
projeto (`--project`) ou a um agente (`--agent HANDLE`). Veja [API HTTP](../api/).

```bash
pepe token add --project acme --label "app mobile da acme"   # mostra a chave uma vez só, guarde agora
pepe token add --agent acme/sales --label "uma integração"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # seguro para colocar no código público de uma página
pepe token list                        # id, escopo, permissões, label
pepe token update <id> --greeting "Oi! Como posso ajudar?"
pepe token revoke <id>
```

O escopo decide *de quem* são os dados que o token alcança; as permissões decidem *o que*
ele pode fazer com eles. Por isso dá para entregar a alguém um token que só lê relatório de
cobrança, sem que ele consiga conversar com nenhum agente. Veja [Uso e cobrança](../billing/).

```bash
# um token só de cobrança: lê /v1/usage, não roda agente, e vê só o que o cliente
# realmente paga (--prices list esconde sua margem; --prices all mostra ela também)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # muda no lugar, a chave continua a mesma
pepe token permissions <id> --no-usage
```

## Watches ("me avisa quando X acontecer")

Confere alguma coisa periodicamente e avisa **uma única vez**, no momento em que aquilo
acontecer, e depois para sozinho. Veja [Watches](../watches/).

```bash
pepe watch add "site no ar" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Tarefas agendadas

Tarefas de agente que se repetem numa agenda, como um cron. Veja [Tarefas
agendadas](../scheduled/).

```bash
pepe cron list
pepe cron add --name "resumo diário" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # dispara agora, fora do horário programado
pepe cron logs <id>
```

## Flows (repetir algo que já deu certo, sem repensar)

Depois que um agente resolve a mesma coisa do mesmo jeito algumas vezes, vale transformar
essa sequência num `flow` batizado com um nome: da próxima vez ele reproduz tudo direto,
mais rápido e sem pedir ao modelo para reconstruir o raciocínio do zero. Veja
[Flows](../flows/).

```bash
pepe flow list AGENTE
pepe flow promote NOME --agent AGENTE --from ID1,ID2[,...] [--overwrite]
pepe flow show AGENTE NOME
pepe flow remove AGENTE NOME
pepe flow run AGENTE NOME                                    # roda agora
pepe flow schedule AGENTE NOME --schedule "..." [--timezone TZ] [--deliver ...]
```

## Aprendizado

```bash
pepe timelearn [AGENTE]                 # o que o agente foi aprendendo, ao longo do tempo
pepe learn consolidate [AGENTE]         # organiza isso agora mesmo
pepe learn auto [AGENTE] [--at CRON]    # faz isso automaticamente toda noite (--off desliga)
pepe learn status                       # quais agentes estão configurados para isso
```

Veja [Aprendizado](../learning/) para saber o que de fato fica registrado.

## Uso, cobrança e traces

```bash
pepe usage                                  # tokens e custo por ciclo, por projeto
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # uma linha por conversa
pepe usage runs <id>                        # aquela conversa, passo a passo
pepe usage export --project acme            # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices [--refresh]               # vê ou atualiza os preços atuais de modelo
pepe traces [--project NOME] [--limit N]    # atividade recente, de qualquer canal
pepe traces <id>                            # reproduz uma execução passo a passo
```

Esses mesmos números também saem por HTTP, com um token com escopo de uso. Veja [Uso e
cobrança](../billing/).

## Servidores de tools, plugins e hooks de privacidade

```bash
pepe mcp add NOME --command npx --args "..."       # um servidor de tools local
pepe mcp add NOME --url URL --header "K: V"        # um servidor de tools remoto (HTTP)
pepe mcp list | tools NOME | remove NOME           # inspeciona e gerencia
pepe mcp login|logout NOME                         # faz login num servidor de tools remoto
pepe plugin list | install | scan | remove         # tools e canais extras
pepe plugin route list | enable NOME | disable NOME  # endpoint web próprio de um plugin
pepe skill list | search | install | update | remove | audit | tap  # marketplace de skills
pepe db add | list | remove              # deixa um agente consultar um banco externo
pepe slot list | set | clear             # qual plugin cuida de uma capacidade específica
pepe policy list                         # regras de permissão instaladas e onde valem
pepe policy scope NOME --agents a,b [--projects x,y] | --clear   # limita onde uma regra vale
pepe hooks list                          # hooks de privacidade disponíveis
pepe hooks generate "oculta CPFs" [--model NOME] [--save]   # a IA escreve um para você
```

Veja [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Banco de
dados](../database/) e [Privacidade e hooks](../privacy/).

## Qualidade e operações

```bash
pepe eval [SUITE]                # roda um conjunto de prompts de teste num agente
pepe doctor [--offline]          # confere se está tudo certo na configuração
pepe review [approve|reject ID]  # aprova ou rejeita mudanças que um agente fez sozinho
pepe backup [--output ARQUIVO.tgz]  # salva tudo (config, agentes, conversas, banco)
pepe backup verify ARQUIVO.tgz      # confere se um backup está íntegro
pepe restore ARQUIVO.tgz [--force]  # traz um backup de volta
pepe migrate ORIGEM [--dry-run]  # importa modelos/agentes de outra ferramenta
pepe update                      # atualiza para última versão
pepe browser install             # prepara o navegador que um agente pode usar
```

Veja [Avaliações](../evals/), [Backup](../backup/) e [Navegador](../browser/).

## Dashboard

A senha é opcional. Sem ela, o dashboard só abre na máquina onde está rodando; qualquer
tentativa de fora é bloqueada. Veja [Autenticação](../auth/) e [Dashboard](../dashboard/).

```bash
pepe dashboard                            # mostra as configurações atuais
pepe dashboard password                   # define uma, digitada escondida, nada aparece na tela
pepe dashboard hosts app.example.com      # libera o acesso por um domínio (--clear reseta)
pepe dashboard trusted-proxies 10.0.0.0/8 # necessário atrás de um proxy reverso
```

## Diversos

```bash
pepe tools     # lista toda tool que um agente pode usar
pepe config    # onde fica o arquivo de config, e um resumo rápido
pepe help      # ajuda completa de comandos (ou: pepe help <grupo>)
```
