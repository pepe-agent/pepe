---
title: Segurança e ambiente isolado
description: Os agentes executam código, por isso fazem trabalho a sério e podem provocar estragos a sério. O Pepe empilha uma barreira de permissão, proteções de comandos, um ambiente isolado opcional, referências a segredos, hooks de censura e controlo de acesso, e é honesto sobre aquilo que cada um faz.
---

## A ameaça, sem rodeios

Um agente capaz de executar um comando ou de escrever um ficheiro é útil precisamente porque atua na tua máquina. Esse mesmo poder é o risco. O Pepe não finge que uma única definição torne isto seguro. Em vez disso empilha várias proteções independentes, cada uma com uma função clara, e permite-te aumentar a força à medida que a tua exposição cresce. Esta página percorre cada camada, desde a que está sempre ativa até aquela que tu ativas por ti próprio para impor um limite firme.

As camadas, da mais fraca mas sempre ativa até a mais forte mas opcional:

1. A barreira de permissão. Uma pessoa aprova qualquer ferramenta que atue.
2. Proteções de comandos. Um filtro incorporado que recusa alguns poucos comandos catastróficos.
3. O ambiente isolado. Um invólucro opcional que executa comandos de shell em isolamento a sério.
4. Referências a segredos. As credenciais ficam como `${ENV_VAR}`, nunca expandidas em disco.
5. Hooks de censura. Limpeza opcional de dados pessoais antes de o texto chegar a um modelo.
6. Controlo de acesso. A palavra-passe do painel e os tokens de portador da API.

<div class="note"><strong>Nenhuma definição sozinha constitui um limite de segurança.</strong> A predefinição honesta é a barreira de permissão mais as proteções. Para tudo o que corra sem supervisão ou aprove ferramentas de forma automática, acrescenta o ambiente isolado, e o ideal é correr o Pepe como um utilizador limitado ou dentro de um contentor.</div>

## A barreira de permissão

Cada chamada de ferramenta passa por uma barreira antes de correr. As ferramentas de leitura apenas correm livremente. Tudo o que atua (executar um comando, escrever ou mover um ficheiro, alterar a configuração, e qualquer ferramenta de plugin de terceiros) tem de ser autorizado primeiro.

