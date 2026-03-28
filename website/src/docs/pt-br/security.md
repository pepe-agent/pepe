---
title: Seguranca e ambiente isolado
description: Agentes executam codigo, entao fazem trabalho de verdade e podem causar estrago de verdade. O Pepe empilha uma barreira de permissao, protecoes de comandos, um ambiente isolado opcional, referencias a segredos, hooks de censura e controle de acesso, e e honesto sobre o que cada um faz.
---

## A ameaca, sem rodeios

Um agente que consegue rodar um comando ou escrever um arquivo e util justamente porque age na sua maquina. Esse mesmo poder e o risco. O Pepe nao finge que um unico ajuste torna isso seguro. Em vez disso ele empilha varias protecoes independentes, cada uma com uma tarefa clara, e deixa voce aumentar a forca conforme sua exposicao cresce. Esta pagina percorre cada camada, da que fica sempre ligada ate a que voce ativa por conta propria para criar um limite firme.

As camadas, da mais fraca porem sempre ligada ate a mais forte porem opcional:

1. A barreira de permissao. Uma pessoa aprova qualquer ferramenta que age.
2. Protecoes de comandos. Um filtro embutido que recusa alguns poucos comandos catastroficos.
3. O ambiente isolado. Um invólucro opcional que roda comandos de shell em isolamento de verdade.
4. Referencias a segredos. As credenciais ficam como `${ENV_VAR}`, nunca expandidas em disco.
5. Hooks de censura. Limpeza opcional de dados pessoais antes que o texto chegue a um modelo.
6. Controle de acesso. A senha do painel e os tokens de portador da API.

<div class="note"><strong>Nenhum ajuste sozinho e um limite de seguranca.</strong> O padrao honesto e a barreira de permissao mais as protecoes. Para qualquer coisa que rode sem supervisao ou aprove ferramentas automaticamente, adicione o ambiente isolado, e o ideal e rodar o Pepe como um usuario limitado ou dentro de um contêiner.</div>

## A barreira de permissao

Toda chamada de ferramenta passa por uma barreira antes de rodar. Ferramentas somente leitura rodam livremente. Tudo que age (rodar um comando, escrever ou mover um arquivo, mudar a configuracao, e qualquer ferramenta de plugin de terceiros) precisa ser autorizado primeiro.

