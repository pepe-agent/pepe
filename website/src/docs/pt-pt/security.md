---
title: Seguranca e ambiente isolado
description: Os agentes executam codigo, por isso fazem trabalho a serio e podem provocar estragos a serio. O Pepe empilha uma barreira de permissao, protecoes de comandos, um ambiente isolado opcional, referencias a segredos, hooks de censura e controlo de acesso, e e honesto sobre aquilo que cada um faz.
---

## A ameaca, sem rodeios

Um agente capaz de executar um comando ou de escrever um ficheiro e util precisamente porque atua na sua maquina. Esse mesmo poder e o risco. O Pepe nao finge que uma unica definicao torne isto seguro. Em vez disso empilha varias protecoes independentes, cada uma com uma funcao clara, e permite-lhe aumentar a forca a medida que a sua exposicao cresce. Esta pagina percorre cada camada, desde a que esta sempre ativa ate aquela que o utilizador ativa por si proprio para impor um limite firme.

As camadas, da mais fraca mas sempre ativa ate a mais forte mas opcional:

1. A barreira de permissao. Uma pessoa aprova qualquer ferramenta que atue.
2. Protecoes de comandos. Um filtro incorporado que recusa alguns poucos comandos catastroficos.
3. O ambiente isolado. Um invólucro opcional que executa comandos de shell em isolamento a serio.
4. Referencias a segredos. As credenciais ficam como `${ENV_VAR}`, nunca expandidas em disco.
5. Hooks de censura. Limpeza opcional de dados pessoais antes de o texto chegar a um modelo.
6. Controlo de acesso. A palavra-passe do painel e os tokens de portador da API.

<div class="note"><strong>Nenhuma definicao sozinha constitui um limite de seguranca.</strong> A predefinicao honesta e a barreira de permissao mais as protecoes. Para tudo o que corra sem supervisao ou aprove ferramentas de forma automatica, acrescente o ambiente isolado, e o ideal e correr o Pepe como um utilizador limitado ou dentro de um contentor.</div>

## A barreira de permissao

Cada chamada de ferramenta passa por uma barreira antes de correr. As ferramentas de leitura apenas correm livremente. Tudo o que atua (executar um comando, escrever ou mover um ficheiro, alterar a configuracao, e qualquer ferramenta de plugin de terceiros) tem de ser autorizado primeiro.