As ferramentas que nunca perguntam são as de leitura apenas: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` e `send_to_agent`. Tudo o que não conste dessa lista, incluindo qualquer ferramenta de plugin acrescentada, é tratado como arriscado e exige aprovação. Trata-se de uma predefinição deliberadamente segura: presume-se que uma ferramenta desconhecida é perigosa.

Quando uma ferramenta arriscada não foi aprovada de antemão, o runtime pergunta a pessoa do outro lado. Cada superfície apresenta esse pedido à sua maneira nativa (botões incorporados num canal de conversa, um menu com as setas do teclado na CLI), mas a decisão é sempre uma de quatro:

- `once`: permite apenas esta chamada, volta a perguntar da próxima vez.
- `session`: permite durante o resto desta conversa. Fica em memória e é esquecido quando inicias uma nova sessão ou reinicias. As restantes sessões continuam a perguntar.
- `always`: permite de agora em diante. Fica guardado no agente em `config.json`.
- `deny`: recusa. Nunca é memorizado, por isso a mesma chamada volta a ser perguntada mais tarde.

Uma chamada recusada não faz falhar a execução. O modelo é informado de que a pessoa não autorizou a ferramenta e é convidado a tentar outra abordagem ou a consultar-te, de modo que a conversa prossegue.

### Aprovação automática e o agente proprietário

Escolher `always` no pedido regista essa ferramenta na lista `auto_approve` do agente, por isso nunca mais pergunta em relação a esse agente. Não existe uma opção separada para configurar isto à partida através de `pepe agent add`. Concede-se confiança respondendo `always` uma vez quando o pedido aparece, ou editando o agente em `config.json`:

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

Um único caráter universal `"*"` em `auto_approve` significa que o agente executa qualquer ferramenta sem nunca perguntar. Esse é o agente proprietário omnipotente criado para ti em `pepe setup`: com confiança sobre todas as ferramentas para que possas conduzir a tua própria máquina sem atrito. Concede essa confiança de forma deliberada, e nunca a um agente exposto a entradas não fidedignas.

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

<div class="note"><strong>As superfícies sem uma pessoa correm livremente.</strong> A API HTTP não tem a quem perguntar, por isso não fornece nenhum aprovador e as ferramentas arriscadas correm sem perguntar. Trata a API como totalmente fidedigna, e protege-a com um token (ver abaixo) antes de a expores.</div>

### O proprietário pode conduzir a CLI pela conversa

A ferramenta `manage_pepe` executa os mesmos comandos `pepe` não interativos que escreverias num terminal (acrescentar um modelo, definir um agente, gerar um token, agendar uma tarefa, gerir empresas), para que um agente proprietário fidedigno consiga operar todo o runtime a partir de uma conversa.

> Tu: Acrescenta um agente chamado researcher com as ferramentas web_search e read_file.
>
> Agente: (pede-te confirmação e depois executa `pepe agent add researcher --tools web_search,read_file`) Pronto. O agente researcher está pronto.

É a ferramenta mais poderosa que existe. Concede-a apenas a um agente proprietário em quem confies totalmente, nunca a um exposto a entradas não fidedignas. Como todas as ferramentas que atuam, passa pela barreira de permissão, e os comandos interativos ou de longa duração (`setup`, `chat`, `serve` e os gateways em primeiro plano) são recusados porque não conseguem correr como uma execução única. Para um único trabalho mais estreito, prefere as ferramentas focadas: `manage_token` para tokens, `manage_channel` para canais, `schedule_task` para crons.

## Proteções de comandos

As ferramentas de shell (`bash` e `run_script`) passam cada comando por uma guarda primeiro. A guarda recusa um conjunto pequeno e deliberadamente estreito de operações catastróficas que nunca são legítimas:

- Eliminações recursivas de um caminho de sistema, `/`, `~` ou `$HOME`.
- Formatar um sistema de ficheiros (`mkfs`).
- Escrever em bruto ou substituir um dispositivo de disco (`dd of=/dev/...`, ou redirecionar para `/dev/sda` e afins).
- Bombas de bifurcação (fork bombs).
- Desligar ou reiniciar o computador (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

É pura, multiplataforma, sem configuração e sempre ativa. Não tem custo, por isso nunca precisa de ser habilitada.

Seja claro sobre o que ela é: uma rede fina contra acidentes e contra injeção de prompt óbvia, não um limite de segurança. Um comando decidido ou ofuscado pode escapar a inspeção estática, e a guarda permite de propósito trabalho poderoso mas legítimo, como instalar dependências ou consultar uma base de dados. Para um limite a sério, acrescenta o ambiente isolado.

## O ambiente isolado (isolamento opcional)

Para um limite verdadeiro, de modo que nem sequer um agente com aprovação automática consiga tocar no computador anfitrião, configura um invólucro de isolamento. Um invólucro é um pequeno executável ao qual o Pepe entrega cada comando. O invólucro executa o comando isolado conforme o anfitrião permitir, e depois devolve o resultado. O Pepe passa o diretório de trabalho do agente na variável de ambiente `PEPE_SANDBOX_CWD`, para que o invólucro possa montar ou confinar as escritas apenas a esse diretório.

Quando nenhum invólucro está definido (a predefinição), os comandos correm diretamente no anfitrião e a barreira de permissão é a proteção. Quando um invólucro está definido, cada comando de shell passa por ele.

A forma mais rápida de configurar um é o fluxo de instalação, que escreve um invólucro pronto a usar em `~/.pepe/sandbox/` e aponta a configuração para ele:

```bash
pepe setup
```

Escolhe o passo Sandbox e o teu isolamento. O Pepe oferece aquilo que o teu anfitrião suporta:

| Anfitrião | Opções |
|------|------|
| Linux | firejail (leve, espaços de nomes) ou Docker/Podman |
| macOS | sandbox-exec (já vem com o macOS) ou Docker Desktop |
| Windows | Docker ou WSL |

O Docker é o denominador comum portátil: monta apenas a área de trabalho, por isso o resto do sistema de ficheiros do anfitrião fica invisível, e pode manter a rede ligada quando o agente precisa de uma base de dados ou de uma API. O invólucro do Docker é ajustável através de variáveis de ambiente, incluindo `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` ou `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS` e `PEPE_SANDBOX_RUNTIME` (`docker` ou `podman`).

Se preferires apontar para o teu próprio invólucro, define o caminho diretamente em `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Qualquer executável serve, desde que corra os seus argumentos (`program arg1 arg2 ...`) de forma isolada e respeite `PEPE_SANDBOX_CWD`. A instalação apenas avisa, e nunca instala automaticamente, se a ferramenta subjacente (docker, firejail, sandbox-exec) faltar no teu `PATH`.

