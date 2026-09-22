---
title: Referência da CLI
description: Todos os comandos do pepe, agrupados pelo que gerem, ligações a modelos, agentes, projetos, tokens, painel e mais.
---

Tudo o que o Pepe faz está acessível pela linha de comandos, e aqui os comandos estão
agrupados pela forma como realmente vais procurá-los, pelo que queres fazer, não por
ordem alfabética. Os exemplos usam sempre o binário `pepe` instalado; a partir de um
checkout do código-fonte usa `mix pepe`, que aceita exatamente os mesmos subcomandos.

```bash
pepe help              # a lista completa de comandos
pepe help <grupo>       # ex.: pepe help agent
```

## Configuração inicial

```bash
pepe setup   # primeira execução: assistente guiado (idioma -> modelo -> agente -> Telegram)
              # execuções seguintes: um menu para adicionar ou reconfigurar qualquer parte
```

## Ligações a modelos

```bash
pepe model                       # mostra a predefinida, troca entre as guardadas ou adiciona uma nova
pepe model add openai            # guiado: fornecedor -> método de autenticação -> modelo
pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # totalmente manual
pepe model providers             # lista os fornecedores conhecidos (OpenAI, Anthropic, Gemini, ...)
pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
pepe model list                  # lista as ligações guardadas
pepe model test [NOME]           # testa uma ligação, para confirmar que a chave e o endpoint funcionam
pepe model reconnect openai      # inicia sessão de novo para reparar uma ligação avariada, mantendo tudo o resto
pepe model remove openrouter
pepe model default openai
```

Já pagas o ChatGPT/Codex ou o Claude Pro/Max? Em vez de colar uma chave de API, dá para
adicionar a ligação **iniciando sessão com essa conta**: `pepe model add openai` e depois
"ChatGPT / Codex subscription" abre o browser, entras na conta e o Pepe trata do resto.
Os detalhes estão em [Modelos](../models/).

Quando uma ligação destas para de funcionar, por exemplo uma sessão que expirou ou que
terminaste noutro sítio, `pepe model reconnect NOME` volta a autenticar e repara tudo no
próprio lugar. O resto da ligação não muda, por isso nenhum agente que já a usava precisa
de reconfiguração. Não a apagues para voltar a criar como forma de resolver isto: isso
começa do zero e perdes qualquer preço personalizado ou ajuste que lá tivesses.

## Agentes

```bash
pepe agent add assistant \
  --prompt "És um agente de programação útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # permite que o assistant envie mensagens ao helper (ver Rotas)
pepe agent manage boss assistant     # permite que o boss administre o assistant ("*" = todos)
pepe agent rename assistant helper   # muda o nome e move a pasta de trabalho
pepe agent remove helper
pepe agent default assistant
```

O que cada opção faz está descrito em [Agentes](../agents/).

## Projetos (mais do que um cliente ou equipa)

Quem corre o Pepe para vários clientes ou equipas a partir de uma única instalação separa
cada um num **projeto**, com os seus próprios agentes e os seus próprios dados,
isolado de todos os outros. Sem `--project`, tudo continua a usar o projeto predefinido,
tal como sempre aconteceu numa instalação de cliente único. Ver [Projetos](../projects/).

```bash
pepe project add acme --description "Acme Inc"     # cria um cliente/projeto novo
pepe project list
pepe project rename acme umbrella                  # muda o nome; nada mais deixa de funcionar
pepe agent add sales --project acme --prompt "..."  # agente "acme/sales"
pepe agent list --project acme                     # só os agentes da Acme
pepe agent list --all                              # de todos os projetos
pepe run acme/sales "olá"                          # corre-o pelo handle
pepe project remove acme --force                   # apaga o projeto e os agentes dele
```

## Executar

```bash
pepe run "lista os ficheiros aqui e resume o projeto"   # execução única, transmite direto para o stdout
pepe run assistant "olá"                                 # escolhendo o agente explicitamente
pepe chat                            # conversa interativa, com memória do que já foi dito
pepe chat --agent assistant          # com um agente específico (ou: pepe chat assistant)
pepe goal "publica as notas de lançamento" \
  --criteria "o CHANGELOG tem uma secção datada" --max-attempts 5   # só para quando estiver mesmo pronto
pepe serve --port 4000               # arranca a API, o painel e o WebSocket juntos
pepe serve --port 4000 --bind lan     # acessível a partir de outras máquinas, não só desta
pepe serve install [--port 4000]     # deixa a correr em segundo plano de forma permanente
pepe serve status                    # está instalado e a correr?
pepe serve uninstall                 # para e remove
```

