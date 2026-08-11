---
title: Referência da CLI
description: Todos os comandos do pepe, agrupados pelo que gerem, ligações de modelo, agentes, projetos, tokens, o dashboard, e mais.
---

Tudo no Pepe é alcançável pela linha de comandos, agrupado aqui como realmente vais
procurar: pelo que estás a tentar fazer, não por ordem alfabética. Todo o exemplo usa o
binário `pepe` instalado; a partir de um checkout do código-fonte, usa `mix pepe` em vez
disso, ambos aceitam os mesmos subcomandos.

```bash
pepe help              # a lista completa de comandos
pepe help <grupo>       # ex.: pepe help agent
```

## Configuração inicial

```bash
pepe setup   # primeira vez: assistente guiado (idioma -> modelo -> agente -> Telegram)
              # vezes seguintes: um menu para adicionares ou reconfigurares qualquer parte
```

## Ligações de modelo

```bash
pepe model                       # mostra a predefinida, troca entre as guardadas, ou adiciona uma nova
pepe model add openai            # guiado: escolhes fornecedor -> método de início de sessão -> modelo
pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # totalmente manual
pepe model providers             # lista fornecedores conhecidos (OpenAI, Anthropic, Gemini, ...)
pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
pepe model list                  # lista as ligações guardadas
pepe model test [NOME]           # testa uma ligação para confirmar que funciona
pepe model reconnect openai      # inicia sessão de novo para corrigir uma ligação avariada, sem mexer no resto
pepe model remove openrouter
pepe model default openai
```

Já pagas o ChatGPT/Codex ou o Claude Pro/Max? Podes adicionar **iniciando sessão com
essa conta** em vez de colares uma chave de API: `pepe model add openai` -> "ChatGPT /
Codex subscription" abre o teu navegador, entras na conta, e o Pepe trata do resto. Vê
[Modelos](../models/).

Se essa ligação deixar de funcionar (a sessão expirou, ou terminaste sessão noutro
lado), `pepe model reconnect NOME` inicia sessão de novo e corrige no lugar. Nada mais
muda na ligação, por isso qualquer agente que já a usasse continua a funcionar sem
precisares de mexer em nada. Não a removas e voltes a adicionar para resolver isto: isso
começa tudo do zero e perde qualquer preço ou ajuste que tivesses configurado.

## Agentes

```bash
pepe agent add assistant \
  --prompt "És um agente de programação útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # deixa o assistant enviar mensagem ao helper (ver Rotas)
pepe agent manage boss assistant     # deixa o boss administrar o assistant ("*" = todos)
pepe agent rename assistant helper   # renomeia + move a pasta de trabalho dele
pepe agent remove helper
pepe agent default assistant
```

Vê [Agentes](../agents/) para perceberes o que cada opção faz.

## Projetos (mais do que um cliente ou equipa no mesmo Pepe)

Se corres o Pepe para vários clientes ou equipas numa só instalação, cada um é um
**projeto**, com os seus próprios agentes e dados, isolado dos outros. Sem
`--project`, tudo usa o projeto predefinido, exatamente como uma instalação de um só
cliente sempre funcionou. Vê [Projetos](../projects/).

```bash
pepe project add acme --description "Acme Inc"     # cria um novo cliente/projeto
pepe project list
pepe project rename acme umbrella                  # renomeia; nada mais se parte
pepe agent add sales --project acme --prompt "..."  # agente "acme/sales"
pepe agent list --project acme                     # só os agentes da Acme
pepe agent list --all                              # todos os projetos
pepe run acme/sales "olá"                          # corre-o pelo handle dele
pepe project remove acme --force                   # apaga o projeto + os agentes dele
```

## Executar

```bash
pepe run "lista os ficheiros aqui e resume o projeto"   # one-shot, transmite para o stdout
pepe run assistant "olá"                                 # escolhe um agente explicitamente
pepe chat                            # conversa interativa, lembra-se do que foi dito
pepe chat --agent assistant          # ...com um agente específico (ou: pepe chat assistant)
pepe goal "publica as notas da versão" \
  --criteria "o CHANGELOG tem uma secção datada" --max-attempts 5   # continua até estar mesmo pronto
pepe serve --port 4000               # arranca a API, o dashboard e o WebSocket juntos
pepe serve --port 4000 --bind lan     # ...acessível a partir de outras máquinas, não só esta
pepe serve install [--port 4000]     # mantém a correr em segundo plano para sempre
pepe serve status                    # está instalado e a correr?
pepe serve uninstall                 # para e remove
```

