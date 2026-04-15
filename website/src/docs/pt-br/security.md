---
title: Segurança e ambiente isolado
description: Agentes executam código, então fazem trabalho de verdade e podem causar estrago de verdade. O Pepe empilha uma barreira de permissão, proteções de comandos, um ambiente isolado opcional, referências a segredos, hooks de censura e controle de acesso, e é honesto sobre o que cada um faz.
---

## A ameaça, sem rodeios

Um agente que consegue rodar um comando ou escrever um arquivo é útil justamente porque age na sua máquina. Esse mesmo poder é o risco. O Pepe não finge que um único ajuste torna isso seguro. Em vez disso ele empilha várias proteções independentes, cada uma com uma tarefa clara, e deixa você aumentar a força conforme sua exposição cresce. Esta página percorre cada camada, da que fica sempre ligada até a que você ativa por conta própria para criar um limite firme.

As camadas, da mais fraca porem sempre ligada até a mais forte porem opcional:

1. A barreira de permissão. Uma pessoa aprova qualquer ferramenta que age.
2. Proteções de comandos. Um filtro embutido que recusa alguns poucos comandos catastroficos.
3. O ambiente isolado. Um invólucro opcional que roda comandos de shell em isolamento de verdade.
4. Referências a segredos. As credenciais ficam como `${ENV_VAR}`, nunca expandidas em disco.
5. Hooks de censura. Limpeza opcional de dados pessoais antes que o texto chegue a um modelo.
6. Controle de acesso. A senha do painel e os tokens de portador da API.

<div class="note"><strong>Nenhum ajuste sozinho é um limite de segurança.</strong> O padrão honesto é a barreira de permissão mais as proteções. Para qualquer coisa que rode sem supervisão ou aprove ferramentas automaticamente, adicione o ambiente isolado, e o ideal é rodar o Pepe como um usuário limitado ou dentro de um contêiner.</div>

## A barreira de permissão

Toda chamada de ferramenta passa por uma barreira antes de rodar. Ferramentas somente leitura rodam livremente. Tudo que age (rodar um comando, escrever ou mover um arquivo, mudar a configuração, e qualquer ferramenta de plugin de terceiros) precisa ser autorizado primeiro.