O `goal` não desiste na primeira tentativa: um revisor independente verifica o resultado
contra `--criteria`, e o Pepe volta a tentar (até `--max-attempts` vezes) enquanto não
passar de facto. Usa `--judge MODELO` se quiseres que um modelo diferente faça essa
verificação. Ver [Objetivos](../goals/).

O `serve install` faz o Pepe arrancar sozinho e ficar a correr em segundo plano, mesmo
depois de um logout, de um reinício ou de uma falha. Só funciona a partir da app `pepe`
instalada, não de um checkout do código-fonte, e o `--bind` também se propaga a ele
(`serve install --bind lan`).

Por predefinição, `serve` liga-se apenas a `127.0.0.1`, ou seja, só esta máquina consegue
alcançá-lo, já que um `serve` isolado não tem nenhum proxy reverso à frente e a API `/v1`
fica aberta sem autenticação enquanto não configurares um token. Usa `--bind lan` para
abrir a todas as interfaces de rede, mas define primeiro uma palavra-passe do painel
(`pepe dashboard password`), ou opta por `--tunnel` para expor publicamente sem alargar a
ligação de todo. Esta predefinição não vale para a imagem Docker oficial, que se liga
sempre a todas as interfaces; a razão está em [Publicar num servidor](../deploy/).

O `chat` (também chamado `tui`) abre uma conversa diretamente no teu terminal, mantendo o
contexto à medida que avanças. Escreve `/help` lá dentro para veres todos os atalhos:
nova conversa, desfazer, recuar algumas trocas, trocar de agente ou de modelo, entre outros.

## Gateway do Telegram

```bash
pepe gateway telegram setup      # interativo: token do bot, quem tem acesso, qual o agente
pepe gateway telegram            # corre em primeiro plano
```

Como funcionam o acesso e vários bots ao mesmo tempo está em [Telegram](../telegram/).

## Tokens de acesso à API

São as chaves que outras apps usam para falar com o Pepe por HTTP ou WebSocket. Sem
nenhum token criado, só pedidos vindos da própria máquina são aceites; assim que crias o
primeiro, todo o pedido passa a precisar de um token válido. Um token pode ficar limitado
a um projeto (`--project`) ou a um agente (`--agent HANDLE`). Ver [API HTTP](../api/).

```bash
pepe token add --project acme --label "app móvel da acme"   # mostra a chave uma única vez, guarda-a já
pepe token add --agent acme/sales --label "uma integração"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # seguro para colocar no código-fonte público de uma página
pepe token list                        # id, âmbito, permissões, etiqueta
pepe token update <id> --greeting "Olá! Como posso ajudar?"
pepe token revoke <id>
```

O âmbito decide *de quem* são os dados que um token consegue alcançar; as permissões
decidem *o que* ele tem autorização para fazer com eles. Por isso dá para entregar a
alguém um token que só lê relatórios de faturação, sem que consiga sequer conversar com
um agente. Ver [Utilização e faturação](../billing/).

```bash
# um token só de faturação: lê /v1/usage, não corre nenhum agente, e só vê o que o
# cliente paga de facto (--prices list esconde a tua margem; --prices all já a mostra)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # altera no próprio lugar, a chave mantém-se igual
pepe token permissions <id> --no-usage
```

## Watches ("avisa-me quando X acontecer")

Verifica algo com uma periodicidade definida e avisa **uma única vez**, no momento em que
se torna verdade, parando sozinho a partir daí. Ver [Watches](../watches/).