`goal` não pára na primeira tentativa: um revisor independente confere o resultado
contra `--criteria` e o Pepe tenta de novo (até `--max-attempts` vezes) até resultar de
facto. Usa `--judge MODELO` para reveres com um modelo diferente. Vê
[Objetivos](../goals/).

`serve install` faz o Pepe ligar-se sozinho e continuar a correr em segundo plano -
mesmo depois de um logout, reinício, ou uma falha. Só funciona a partir da app `pepe`
instalada, não de um checkout do código-fonte. O `--bind` também se aplica a ele
(`serve install --bind lan`).

`serve` liga-se apenas a `127.0.0.1` por predefinição - só esta máquina o consegue
alcançar, já que um `serve` puro não tem proxy reverso à frente e a API `/v1` fica
aberta sem autenticação até configurares um token. `--bind lan` abre para todas as
interfaces de rede; define primeiro uma palavra-passe do dashboard
(`pepe dashboard password`), ou usa `--tunnel` para expor publicamente sem alargar
a ligação. Esta predefinição não se aplica à imagem Docker oficial, que liga sempre
a todas as interfaces - vê [Publicar num servidor](../deploy/) para saberes porquê.

`chat` (também chamado `tui`) abre uma conversa diretamente no teu terminal, que se
lembra do contexto à medida que usas. Escreve `/help` lá dentro para veres todos os
atalhos (nova conversa, desfazer, trocar de agente ou modelo, e mais).

## Gateway do Telegram

```bash
pepe gateway telegram setup      # interativo: token do bot, quem pode falar com ele, qual agente
pepe gateway telegram            # corre em primeiro plano
```

Vê [Telegram](../telegram/) para perceberes o acesso e vários bots.

## Tokens de acesso à API

Chaves que outras apps usam para falar com o Pepe por HTTP ou WebSocket. Sem nenhuma
criada, só pedidos vindos da própria máquina são aceites; assim que crias uma, todo o
pedido passa a precisar de um token válido. Um token pode ser limitado a um projeto
(`--project`) ou a um agente (`--agent HANDLE`). Vê [API HTTP](../api/).

```bash
pepe token add --project acme --label "app móvel da acme"   # mostra a chave uma vez só, guarda-a já
pepe token add --agent acme/sales --label "uma integração"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # seguro para colocares no código público de uma página
pepe token list                        # id, âmbito, permissões, etiqueta
pepe token update <id> --greeting "Olá! Como posso ajudar?"
pepe token revoke <id>
```

O âmbito decide *de quem* são os dados que um token alcança; as permissões decidem *o
que* ele pode fazer com eles. Ou seja, podes dar a alguém um token que só lê
relatórios de faturação, sem conseguir conversar com um agente. Vê [Utilização e
faturação](../billing/).

```bash
# um token só de faturação: lê /v1/usage, não consegue correr um agente, e vê só o
# que o cliente paga de facto (--prices list esconde a tua margem; --prices all também a mostra)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # muda no lugar, a chave mantém-se
pepe token permissions <id> --no-usage
```

## Watches ("avisa-me quando X acontecer")

Verifica algo periodicamente e avisa **uma vez**, assim que acontecer, depois pára
sozinho. Vê [Watches](../watches/).