As ferramentas que nunca perguntam são as de somente leitura: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` e `send_to_agent`. Qualquer coisa fora dessa lista, incluindo qualquer ferramenta de plugin adicionada, é tratada como arriscada e exige aprovação. Esse é um padrão deliberadamente seguro: presume-se que uma ferramenta desconhecida seja perigosa.

Quando uma ferramenta arriscada não foi aprovada de antemão, o runtime pergunta a pessoa do outro lado. Cada superfície mostra esse aviso do seu jeito nativo (botões embutidos num canal de chat, um menu com as setas do teclado na CLI), mas a decisão é sempre uma de quatro:

- `once`: permite só está chamada, pergunta de novo na próxima vez.
- `session`: permite pelo resto desta conversa. Fica na memória e é esquecido quando você inicia uma nova sessão ou reinicia. As outras sessões continuam perguntando.
- `always`: permite de agora em diante. Fica salvo no agente em `config.json`.
- `deny`: recusa. Nunca e lembrado, então a mesma chamada e perguntada de novo mais tarde.

Uma chamada negada não derruba a execução. O modelo é informado de que a pessoa não autorizou a ferramenta e é orientado a tentar outra abordagem ou consultar você, de modo que a conversa continua.

### Aprovação automática e o agente dono

Escolher `always` no aviso registra essa ferramenta na lista `auto_approve` do agente, então ela nunca mais pergunta para aquele agente. Não ha uma opção separada para configurar isso de antemão pelo `pepe agent add`. Você concede confiança respondendo `always` uma vez quando o aviso aparece, ou editando o agente em `config.json`:

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

Um único curinga `"*"` em `auto_approve` significa que o agente roda qualquer ferramenta sem nunca perguntar. Esse é o agente dono onipotente criado para você no `pepe setup`: com confiança sobre todas as ferramentas para que você possa conduzir sua própria máquina sem atrito. Conceda essa confiança de forma deliberada, e nunca a um agente exposto a entradas não confiáveis.

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

<div class="note"><strong>Superficies sem uma pessoa rodam livremente.</strong> A API HTTP não tem a quem perguntar, então não fornece nenhum aprovador e as ferramentas arriscadas rodam sem perguntar. Trate a API como de plena confiança, e proteja-a com um token (veja abaixo) antes de expo-la.</div>

### O dono pode conduzir a CLI pela conversa

A ferramenta `manage_pepe` roda os mesmos comandos `pepe` não interativos que você digitaria num terminal (adicionar um modelo, definir um agente, gerar um token, agendar uma tarefa, gerenciar empresas), então um agente dono confiável consegue operar todo o runtime a partir de uma conversa.

> Você: Adicione um agente chamado researcher com as ferramentas web_search e read_file.
>
> Agente: (pede sua confirmação e depois roda `pepe agent add researcher --tools web_search,read_file`) Pronto. O agente researcher está pronto.

Ela e a ferramenta mais poderosa que existe. De-a apenas a um agente dono em quem você confia plenamente, nunca a um exposto a entradas não confiáveis. Como toda ferramenta que age, ela passa pela barreira de permissão, e os comandos interativos ou de longa duração (`setup`, `chat`, `serve` e os gateways em primeiro plano) são recusados porque não conseguem rodar como uma execução única. Para um único trabalho mais estreito, prefira as ferramentas focadas: `manage_token` para tokens, `manage_channel` para canais, `schedule_task` para agendamentos.

## Proteções de comandos

As ferramentas de shell (`bash` e `run_script`) passam cada comando por uma guarda primeiro. A guarda recusa um conjunto pequeno e deliberadamente estreito de operações catastróficas que nunca são legítimas:

- Exclusoes recursivas de um caminho de sistema, `/`, `~` ou `$HOME`.
- Formatar um sistema de arquivos (`mkfs`).
- Escrever direto ou sobrescrever um dispositivo de disco (`dd of=/dev/...`, ou redirecionar para `/dev/sda` e afins).
- Bombas de bifurcação (fork bombs).
- Desligar ou reiniciar a máquina (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

Ela e pura, multiplataforma, sem configuração e sempre ligada. Não custa nada, então nunca precisa ser habilitada.

Deixe claro o que ela é: uma rede fina contra acidentes e contra injeção de prompt óbvia, não um limite de segurança. Um comando decidido ou ofuscado pode escapar da inspeção estática, e a guarda permite de propósito trabalho poderoso porem legítimo, como instalar dependências ou consultar um banco de dados. Para um limite de verdade, adicione o ambiente isolado.

## O ambiente isolado (isolamento opcional)

Para um limite de verdade, de modo que nem mesmo um agente com aprovação automática consiga tocar a máquina anfitriã, configure um invólucro de isolamento. Um invólucro é um pequeno executável ao qual o Pepe entrega cada comando. O invólucro roda o comando isolado conforme o anfitrião permitir, e depois devolve à saída. O Pepe passa o diretório de trabalho do agente na variável de ambiente `PEPE_SANDBOX_CWD`, para que o invólucro possa montar ou confinar as escritas apenas naquele diretório.

Quando nenhum invólucro está configurado (o padrão), os comandos rodam direto na máquina anfitriã e a barreira de permissão é a proteção. Quando um invólucro está configurado, cada comando de shell passa por ele.

O jeito mais rápido de configurar um é o fluxo de instalação, que escreve um invólucro pronto em `~/.pepe/sandbox/` e aponta a configuração para ele:

```bash
pepe setup
```

Escolha o passo Sandbox e o seu isolamento. O Pepe oferece o que a sua máquina anfitriã suporta:

| Anfitrião | Opções |
|------|------|
| Linux | firejail (leve, espaços de nomes) ou Docker/Podman |
| macOS | sandbox-exec (já vem com o macOS) ou Docker Desktop |
| Windows | Docker ou WSL |

O Docker é o denominador comum portátil: ele monta apenas a área de trabalho, então o resto do sistema de arquivos da máquina anfitriã fica invisível, e você pode manter a rede ligada quando o agente precisa de um banco de dados ou de uma API. O invólucro do Docker é ajustável por variáveis de ambiente, incluindo `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` ou `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS` e `PEPE_SANDBOX_RUNTIME` (`docker` ou `podman`).

Se você preferir apontar para o seu próprio invólucro, defina o caminho direto em `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Qualquer executável serve desde que rode seus argumentos (`program arg1 arg2 ...`) de forma isolada e respeite `PEPE_SANDBOX_CWD`. A instalação apenas avisa, e nunca instala automaticamente, se a ferramenta subjacente (docker, firejail, sandbox-exec) estiver faltando no seu `PATH`.