<div class="note"><strong>Não existe um ambiente isolado verdadeiro que seja sem configuração e multiplataforma.</strong> Todo o isolamento real precisa de uma funcionalidade do sistema operativo ou de uma ferramenta externa. É por isso que o ambiente isolado é opcional e as predefinições sempre ativas são a barreira mais as proteções. Quando os agentes correm sem supervisão ou aprovam ferramentas de forma automática, trata o ambiente isolado como obrigatório, não opcional.</div>

## Os segredos ficam como referências

A configuração vive num ficheiro JSON simples em `~/.pepe/config.json`. Não há base de dados. Para manter as credenciais fora desse ficheiro, escreve-as como referências `${ENV_VAR}`. O Pepe interpola-as em relação ao ambiente no momento da leitura e nunca persiste o valor expandido.

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

Em tempo de execução a chave real é lida do ambiente. Em disco o ficheiro só contém o marcador. O mesmo mecanismo funciona para os tokens de gateway, as definições de plugins e a palavra-passe do painel, por isso podes versionar ou partilhar uma configuração sem divulgar nada. Exporta as variáveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador de cadeia inteira que se resolve em nada (a variável não está definida) é tratado como "não definido" em vez de uma cadeia vazia, por isso um segredo em falta surge como um claro "não configurado" em vez de um branco silencioso.

### Fá-lo pela conversa

Um agente ao qual sejam concedidas as ferramentas de leitura apenas `config_get` e `doctor` consegue relatar a sua configuração e apanhar um segredo em falta numa conversa normal. Ambas são de leitura apenas, por isso nunca acionam a barreira de permissão.

> Tu: Está tudo configurado corretamente?
>
> Agente: (executa `doctor`) Encontrei um problema: a ligação de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variável não está definida no ambiente. Exporta-a antes de servir.

A ferramenta `doctor` faz uma verificação de saúde de toda a configuração e sinaliza segredos `${ENV}` por definir, agentes a apontar para modelos em falta, agendamentos inválidos e ligações inalcançáveis. Passa `live: true` para também sondar a rede.

<div class="note"><strong>As definições sensíveis à segurança não são editáveis pela ferramenta geral de configuração.</strong> A ferramenta protegida `config_set` fecha por predefinição: só mexe numa lista de permissões curta (o modelo e o agente predefinidos, o idioma, o fuso horário e algumas opções do Telegram). Os segredos, as listas de ferramentas permitidas, os tokens de bot, o invólucro do ambiente isolado e a palavra-passe do painel ficam de propósito fora dessa lista, pelo que o `config_set` não os consegue alterar. És tu que os defines, através da CLI ou do painel. Os tokens da API são a única coisa que um agente consegue gerar pela conversa, mas apenas através da ferramenta separada e protegida por permissões `manage_token`, nunca através do `config_set`.</div>

## Hooks de censura (limpeza opcional de dados pessoais)

Se os teus agentes lidam com dados pessoais, podes limpá-los antes de chegarem a um modelo. Os hooks de censura correm sobre o fluxo de mensagens e são habilitados por agente, por isso só os agentes que precisam pagam o custo.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Três pontos do fluxo são censurados: a mensagem de entrada do humano, **o resultado bruto de qualquer tool** (uma consulta à base de dados, a leitura de um ficheiro, uma pesquisa na web, qualquer coisa que uma tool traga, não só o que um humano escreveu), e a resposta de saída do agente. O resultado da tool é censurado antes de entrar na conversa e antes de ser gravado em disco, por isso um resultado grande que acabe guardado num ficheiro do workspace (ver Agentes) já sai gravado censurado, nunca em bruto. Pede "lista os 10 doentes mais recentes com diagnóstico cardíaco" contra a tua própria base de dados e, com `pii_redact` ativado, o modelo raciocina sobre `[PERSON_1]`, `[PERSON_2]`, ...; só a resposta final para ti recebe os nomes reais de volta.

