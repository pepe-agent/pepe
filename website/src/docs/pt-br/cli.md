---
title: Referência da CLI
description: Todos os comandos do pepe, agrupados pelo que gerenciam: conexões de modelo, agentes, projetos, tokens, o dashboard, e mais.
---

Tudo no Pepe é alcançável pela linha de comando, agrupado aqui do jeito que você
realmente vai procurar: pelo que você está tentando fazer, não em ordem alfabética.
Todo exemplo usa o binário `pepe` instalado; a partir de um checkout do código-fonte,
use `mix pepe` no lugar, os dois aceitam os mesmos subcomandos.

```bash
pepe help              # a lista completa de comandos
pepe help <grupo>       # ex.: pepe help agent
```

## Configuração inicial

```bash
pepe setup   # primeira vez: assistente guiado (idioma -> modelo -> agente -> Telegram)
              # próximas vezes: um menu pra adicionar ou reconfigurar qualquer parte
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
pepe model test [NOME]           # testa uma conexão pra confirmar que ela funciona
pepe model reconnect openai      # faz login de novo pra consertar uma conexão quebrada, sem mexer no resto
pepe model remove openrouter
pepe model default openai
```

Já paga o ChatGPT/Codex ou o Claude Pro/Max? Dá pra adicionar **fazendo login com essa
conta** em vez de colar uma chave de API: `pepe model add openai` -> "ChatGPT / Codex
subscription" abre seu navegador, você entra na conta, e o Pepe cuida do resto. Veja
[Modelos](../models/).

Se essa conexão parar de funcionar (o login expirou, ou você saiu da conta em outro
lugar), `pepe model reconnect NOME` faz login de novo e conserta no lugar. Nada mais
muda na conexão, então todo agente que já usava ela continua funcionando sem precisar
mexer em nada. Não remova e adicione de novo pra resolver isso: isso recomeça do zero e
perde qualquer preço ou ajuste que você tinha configurado.

## Agentes

```bash
pepe agent add assistant \
  --prompt "Você é um agente de programação útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # deixa o assistant mandar mensagem pro helper (ver Rotas)
pepe agent manage boss assistant     # deixa o boss administrar o assistant ("*" = todos)
pepe agent rename assistant helper   # renomeia + move a pasta de trabalho dele
pepe agent remove helper
pepe agent default assistant
```

Veja [Agentes](../agents/) pra entender o que cada opção faz.

## Projetos (mais de um cliente ou time no mesmo Pepe)

Se você roda o Pepe pra vários clientes ou times numa instalação só, cada um é um
**projeto**, com seus próprios agentes e dados, isolado dos outros. Sem `--project`,
tudo usa o projeto padrão, exatamente como uma instalação de cliente único sempre
funcionou. Veja [Projetos](../projects/).

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

## Rodando

```bash
pepe run "liste os arquivos aqui e resuma o projeto"   # one-shot, transmite pro stdout
pepe run assistant "olá"                                # escolhe um agente explicitamente
pepe chat                            # conversa interativa, lembra o que foi dito
pepe chat --agent assistant          # ...com um agente específico (ou: pepe chat assistant)
pepe goal "publica as notas de versão" \
  --criteria "CHANGELOG tem uma seção datada" --max-attempts 5   # continua até estar pronto de verdade
pepe serve --port 4000               # sobe a API, o dashboard e o WebSocket juntos
pepe serve install [--port 4000]     # mantém rodando em segundo plano pra sempre
pepe serve status                    # está instalado e rodando?
pepe serve uninstall                 # para e remove
```

`goal` não para na primeira tentativa: um revisor independente confere o resultado
contra `--criteria` e o Pepe tenta de novo (até `--max-attempts` vezes) até dar certo de
verdade. Use `--judge MODELO` pra revisar com um modelo diferente. Veja
[Metas](../goals/).

`serve install` faz o Pepe ligar sozinho e continuar rodando em segundo plano, mesmo
depois de logout, reinício, ou uma queda. Só funciona a partir do app `pepe`
instalado, não de um checkout do código-fonte.

`chat` (também chamado de `tui`) abre uma conversa direto no seu terminal, que lembra o
contexto conforme você usa. Digite `/help` dentro dele pra ver todos os atalhos (nova
conversa, desfazer, trocar de agente ou modelo, e mais).

## Gateway do Telegram

```bash
pepe gateway telegram setup      # interativo: token do bot, quem pode falar com ele, qual agente
pepe gateway telegram            # roda em primeiro plano
```

Veja [Telegram](../telegram/) pra entender acesso e vários bots.

## Tokens de acesso à API

Chaves que outros apps usam pra falar com o Pepe por HTTP ou WebSocket. Sem nenhuma
criada, só pedidos vindos da própria máquina são aceitos; assim que você cria uma, todo
pedido passa a precisar de um token válido. Um token pode ser limitado a um projeto
(`--project`) ou a um agente (`--agent HANDLE`). Veja [API HTTP](../api/).