<div class="note"><strong>Não existe ambiente isolado de verdade que seja sem configuração e multiplataforma.</strong> Todo isolamento real precisa de um recurso do sistema operacional ou de uma ferramenta externa. Por isso o ambiente isolado é opcional e os padrões sempre ligados são a barreira mais as proteções. Quando os agentes rodam sem supervisão ou aprovam ferramentas automaticamente, trate o ambiente isolado como obrigatório, não opcional.</div>

## Os segredos ficam como referências

A configuração fica em um arquivo JSON simples em `~/.pepe/config.json`. Não ha banco de dados. Para manter as credenciais fora desse arquivo, escreva-as como referências `${ENV_VAR}`. O Pepe as interpola contra o ambiente no momento da leitura e nunca persiste o valor expandido.

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

Em tempo de execução a chave real é lida do ambiente. Em disco o arquivo só contém o marcador. O mesmo mecanismo funciona para os tokens de gateway, os ajustes de plugins e a senha do painel, então você pode versionar ou compartilhar uma configuração sem vazar nada. Exporte as variáveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador de string inteira que resolve para nada (a variável não está definida) é tratado como "não definido" em vez de uma string vazia, então um segredo ausente aparece como um claro "não configurado" em vez de um branco silencioso.

### Faça pela conversa

Um agente que recebe as ferramentas somente leitura `config_get` e `doctor` consegue relatar a sua configuração e pegar um segredo ausente numa conversa normal. Ambas são somente leitura, então nunca disparam a barreira de permissão.

> Você: Esta tudo configurado corretamente?
>
> Agente: (roda `doctor`) Encontrei um problema: a conexão de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variável não está definida no ambiente. Exporte-a antes de servir.

A ferramenta `doctor` faz uma verificação de saúde de toda a configuração e sinaliza segredos `${ENV}` não definidos, agentes apontando para modelos ausentes, agendamentos inválidos e conexões inalcançáveis. Passe `live: true` para também sondar a rede.

<div class="note"><strong>Ajustes sensíveis à segurança não são editáveis pela ferramenta geral de configuração.</strong> A ferramenta protegida `config_set` é fechada por padrão: ela só mexe numa lista de permissão curta (o modelo e o agente padrão, o idioma, o fuso horário e algumas poucas opções do Telegram). Segredos, listas de ferramentas permitidas, tokens de bot, o invólucro do ambiente isolado e a senha do painel ficam de propósito fora dessa lista, então o `config_set` não consegue mudá-los. Você define esses por conta própria com a CLI ou o painel. Os tokens da API são a única coisa que um agente consegue gerar pela conversa, mas apenas pela ferramenta separada e protegida por barreira de permissão `manage_token`, nunca pelo `config_set`.</div>

## Hooks de censura (limpeza opcional de dados pessoais)

Se os seus agentes lidam com dados pessoais, você pode limpá-los antes que cheguem a um modelo. Os hooks de censura rodam sobre o fluxo de mensagens e são habilitados por agente, então só os agentes que precisam pagam o custo.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Quatro hooks vem de fábrica:

- `pii_redact`: um censor de expressões regulares, offline e sem dependências. Ele substitui dados pessoais estruturados (email, número de cartão e documentos nacionais como CPF ou CNPJ) por um token estável como `[CPF_1]`. Por padrão e reversível: registra `token -> real` para que o pipeline consiga restaurar o valor real na resposta de saída.
- `llm_redact`: usa um modelo local ou configurado para substituir nomes, enderecos e texto livre por pseudónimos realistas, e depois os restaura na saída. Vai melhor junto com o `pii_redact`, que lida com os documentos estruturados de forma determinística enquanto o modelo cuida das partes baguncadas em qualquer idioma.
- `presidio`: envia o texto pelos seus próprios contêineres auto-hospedados de análise e anonimização do Microsoft Presidio, assim os dados ficam sob o seu controle.
- `http_redact`: a válvula de escape genérica. O Pepe pública a mensagem no seu próprio endpoint, que devolve o texto transformado, assim qualquer serviço de censura se conecta sem um adaptador dedicado.

Os ajustes globais de cada hook (quais pacotes de reconhecedores, padrões personalizados, se deve manter reversível) ficam em `"hooks"` no `config.json`. Você pode pedir a um modelo que rasgere uma configuração de `pii_redact` para você:

```bash
pepe hooks list
pepe hooks generate "redact Brazilian CPF, emails, and phone numbers" --save
```

Os hooks de expressões regulares e de HTTP falham de forma aberta por design: se um censor der erro ou um modelo estiver indisponível, o texto original passa em vez de bloquear o trabalho. Quando você precisa de uma garantia firme, marque a conexão de modelo com `require_redaction` em `config.json`. Um modelo marcado assim se recusa a rodar a menos que o agente tenha pelo menos um hook de censura habilitado, transformando uma limpeza de melhor esforço em uma obrigatória.

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

O painel web fica aberto em localhost por padrão, o que é conveniente para o desenvolvimento local. No momento em que você o expõe além da sua máquina, coloque-o atrás de uma senha:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Você pode passar uma senha literal ou uma referência `${ENV_VAR}` para que o segredo fique fora do arquivo. Uma vez definida a senha, o painel exige entrar em `/login`. Limpe-a com `pepe dashboard password --clear`.

A senha é lida de `dashboard.password` na configuração (interpolada), com um recuo para a variável de ambiente `PEPE_DASHBOARD_PASSWORD`. Dois ajustes relacionados reforcam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores extras do cabeçalho `Host` que o painel aceita. Isso serve também como a lista de permissão contra o reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies reversos cujo cabeçalho `X-Forwarded-For` pode ser considerado confiável. Vazio por padrão, o que significa que nenhum cabeçalho de encaminhamento é confiável.

Vinculado a uma interface pública sem senha, o painel se fecha por padrão e bloqueia clientes remotos até que você defina uma.

## Tokens da API

Sem nenhum token, a API HTTP responde apenas a chamadas de loopback (localhost), então uma configuração local continua simples enquanto um servidor exposto na rede nunca fica anônimo. Criar o primeiro token a fecha para todo mundo (local ou remoto): dai em diante cada requisição para `/v1` precisa de um cabeçalho `Authorization: Bearer` carregando um token válido. Gere um com:

```bash
pepe token add --label "ci pipeline"
```

O token em bruto é mostrado uma única vez e apenas o seu hash SHA-256 é armazenado, nunca o token em si. Um token pode ter escopo: `--company` o limita aos agentes de uma empresa, e `--agent` o limita a um único agente (que precisa estar dentro daquela empresa). Gerencie-os com `pepe token list` e `pepe token revoke ID`, pela página de tokens da API do painel, ou pela conversa com um agente que tenha a ferramenta protegida `manage_token`. Para os formatos das requisições e o uso do SDK, veja a [página da API HTTP](./api/).

## Isolamento multiempresa

O trabalho pode ser separado por empresa (um escopo de empresa baseado num identificador). O escopo padrão, sem empresa, se chama Principal. Os agentes, modelos e chaves de provedor de uma empresa ficam invisíveis para as outras empresas, e um token de API com escopo de empresa alcança apenas os agentes daquela empresa. Isso impede que as credenciais e conversas de uma empresa vazem para as de outra, o que importa quando você hospeda agentes em nome de vários clientes a partir de uma única instância do Pepe.