As ferramentas que nunca perguntam sao as de somente leitura: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` e `send_to_agent`. Qualquer coisa fora dessa lista, incluindo qualquer ferramenta de plugin adicionada, e tratada como arriscada e exige aprovacao. Esse e um padrao deliberadamente seguro: presume-se que uma ferramenta desconhecida seja perigosa.

Quando uma ferramenta arriscada nao foi aprovada de antemao, o runtime pergunta a pessoa do outro lado. Cada superficie mostra esse aviso do seu jeito nativo (botoes embutidos num canal de chat, um menu com as setas do teclado na CLI), mas a decisao e sempre uma de quatro:

- `once`: permite so esta chamada, pergunta de novo na proxima vez.
- `session`: permite pelo resto desta conversa. Fica na memoria e e esquecido quando voce inicia uma nova sessao ou reinicia. As outras sessoes continuam perguntando.
- `always`: permite de agora em diante. Fica salvo no agente em `config.json`.
- `deny`: recusa. Nunca e lembrado, entao a mesma chamada e perguntada de novo mais tarde.

Uma chamada negada nao derruba a execucao. O modelo e informado de que a pessoa nao autorizou a ferramenta e e orientado a tentar outra abordagem ou consultar voce, de modo que a conversa continua.

### Aprovacao automatica e o agente dono

Escolher `always` no aviso registra essa ferramenta na lista `auto_approve` do agente, entao ela nunca mais pergunta para aquele agente. Nao ha uma opcao separada para configurar isso de antemao pelo `pepe agent add`. Voce concede confianca respondendo `always` uma vez quando o aviso aparece, ou editando o agente em `config.json`:

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

Um unico curinga `"*"` em `auto_approve` significa que o agente roda qualquer ferramenta sem nunca perguntar. Esse e o agente dono onipotente criado para voce no `pepe setup`: com confianca sobre todas as ferramentas para que voce possa conduzir sua propria maquina sem atrito. Conceda essa confianca de forma deliberada, e nunca a um agente exposto a entradas nao confiaveis.

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

<div class="note"><strong>Superficies sem uma pessoa rodam livremente.</strong> A API HTTP nao tem a quem perguntar, entao nao fornece nenhum aprovador e as ferramentas arriscadas rodam sem perguntar. Trate a API como de plena confianca, e proteja-a com um token (veja abaixo) antes de expo-la.</div>

## Protecoes de comandos

As ferramentas de shell (`bash` e `run_script`) passam cada comando por uma guarda primeiro. A guarda recusa um conjunto pequeno e deliberadamente estreito de operacoes catastroficas que nunca sao legitimas:

- Exclusoes recursivas de um caminho de sistema, `/`, `~` ou `$HOME`.
- Formatar um sistema de arquivos (`mkfs`).
- Escrever direto ou sobrescrever um dispositivo de disco (`dd of=/dev/...`, ou redirecionar para `/dev/sda` e afins).
- Bombas de bifurcacao (fork bombs).
- Desligar ou reiniciar a maquina (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

Ela e pura, multiplataforma, sem configuracao e sempre ligada. Nao custa nada, entao nunca precisa ser habilitada.

Deixe claro o que ela e: uma rede fina contra acidentes e contra injecao de prompt obvia, nao um limite de seguranca. Um comando decidido ou ofuscado pode escapar da inspecao estatica, e a guarda permite de proposito trabalho poderoso porem legitimo, como instalar dependencias ou consultar um banco de dados. Para um limite de verdade, adicione o ambiente isolado.

## O ambiente isolado (isolamento opcional)

Para um limite de verdade, de modo que nem mesmo um agente com aprovacao automatica consiga tocar a maquina anfitria, configure um invólucro de isolamento. Um invólucro e um pequeno executavel ao qual o Pepe entrega cada comando. O invólucro roda o comando isolado conforme o anfitriao permitir, e depois devolve a saida. O Pepe passa o diretorio de trabalho do agente na variavel de ambiente `PEPE_SANDBOX_CWD`, para que o invólucro possa montar ou confinar as escritas apenas naquele diretorio.

Quando nenhum invólucro esta configurado (o padrao), os comandos rodam direto na maquina anfitria e a barreira de permissao e a protecao. Quando um invólucro esta configurado, cada comando de shell passa por ele.

O jeito mais rapido de configurar um e o fluxo de instalacao, que escreve um invólucro pronto em `~/.pepe/sandbox/` e aponta a configuracao para ele:

```bash
pepe setup
```

Escolha o passo Sandbox e o seu isolamento. O Pepe oferece o que a sua maquina anfitria suporta:

| Anfitriao | Opcoes |
|------|------|
| Linux | firejail (leve, espacos de nomes) ou Docker/Podman |
| macOS | sandbox-exec (ja vem com o macOS) ou Docker Desktop |
| Windows | Docker ou WSL |

O Docker e o denominador comum portatil: ele monta apenas a area de trabalho, entao o resto do sistema de arquivos da maquina anfitria fica invisivel, e voce pode manter a rede ligada quando o agente precisa de um banco de dados ou de uma API. O invólucro do Docker e ajustavel por variaveis de ambiente, incluindo `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` ou `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS` e `PEPE_SANDBOX_RUNTIME` (`docker` ou `podman`).

Se voce preferir apontar para o seu proprio invólucro, defina o caminho direto em `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Qualquer executavel serve desde que rode seus argumentos (`program arg1 arg2 ...`) de forma isolada e respeite `PEPE_SANDBOX_CWD`. A instalacao apenas avisa, e nunca instala automaticamente, se a ferramenta subjacente (docker, firejail, sandbox-exec) estiver faltando no seu `PATH`.

<div class="note"><strong>Nao existe ambiente isolado de verdade que seja sem configuracao e multiplataforma.</strong> Todo isolamento real precisa de um recurso do sistema operacional ou de uma ferramenta externa. Por isso o ambiente isolado e opcional e os padroes sempre ligados sao a barreira mais as protecoes. Quando os agentes rodam sem supervisao ou aprovam ferramentas automaticamente, trate o ambiente isolado como obrigatorio, nao opcional.</div>

## Os segredos ficam como referencias

A configuracao fica em um arquivo JSON simples em `~/.pepe/config.json`. Nao ha banco de dados. Para manter as credenciais fora desse arquivo, escreva-as como referencias `${ENV_VAR}`. O Pepe as interpola contra o ambiente no momento da leitura e nunca persiste o valor expandido.

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

Em tempo de execucao a chave real e lida do ambiente. Em disco o arquivo so contem o marcador. O mesmo mecanismo funciona para os tokens de gateway, os ajustes de plugins e a senha do painel, entao voce pode versionar ou compartilhar uma configuracao sem vazar nada. Exporte as variaveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador de string inteira que resolve para nada (a variavel nao esta definida) e tratado como "nao definido" em vez de uma string vazia, entao um segredo ausente aparece como um claro "nao configurado" em vez de um branco silencioso.

### Faça por chat

Um agente que recebe as ferramentas somente leitura `config_get` e `doctor` consegue relatar a sua configuracao e pegar um segredo ausente numa conversa normal. Ambas sao somente leitura, entao nunca disparam a barreira de permissao.

> Voce: Esta tudo configurado corretamente?
>
> Agente: (roda `doctor`) Encontrei um problema: a conexao de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variavel nao esta definida no ambiente. Exporte-a antes de servir.

A ferramenta `doctor` faz uma verificacao de saude de toda a configuracao e sinaliza segredos `${ENV}` nao definidos, agentes apontando para modelos ausentes, agendamentos invalidos e conexoes inalcancaveis. Passe `live: true` para tambem sondar a rede.