```bash
pepe watch add "site no ar" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Tarefas agendadas

Trabalhos de agente que se repetem numa agenda fixa, à semelhança de um cron. Ver
[Tarefas agendadas](../scheduled/).

```bash
pepe cron list
pepe cron add --name "resumo diário" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # dispara já, fora da agenda normal
pepe cron logs <id>
```

## Flows (repetir uma sequência já validada sem voltar a pensá-la)

Assim que um agente já resolveu algo da mesma forma umas quantas vezes, essa sequência
pode virar um `flow` com nome, que passa a repeti-la diretamente da próxima vez, mais
rápido e sem pedir ao modelo para a descobrir outra vez do zero. Ver [Flows](../flows/).

```bash
pepe flow list AGENTE
pepe flow promote NOME --agent AGENTE --from ID1,ID2[,...] [--overwrite]
pepe flow show AGENTE NOME
pepe flow remove AGENTE NOME
pepe flow run AGENTE NOME                                    # corre já
pepe flow schedule AGENTE NOME --schedule "..." [--timezone TZ] [--deliver ...]
```

## Aprendizagem

```bash
pepe timelearn [AGENTE]                 # o que o agente foi aprendendo ao longo do tempo
pepe learn consolidate [AGENTE]         # organiza isso agora mesmo
pepe learn auto [AGENTE] [--at CRON]    # faz o mesmo automaticamente todas as noites (--off para desligar)
pepe learn status                       # que agentes estão configurados para isto
```

O que fica realmente memorizado está descrito em [Aprendizagem](../learning/).

## Utilização, faturação e traces

```bash
pepe usage                                  # tokens e custo por ciclo, por projeto
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # uma linha por conversa
pepe usage runs <id>                        # essa conversa, passo a passo
pepe usage export --project acme            # fatura de cliente (Markdown, ou --format csv)
pepe usage prices [--refresh]               # consulta ou atualiza os preços atuais de modelo
pepe traces [--project NOME] [--limit N]    # atividade recente, em qualquer canal
pepe traces <id>                            # reproduz uma execução passo a passo
```

Os mesmos números também estão disponíveis por HTTP com um token com âmbito de
utilização. Ver [Utilização e faturação](../billing/).

## Servidores de ferramentas, plugins e hooks de privacidade

```bash
pepe mcp add NOME --command npx --args "..."       # um servidor de ferramentas local
pepe mcp add NOME --url URL --header "K: V"        # um servidor de ferramentas remoto (HTTP)
pepe mcp list | tools NOME | remove NOME           # inspeciona e gere
pepe mcp login|logout NOME                         # inicia sessão num servidor de ferramentas remoto
pepe plugin list | install | scan | remove         # ferramentas e canais adicionais
pepe plugin route list | enable NOME | disable NOME  # o endpoint web próprio de um plugin
pepe skill list | search | install | update | remove | audit | tap  # marketplace de skills
pepe db add | list | remove              # permite que um agente consulte uma base de dados externa
pepe slot list | set | clear             # que plugin trata de cada capacidade
pepe policy list                         # regras de permissão instaladas e onde se aplicam
pepe policy scope NOME --agents a,b [--projects x,y] | --clear   # restringe onde uma regra se aplica
pepe hooks list                          # hooks de privacidade disponíveis
pepe hooks generate "oculta números de contribuinte" [--model NOME] [--save]   # a IA escreve um por ti
```

Ver [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Base de
dados](../database/) e [Privacidade e hooks](../privacy/).

## Qualidade e operações

```bash
pepe eval [SUITE]                # corre um conjunto de perguntas de teste contra um agente
pepe doctor [--offline]          # confirma que está tudo bem configurado
pepe review [approve|reject ID]  # aprova ou rejeita alterações que um agente fez por conta própria
pepe backup [--output FICHEIRO.tgz]  # guarda tudo (configuração, agentes, conversas, base de dados)
pepe backup verify FICHEIRO.tgz      # confirma que um backup está íntegro
pepe restore FICHEIRO.tgz [--force]  # restaura um backup
pepe migrate ORIGEM [--dry-run]  # importa modelos/agentes de outra ferramenta
pepe update                      # atualiza para a versão mais recente
pepe browser install             # prepara o browser que um agente pode usar
```

Ver [Avaliações](../evals/), [Backup](../backup/) e [Browser](../browser/).

## Painel

Definir uma palavra-passe é opcional. Sem ela, o painel só abre na própria máquina onde
está a correr; qualquer tentativa vinda de outro lado é bloqueada. Ver
[Autenticação](../auth/) e [Painel](../dashboard/).

```bash
pepe dashboard                            # mostra as definições atuais
pepe dashboard password                   # define uma, digitada de forma oculta, sem nada visível no ecrã
pepe dashboard hosts app.example.com      # permite aceder por um nome de domínio (--clear repõe)
pepe dashboard trusted-proxies 10.0.0.0/8 # necessário quando está atrás de um proxy inverso
```

## Diversos

```bash
pepe tools     # lista todas as ferramentas que um agente pode usar
pepe config    # onde fica o ficheiro de configuração, e um resumo rápido
pepe help      # ajuda completa de comandos (ou: pepe help <grupo>)
```