```bash
pepe watch add "site no ar" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Tarefas agendadas

Tarefas de agente que se repetem numa agenda, como um cron. Vê [Tarefas
agendadas](../scheduled/).

```bash
pepe cron list
pepe cron add --name "resumo diário" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # dispara agora, fora do horário
pepe cron logs <id>
```

## Flows (repetir algo que já resultou, sem pensar de novo)

Depois de um agente resolver algo da mesma forma umas duas vezes, transforma essa
sequência num `flow` com nome, que se repete diretamente da próxima vez, mais rápido e
sem pedir ao modelo para pensar tudo de novo do zero. Vê [Flows](../flows/).

```bash
pepe flow list AGENTE
pepe flow promote NOME --agent AGENTE --from ID1,ID2[,...] [--overwrite]
pepe flow show AGENTE NOME
pepe flow remove AGENTE NOME
pepe flow run AGENTE NOME                                    # corre agora
pepe flow schedule AGENTE NOME --schedule "..." [--timezone TZ] [--deliver ...]
```

## Aprendizagem

```bash
pepe timelearn [AGENTE]                 # o que o agente aprendeu, ao longo do tempo
pepe learn consolidate [AGENTE]         # organiza isso agora
pepe learn auto [AGENTE] [--at CRON]    # faz isso automaticamente todas as noites (--off para desligar)
pepe learn status                       # que agentes estão configurados para isto
```

Vê [Aprendizagem](../learning/) para perceberes o que de facto fica guardado.

## Utilização, faturação e traces

```bash
pepe usage                                  # tokens e custo por ciclo, por projeto
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # uma linha por conversa
pepe usage runs <id>                        # essa conversa, passo a passo
pepe usage export --project acme            # uma fatura de cliente (Markdown, ou --format csv)
pepe usage prices [--refresh]               # vê ou atualiza os preços atuais de modelo
pepe traces [--project NOME] [--limit N]    # atividade recente, qualquer canal
pepe traces <id>                            # reproduz uma execução passo a passo
```

Os mesmos números podem ser lidos por HTTP com um token com âmbito de utilização. Vê
[Utilização e faturação](../billing/).

## Servidores de ferramentas, plugins e hooks de privacidade

```bash
pepe mcp add NOME --command npx --args "..."       # um servidor de ferramentas local
pepe mcp add NOME --url URL --header "K: V"        # um servidor de ferramentas remoto (HTTP)
pepe mcp list | tools NOME | remove NOME           # inspeciona e gere
pepe mcp login|logout NOME                         # inicia sessão num servidor de ferramentas remoto
pepe plugin list | install | scan | remove         # ferramentas e canais extra
pepe plugin route list | enable NOME | disable NOME  # endpoint web próprio de um plugin
pepe skill list | search | install | update | remove | audit | tap  # marketplace de skills
pepe db add | list | remove              # deixa um agente consultar uma base de dados externa
pepe slot list | set | clear             # que plugin trata de uma capacidade específica
pepe policy list                         # regras de permissão instaladas e onde se aplicam
pepe policy scope NOME --agents a,b [--projects x,y] | --clear   # limita onde uma regra se aplica
pepe hooks list                          # hooks de privacidade disponíveis
pepe hooks generate "oculta NIFs" [--model NOME] [--save]   # deixa a IA escrever um por ti
```

Vê [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Base de
dados](../database/) e [Privacidade e hooks](../privacy/).

## Qualidade e operações

```bash
pepe eval [SUITE]                # corre um conjunto de perguntas de teste num agente
pepe doctor [--offline]          # confirma que está tudo configurado corretamente
pepe review [approve|reject ID]  # aprova ou rejeita alterações que um agente fez sozinho
pepe backup [--output FICHEIRO.tgz]  # guarda tudo (configuração, agentes, conversas, base de dados)
pepe backup verify FICHEIRO.tgz      # confirma que um backup está intacto
pepe restore FICHEIRO.tgz [--force]  # traz um backup de volta
pepe migrate ORIGEM [--dry-run]  # traz modelos/agentes de outra ferramenta
pepe update                      # atualiza para a última versão
pepe browser install             # prepara o navegador que um agente pode usar
```

Vê [Avaliações](../evals/), [Backup](../backup/) e [Navegador](../browser/).

## Dashboard

Uma palavra-passe é opcional. Sem ela, o dashboard só abre na mesma máquina onde está a
correr; quem tentar de outro lado é bloqueado. Vê [Autenticação](../auth/) e
[Dashboard](../dashboard/).

```bash
pepe dashboard                            # vê as definições atuais
pepe dashboard password                   # define uma, escreves de forma escondida, nada aparece no ecrã
pepe dashboard hosts app.example.com      # permite aceder por um domínio (--clear repõe)
pepe dashboard trusted-proxies 10.0.0.0/8 # necessário se estiver atrás de um proxy inverso
```

## Diversos

```bash
pepe tools     # lista todas as ferramentas que um agente pode usar
pepe config    # onde fica o ficheiro de configuração, e um resumo rápido
pepe help      # ajuda completa de comandos (ou: pepe help <grupo>)
```