As ferramentas que nunca perguntam sao as de leitura apenas: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` e `send_to_agent`. Tudo o que nao conste dessa lista, incluindo qualquer ferramenta de plugin acrescentada, e tratado como arriscado e exige aprovacao. Trata-se de uma predefinicao deliberadamente segura: presume-se que uma ferramenta desconhecida e perigosa.

Quando uma ferramenta arriscada nao foi aprovada de antemao, o runtime pergunta a pessoa do outro lado. Cada superficie apresenta esse pedido a sua maneira nativa (botoes incorporados num canal de conversa, um menu com as setas do teclado na CLI), mas a decisao e sempre uma de quatro:

- `once`: permite apenas esta chamada, volta a perguntar da proxima vez.
- `session`: permite durante o resto desta conversa. Fica em memoria e e esquecido quando o utilizador inicia uma nova sessao ou reinicia. As restantes sessoes continuam a perguntar.
- `always`: permite de agora em diante. Fica guardado no agente em `config.json`.
- `deny`: recusa. Nunca e memorizado, por isso a mesma chamada volta a ser perguntada mais tarde.

Uma chamada recusada nao faz falhar a execucao. O modelo e informado de que a pessoa nao autorizou a ferramenta e e convidado a tentar outra abordagem ou a consultar o utilizador, de modo que a conversa prossegue.

### Aprovacao automatica e o agente proprietario

Escolher `always` no pedido regista essa ferramenta na lista `auto_approve` do agente, por isso nunca mais pergunta em relacao a esse agente. Nao existe uma opcao separada para configurar isto a partida atraves de `pepe agent add`. Concede-se confianca respondendo `always` uma vez quando o pedido aparece, ou editando o agente em `config.json`:

```json
{
  "agents": {
    "ops": {
      "system_prompt": "You keep the build green.",
      "tools": ["bash", "read_file", "write_file"],
      "auto_approve": ["read_file", "write_file"]
    }
  }
}
```

Um unico carater universal `"*"` em `auto_approve` significa que o agente executa qualquer ferramenta sem nunca perguntar. Esse e o agente proprietario omnipotente criado para si em `pepe setup`: com confianca sobre todas as ferramentas para que possa conduzir a sua propria maquina sem atrito. Conceda essa confianca de forma deliberada, e nunca a um agente exposto a entradas nao fidedignas.

```json
{
  "agents": {
    "owner": {
      "system_prompt": "...",
      "tools": ["bash", "read_file", "write_file", "edit_file"],
      "auto_approve": ["*"]
    }
  }
}
```

<div class="note"><strong>As superficies sem uma pessoa correm livremente.</strong> A API HTTP nao tem a quem perguntar, por isso nao fornece nenhum aprovador e as ferramentas arriscadas correm sem perguntar. Trate a API como totalmente fidedigna, e proteja-a com um token (ver abaixo) antes de a expor.</div>

### O proprietario pode conduzir a CLI por chat

A ferramenta `manage_pepe` executa os mesmos comandos `pepe` nao interativos que o utilizador escreveria num terminal (acrescentar um modelo, definir um agente, cunhar um token, agendar uma tarefa, gerir empresas), para que um agente proprietario fidedigno consiga operar todo o runtime a partir de uma conversa.

> Utilizador: Acrescenta um agente chamado researcher com as ferramentas web_search e read_file.
>
> Agente: (pede-lhe confirmacao e depois executa `pepe agent add researcher --tools web_search,read_file`) Pronto. O agente researcher esta pronto.

E a ferramenta mais poderosa que existe. Conceda-a apenas a um agente proprietario em quem confie totalmente, nunca a um exposto a entradas nao fidedignas. Como todas as ferramentas que atuam, passa pela barreira de permissao, e os comandos interativos ou de longa duracao (`setup`, `chat`, `serve` e os gateways em primeiro plano) sao recusados porque nao conseguem correr como uma execucao unica. Para um unico trabalho mais estreito, prefira as ferramentas focadas: `manage_token` para tokens, `manage_channel` para canais, `schedule_task` para crons.

## Protecoes de comandos

As ferramentas de shell (`bash` e `run_script`) passam cada comando por uma guarda primeiro. A guarda recusa um conjunto pequeno e deliberadamente estreito de operacoes catastroficas que nunca sao legitimas:

- Eliminacoes recursivas de um caminho de sistema, `/`, `~` ou `$HOME`.
- Formatar um sistema de ficheiros (`mkfs`).
- Escrever em bruto ou substituir um dispositivo de disco (`dd of=/dev/...`, ou redirecionar para `/dev/sda` e afins).
- Bombas de bifurcacao (fork bombs).
- Desligar ou reiniciar o computador (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

E pura, multiplataforma, sem configuracao e sempre ativa. Nao tem custo, por isso nunca precisa de ser habilitada.

Seja claro sobre o que ela e: uma rede fina contra acidentes e contra injecao de prompt obvia, nao um limite de seguranca. Um comando decidido ou ofuscado pode escapar a inspecao estatica, e a guarda permite de proposito trabalho poderoso mas legitimo, como instalar dependencias ou consultar uma base de dados. Para um limite a serio, acrescente o ambiente isolado.

## O ambiente isolado (isolamento opcional)

Para um limite verdadeiro, de modo que nem sequer um agente com aprovacao automatica consiga tocar no computador anfitriao, configure um invólucro de isolamento. Um invólucro e um pequeno executavel ao qual o Pepe entrega cada comando. O invólucro executa o comando isolado conforme o anfitriao permitir, e depois devolve o resultado. O Pepe passa o diretorio de trabalho do agente na variavel de ambiente `PEPE_SANDBOX_CWD`, para que o invólucro possa montar ou confinar as escritas apenas a esse diretorio.

Quando nenhum invólucro esta definido (a predefinicao), os comandos correm diretamente no anfitriao e a barreira de permissao e a protecao. Quando um invólucro esta definido, cada comando de shell passa por ele.

A forma mais rapida de configurar um e o fluxo de instalacao, que escreve um invólucro pronto a usar em `~/.pepe/sandbox/` e aponta a configuracao para ele:

```bash
pepe setup
```

Escolha o passo Sandbox e o seu isolamento. O Pepe oferece aquilo que o seu anfitriao suporta:

| Anfitriao | Opcoes |
|------|------|
| Linux | firejail (leve, espacos de nomes) ou Docker/Podman |
| macOS | sandbox-exec (ja vem com o macOS) ou Docker Desktop |
| Windows | Docker ou WSL |

O Docker e o denominador comum portatil: monta apenas a area de trabalho, por isso o resto do sistema de ficheiros do anfitriao fica invisivel, e pode manter a rede ligada quando o agente precisa de uma base de dados ou de uma API. O invólucro do Docker e ajustavel atraves de variaveis de ambiente, incluindo `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` ou `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS` e `PEPE_SANDBOX_RUNTIME` (`docker` ou `podman`).

Se preferir apontar para o seu proprio invólucro, defina o caminho diretamente em `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Qualquer executavel serve, desde que corra os seus argumentos (`program arg1 arg2 ...`) de forma isolada e respeite `PEPE_SANDBOX_CWD`. A instalacao apenas avisa, e nunca instala automaticamente, se a ferramenta subjacente (docker, firejail, sandbox-exec) faltar no seu `PATH`.