<div class="note"><strong>Ajustes sensiveis a seguranca nao podem ser editados por chat.</strong> A ferramenta protegida `config_set` e fechada por padrao: ela so mexe numa lista de permissao curta (o modelo e o agente padrao, o idioma, o fuso horario e algumas poucas opcoes do Telegram). Segredos, listas de ferramentas permitidas, tokens de bot, o invólucro do ambiente isolado, a senha do painel e os tokens da API ficam de proposito fora dessa lista. Um agente nao consegue muda-los conversando com ele; esses voce define por conta propria com a CLI ou editando a configuracao.</div>

## Hooks de censura (limpeza opcional de dados pessoais)

Se os seus agentes lidam com dados pessoais, voce pode limpa-los antes que cheguem a um modelo. Os hooks de censura rodam sobre o fluxo de mensagens e sao habilitados por agente, entao so os agentes que precisam pagam o custo.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Quatro hooks vem de fabrica:

- `pii_redact`: um censor de expressoes regulares, offline e sem dependencias. Ele substitui dados pessoais estruturados (email, numero de cartao e documentos nacionais como CPF ou CNPJ) por um token estavel como `[CPF_1]`. Por padrao e reversivel: registra `token -> real` para que o pipeline consiga restaurar o valor real na resposta de saida.
- `llm_redact`: usa um modelo local ou configurado para substituir nomes, enderecos e texto livre por pseudonimos realistas, e depois os restaura na saida. Vai melhor junto com o `pii_redact`, que lida com os documentos estruturados de forma deterministica enquanto o modelo cuida das partes baguncadas em qualquer idioma.
- `presidio`: envia o texto pelos seus proprios contêineres autohospedados de analise e anonimizacao do Microsoft Presidio, assim os dados ficam sob o seu controle.
- `http_redact`: a valvula de escape generica. O Pepe publica a mensagem no seu proprio endpoint, que devolve o texto transformado, assim qualquer servico de censura se conecta sem um adaptador dedicado.

Os ajustes globais de cada hook (quais pacotes de reconhecedores, padroes personalizados, se deve manter reversivel) ficam em `"hooks"` no `config.json`. Voce pode pedir a um modelo que rascunhe uma configuracao de `pii_redact` para voce:

```bash
pepe hooks list
pepe hooks generate "redact Brazilian CPF, emails, and phone numbers" --save
```

Os hooks de expressoes regulares e de HTTP falham de forma aberta por design: se um censor der erro ou um modelo estiver indisponivel, o texto original passa em vez de bloquear o trabalho. Quando voce precisa de uma garantia firme, marque a conexao de modelo com `require_redaction` em `config.json`. Um modelo marcado assim se recusa a rodar a menos que o agente tenha pelo menos um hook de censura habilitado, transformando uma limpeza de melhor esforco em uma obrigatoria.

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

O painel web fica aberto em localhost por padrao, o que e conveniente para o desenvolvimento local. No momento em que voce o expoe alem da sua maquina, coloque-o atras de uma senha:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Voce pode passar uma senha literal ou uma referencia `${ENV_VAR}` para que o segredo fique fora do arquivo. Uma vez definida a senha, o painel exige entrar em `/login`. Limpe-a com `pepe dashboard password --clear`.

A senha e lida de `dashboard.password` na configuracao (interpolada), com um recuo para a variavel de ambiente `PEPE_DASHBOARD_PASSWORD`. Dois ajustes relacionados reforcam um painel servido atras de um dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores extras do cabecalho `Host` que o painel aceita. Isso serve tambem como a lista de permissao contra o reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies reversos cujo cabecalho `X-Forwarded-For` pode ser considerado confiavel. Vazio por padrao, o que significa que nenhum cabecalho de encaminhamento e confiavel.

Vinculado a uma interface publica sem senha, o painel se fecha por padrao e bloqueia clientes remotos ate que voce defina uma.

## Tokens da API

A API HTTP fica aberta quando nenhum token existe, o que mantem simples uma configuracao de um unico inquilino. Criar o primeiro token a vira para fechada: dai em diante cada requisicao para `/v1` precisa de um cabecalho `Authorization: Bearer` carregando um token valido. Gere um com:

```bash
pepe token add --label "ci pipeline"
```

O token em bruto e mostrado uma unica vez e apenas o seu hash SHA-256 e armazenado, nunca o token em si. Um token pode ter escopo: `--company` o limita aos agentes de um inquilino, e `--agent` o limita a um unico agente (que precisa estar dentro daquela empresa). Gerencie-os com `pepe token list` e `pepe token revoke ID`. Para os formatos das requisicoes e o uso do SDK, veja a [pagina da API HTTP](./api/).

## Isolamento multi-inquilino

O trabalho pode ser separado por empresa (um escopo de inquilino baseado num identificador). O escopo padrao, sem empresa, se chama Principal. Os agentes, modelos e chaves de provedor de uma empresa ficam invisiveis para as outras empresas, e um token de API com escopo de empresa alcanca apenas os agentes daquela empresa. Isso impede que as credenciais e conversas de um inquilino vazem para as de outro, o que importa quando voce hospeda agentes em nome de varios clientes a partir de uma unica instancia do Pepe.