Vem quatro hooks de fábrica:

- `pii_redact`: um censor de expressões regulares, offline e sem dependências. Substitui dados pessoais estruturados (correio eletrónico, número de cartão e documentos nacionais como o NIF) por um token estável como `[NIF_1]`. Por predefinição é reversível: regista `token -> real` para que o fluxo consiga restaurar o valor real na resposta à saída.
- `llm_redact`: usa um modelo local ou configurado para substituir nomes, moradas e texto livre por pseudónimos realistas, e depois restaura-os à saída. Combina melhor com o `pii_redact`, que trata os documentos estruturados de forma determinística enquanto o modelo trata das partes desordenadas em qualquer idioma.
- `presidio`: envia o texto através dos teus próprios contentores auto-alojados de análise e anonimização do Microsoft Presidio, para que os dados permaneçam sob o teu controlo.
- `http_redact`: a válvula de escape genérica. O Pepe publica a mensagem no teu próprio endpoint, que devolve o texto transformado, para que qualquer serviço de censura se ligue sem um adaptador dedicado.

As definições globais de cada hook (que pacotes de reconhecedores, padrões personalizados, se deve manter-se reversível) ficam em `"hooks"` no `config.json`. Podes pedir a um modelo que gere uma configuração de `pii_redact` por ti:

```bash
pepe hooks list
pepe hooks generate "redact Portuguese NIF, emails, and phone numbers" --save
```

Os hooks de expressões regulares e de HTTP falham de forma aberta por conceito: se um censor der erro ou um modelo estiver indisponível, o texto original passa em vez de bloquear o trabalho. Quando precisas de uma garantia firme, marca a ligação de modelo com `require_redaction` em `config.json`. Um modelo assim marcado recusa-se a correr, a não ser que o agente tenha pelo menos um hook de censura habilitado, transformando uma limpeza de melhor esforço numa obrigatória.

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

O painel web fica aberto em localhost por predefinição, o que é cómodo para o desenvolvimento local. No momento em que o expões para além da tua máquina, coloca-o atrás de uma palavra-passe:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Vinculado a uma interface pública sem palavra-passe, o painel fecha por predefinição e bloqueia os clientes remotos até definires uma. Os detalhes completos (a lista de permissões de `Host` e as definições de trusted-proxies para servir atrás de um domínio, e como o correr como serviço persistente) estão na página [Painel](../dashboard/).

## Tokens da API

Sem nenhum token, a API HTTP responde apenas a quem chama a partir de loopback (localhost). O primeiro token fecha-a para toda a gente, local ou remoto: daí em diante cada pedido a `/v1` precisa de um cabeçalho `Authorization: Bearer` a transportar um token válido. Gera um com:

```bash
pepe token add --label "ci pipeline"
```

O token em bruto é mostrado uma única vez e apenas o seu hash SHA-256 é armazenado, nunca o token em si. Um token pode ter âmbito: `--company` limita-o aos agentes de uma empresa, e `--agent` limita-o a um único agente (que tem de residir dentro dessa empresa). Faz a sua gestão com `pepe token list` e `pepe token revoke ID`, a partir da página de tokens de API do painel, ou por conversa com um agente que tenha a ferramenta protegida `manage_token`. Para os formatos dos pedidos e a utilização do SDK, consulta a [página da API HTTP](../api/).

## Isolamento multiempresa

O trabalho pode ser separado por empresa (um âmbito de empresa baseado num identificador). O âmbito predefinido, sem empresa, chama-se Principal. Os agentes, modelos e chaves de fornecedor de uma empresa ficam invisíveis para as outras empresas, e um token de API com âmbito de empresa alcança apenas os agentes dessa empresa. Isto impede que as credenciais e conversas de uma empresa se infiltrem nas de outra, o que importa quando alojas agentes em nome de vários clientes a partir de uma única instância do Pepe.