<div class="note"><strong>Nao existe um ambiente isolado verdadeiro que seja sem configuracao e multiplataforma.</strong> Todo o isolamento real precisa de uma funcionalidade do sistema operativo ou de uma ferramenta externa. E por isso que o ambiente isolado e opcional e as predefinicoes sempre ativas sao a barreira mais as protecoes. Quando os agentes correm sem supervisao ou aprovam ferramentas de forma automatica, trate o ambiente isolado como obrigatorio, nao opcional.</div>

## Os segredos ficam como referencias

A configuracao vive num ficheiro JSON simples em `~/.pepe/config.json`. Nao ha base de dados. Para manter as credenciais fora desse ficheiro, escreva-as como referencias `${ENV_VAR}`. O Pepe interpola-as em relacao ao ambiente no momento da leitura e nunca persiste o valor expandido.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini"
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}" }
}
```

Em tempo de execucao a chave real e lida do ambiente. Em disco o ficheiro so contem o marcador. O mesmo mecanismo funciona para os tokens de gateway, as definicoes de plugins e a palavra-passe do painel, por isso pode versionar ou partilhar uma configuracao sem divulgar nada. Exporte as variaveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador de cadeia inteira que se resolve em nada (a variavel nao esta definida) e tratado como "nao definido" em vez de uma cadeia vazia, por isso um segredo em falta surge como um claro "nao configurado" em vez de um branco silencioso.

### Fá-lo por chat

Um agente ao qual sejam concedidas as ferramentas de leitura apenas `config_get` e `doctor` consegue relatar a sua configuracao e apanhar um segredo em falta numa conversa normal. Ambas sao de leitura apenas, por isso nunca acionam a barreira de permissao.

> Utilizador: Esta tudo configurado corretamente?
>
> Agente: (executa `doctor`) Encontrei um problema: a ligacao de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variavel nao esta definida no ambiente. Exporte-a antes de servir.

A ferramenta `doctor` faz uma verificacao de saude de toda a configuracao e sinaliza segredos `${ENV}` por definir, agentes a apontar para modelos em falta, agendamentos invalidos e ligacoes inalcancaveis. Passe `live: true` para tambem sondar a rede.

<div class="note"><strong>As definicoes sensiveis a seguranca nao sao editaveis pela ferramenta geral de configuracao.</strong> A ferramenta protegida `config_set` fecha por predefinicao: so mexe numa lista de permissoes curta (o modelo e o agente predefinidos, o idioma, o fuso horario e algumas opcoes do Telegram). Os segredos, as listas de ferramentas permitidas, os tokens de bot, o involucro do ambiente isolado e a palavra-passe do painel ficam de proposito fora dessa lista, pelo que o `config_set` nao os consegue alterar. Esses e o utilizador que os define, atraves da CLI ou do painel. Os tokens da API sao a unica coisa que um agente consegue cunhar por conversa, mas apenas atraves da ferramenta separada e protegida por permissoes `manage_token`, nunca atraves do `config_set`.</div>

## Hooks de censura (limpeza opcional de dados pessoais)

Se os seus agentes lidam com dados pessoais, pode limpa-los antes de chegarem a um modelo. Os hooks de censura correm sobre o fluxo de mensagens e sao habilitados por agente, por isso so os agentes que precisam pagam o custo.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Vem quatro hooks de fabrica:

- `pii_redact`: um censor de expressoes regulares, offline e sem dependencias. Substitui dados pessoais estruturados (correio eletronico, numero de cartao e documentos nacionais como o CPF ou o CNPJ) por um token estavel como `[CPF_1]`. Por predefinicao e reversivel: regista `token -> real` para que o fluxo consiga restaurar o valor real na resposta a saida.
- `llm_redact`: usa um modelo local ou configurado para substituir nomes, moradas e texto livre por pseudonimos realistas, e depois restaura-os a saida. Combina melhor com o `pii_redact`, que trata os documentos estruturados de forma deterministica enquanto o modelo trata das partes desordenadas em qualquer idioma.
- `presidio`: envia o texto atraves dos seus proprios contentores auto-alojados de analise e anonimizacao do Microsoft Presidio, para que os dados permanecam sob o seu controlo.
- `http_redact`: a valvula de escape generica. O Pepe publica a mensagem no seu proprio endpoint, que devolve o texto transformado, para que qualquer servico de censura se ligue sem um adaptador dedicado.

As definicoes globais de cada hook (que pacotes de reconhecedores, padroes personalizados, se deve manter-se reversivel) ficam em `"hooks"` no `config.json`. Pode pedir a um modelo que rascunhe uma configuracao de `pii_redact` por si:

```bash
pepe hooks list
pepe hooks generate "redact Brazilian CPF, emails, and phone numbers" --save
```

Os hooks de expressoes regulares e de HTTP falham de forma aberta por conceito: se um censor der erro ou um modelo estiver indisponivel, o texto original passa em vez de bloquear o trabalho. Quando precisa de uma garantia firme, marque a ligacao de modelo com `require_redaction` em `config.json`. Um modelo assim marcado recusa-se a correr, a nao ser que o agente tenha pelo menos um hook de censura habilitado, transformando uma limpeza de melhor esforco numa obrigatoria.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini",
      "require_redaction": true
    }
  }
}
```