```bash
pepe token add --project acme --label "app mobile da acme"   # mostra a chave uma vez só, guarde agora
pepe token add --agent acme/sales --label "uma integração"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # seguro pra colocar no código público de uma página
pepe token list                        # id, escopo, permissões, label
pepe token update <id> --greeting "Oi! Como posso ajudar?"
pepe token revoke <id>
```

Escopo decide *de quem* são os dados que um token alcança; permissões decidem *o que*
ele pode fazer com eles. Ou seja, dá pra dar a alguém um token que só lê relatório de
cobrança, sem conseguir conversar com um agente. Veja [Uso e cobrança](../billing/).

```bash
# um token só de cobrança: lê /v1/usage, não roda agente, e vê só o que
# o cliente paga de verdade (--prices list esconde sua margem; --prices all mostra ela também)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # muda no lugar, a chave continua a mesma
pepe token permissions <id> --no-usage
```

## Watches ("me avisa quando X acontecer")

Verifica algo periodicamente e avisa **uma vez**, assim que acontecer, depois para
sozinho. Veja [Watches](../watches/).

```bash
pepe watch add "site no ar" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Tarefas agendadas

Tarefas de agente que repetem numa agenda, tipo um cron. Veja [Tarefas
agendadas](../scheduled/).

```bash
pepe cron list
pepe cron add --name "resumo diário" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # dispara agora, fora do horário
pepe cron logs <id>
```

## Flows (repetir algo que já deu certo, sem pensar de novo)

Depois que um agente resolve algo do mesmo jeito umas duas vezes, transforme essa
sequência num `flow` com nome, que repete direto da próxima vez, mais rápido e sem
pedir pro modelo pensar tudo de novo do zero. Veja [Flows](../flows/).

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
pepe timelearn [AGENTE]                 # o que o agente aprendeu, ao longo do tempo
pepe learn consolidate [AGENTE]         # organiza isso agora
pepe learn auto [AGENTE] [--at CRON]    # faz isso automaticamente toda noite (--off pra desligar)
pepe learn status                       # quais agentes estão configurados pra isso
```

Veja [Aprendizado](../learning/) pra entender o que de fato é lembrado.

## Uso, cobrança e traces

```bash
pepe usage                                  # tokens e custo por ciclo, por projeto
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # uma linha por conversa
pepe usage runs <id>                        # aquela conversa, passo a passo
pepe usage export --project acme            # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices [--refresh]               # vê ou atualiza os preços atuais de modelo
pepe traces [--project NOME] [--limit N]    # atividade recente, qualquer canal
pepe traces <id>                            # reproduz uma execução passo a passo
```

Os mesmos números dá pra pegar por HTTP com um token com escopo de uso. Veja [Uso e
cobrança](../billing/).

## Servidores de tool, plugins e hooks de privacidade

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
pepe hooks generate "oculta CPFs" [--model NOME] [--save]   # deixa a IA escrever um pra você
```

Veja [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Banco de
dados](../database/) e [Privacidade e hooks](../privacy/).

## Qualidade e operações

```bash
pepe eval [SUITE]                # roda um conjunto de prompts de teste num agente
pepe doctor [--offline]          # confere se está tudo configurado certo
pepe review [approve|reject ID]  # aprova ou rejeita mudanças que um agente fez sozinho
pepe backup [--output ARQUIVO.tgz]  # salva tudo (config, agentes, conversas, banco)
pepe backup verify ARQUIVO.tgz      # confere se um backup está íntegro
pepe restore ARQUIVO.tgz [--force]  # traz um backup de volta
pepe migrate ORIGEM [--dry-run]  # traz modelos/agentes de outra ferramenta
pepe update                      # atualiza pra última versão
pepe browser install             # prepara o navegador que um agente pode usar
```

Veja [Avaliações](../evals/), [Backup](../backup/) e [Navegador](../browser/).

## Dashboard

Uma senha é opcional. Sem ela, o dashboard só abre na mesma máquina onde está rodando;
quem tentar de outro lugar é bloqueado. Veja [Autenticação](../auth/) e
[Dashboard](../dashboard/).

```bash
pepe dashboard                            # vê as configurações atuais
pepe dashboard password                   # define uma, digita escondido, nada aparece na tela
pepe dashboard hosts app.example.com      # permite acessar por um domínio (--clear reseta)
pepe dashboard trusted-proxies 10.0.0.0/8 # necessário se estiver atrás de um proxy reverso
```

## Diversos

```bash
pepe tools     # lista toda tool que um agente pode usar
pepe config    # onde fica o arquivo de config, e um resumo rápido
pepe help      # ajuda completa de comandos (ou: pepe help <grupo>)
```