## Acesso ao painel

O painel web fica aberto em localhost por predefinicao, o que e comodo para o desenvolvimento local. No momento em que o expoe para alem da sua maquina, coloque-o atras de uma palavra-passe:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Pode passar uma palavra-passe literal ou uma referencia `${ENV_VAR}` para que o segredo fique fora do ficheiro. Uma vez definida a palavra-passe, o painel exige iniciar sessao em `/login`. Limpe-a com `pepe dashboard password --clear`.

A palavra-passe e lida de `dashboard.password` na configuracao (interpolada), com recurso a variavel de ambiente `PEPE_DASHBOARD_PASSWORD`. Duas definicoes relacionadas reforcam um painel servido atras de um dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores adicionais do cabecalho `Host` que o painel aceita. Isto serve tambem de lista de permissoes contra o reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies inversos cujo cabecalho `X-Forwarded-For` pode ser considerado fidedigno. Vazio por predefinicao, o que significa que nenhum cabecalho de encaminhamento e considerado fidedigno.

Vinculado a uma interface publica sem palavra-passe, o painel fecha por predefinicao e bloqueia os clientes remotos ate o utilizador definir uma.

## Tokens da API

Sem nenhum token, a API HTTP responde apenas a quem chama a partir de loopback (localhost). O primeiro token fecha-a para toda a gente, local ou remoto: dai em diante cada pedido a `/v1` precisa de um cabecalho `Authorization: Bearer` a transportar um token valido. Gere um com:

```bash
pepe token add --label "ci pipeline"
```

O token em bruto e mostrado uma unica vez e apenas o seu hash SHA-256 e armazenado, nunca o token em si. Um token pode ter ambito: `--company` limita-o aos agentes de um inquilino, e `--agent` limita-o a um unico agente (que tem de residir dentro dessa empresa). Faca a sua gestao com `pepe token list` e `pepe token revoke ID`, a partir da pagina de tokens de API do painel, ou por conversa com um agente que tenha a ferramenta protegida `manage_token`. Para os formatos dos pedidos e a utilizacao do SDK, consulte a [pagina da API HTTP](./api/).

## Isolamento multi-inquilino

O trabalho pode ser separado por empresa (um ambito de inquilino baseado num identificador). O ambito predefinido, sem empresa, chama-se Principal. Os agentes, modelos e chaves de fornecedor de uma empresa ficam invisiveis para as outras empresas, e um token de API com ambito de empresa alcanca apenas os agentes dessa empresa. Isto impede que as credenciais e conversas de um inquilino alguma vez se infiltrem nas de outro, o que importa quando aloja agentes em nome de varios clientes a partir de uma unica instancia do Pepe.
