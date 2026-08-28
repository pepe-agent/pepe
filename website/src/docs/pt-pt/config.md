---
title: Configuração
description: Onde o Pepe guarda a tua configuração, como as chaves ficam fora dos ficheiros, e como fazer cópia de segurança de tudo com um único comando.
---

## Onde vive a tua configuração

Tudo o que fizeste até agora ficou gravado em `~/.pepe/config.json`: a ligação ao
modelo, o agente, e quaisquer canais que tenhas ligado. Nada de base de dados, nada de
migrações. Para levares uma configuração para outra máquina basta copiar esse ficheiro e
definir as mesmas variáveis de ambiente que as tuas referências `${VAR}` apontam.

```bash
pepe config
```

Este comando mostra o caminho da configuração e um resumo do que lá está definido. Um
ficheiro completo tem este aspeto:

```json
{
  "default_model": "openrouter",
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-5-chat",
      "max_tokens": 4096
    }
  },
  "default_agent": "assistant",
  "agents": {
    "assistant": {
      "model": "openrouter",
      "system_prompt": "You are Pepe, a helpful agent.",
      "tools": ["bash", "run_script", "read_file", "write_file", "edit_file", "list_dir", "fetch_url", "web_search"],
      "auto_approve": ["read_file"],
      "max_iterations": 12
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [], "require_mention": true },
  "locale": "en",
  "server": { "port": 4000 }
}
```

O campo `auto_approve` lista as ferramentas que esse agente pode correr sem parar para te
perguntar nada, como é explicado na página de Segurança. Para mudar onde o ficheiro fica,
usa `PEPE_HOME` (uma pasta) ou `PEPE_CONFIG` (um ficheiro específico).

### O que um agente guarda em disco

Cada agente tem também a sua própria pasta persistente, `~/.pepe/agents/<name>/`, onde
fica o `SOUL.md` (a sua persona) e qualquer ficheiro que crie enquanto trabalha, como
`MEMORY.md`, `people.md` ou outros que decida manter. Já `~/.pepe/shared/` é partilhado
entre todos os agentes.

Um agente sem identidade própria (sem `SOUL.md`, ainda na configuração inicial)
apresenta-se simplesmente como Pepe, avisa que ainda não tem nome nem características
definidas, e propõe-se a tratar disso. As tuas respostas ficam gravadas no `SOUL.md`, e é
a própria ferramenta `rename_agent` que muda o nome do agente a partir daí.

### Um modelo barato para as tarefas menores (`utility_model`)

Nem toda a chamada ao modelo é o agente a pensar; algumas são só o agente a arrumar a
casa. Dar nome a uma conversa, para a barra lateral do painel mostrar algo legível, é
o primeiro caso disto. Aponta `utility_model` para qualquer ligação que já tenhas
configurada, e essas chamadas passam a ir para lá:

```json
{
  "agents": {
    "assistant": {
      "model": "openrouter",
      "utility_model": "groq-fast"
    }
  }
}
```

Ou seja, `model` faz o trabalho, `utility_model` dá nome à conversa. O mesmo pela CLI:

```bash
pepe agent add assistant --model openrouter --utility-model groq-fast
```

Também está disponível no painel, em Agents, depois Edit, depois Chores; e um agente
com a ferramenta `manage_agent` consegue mudar isto pela própria conversa, bastando dizer
algo como "trata das tuas tarefas menores no groq-fast".

**Sem nada definido, as conversas continuam a receber nome**, tirado das primeiras
palavras da mensagem de abertura. Isto não custa nada, funciona offline, e a primeira
mensagem de ninguém sai dali para ser lida por terceiros. Não é muito pior do que aquilo
que uma barra lateral serve mesmo para fazer, que é tu reconheceres a conversa. O que o
Pepe nunca faz é cair de volta no modelo do próprio agente: isso passaria a gastar em
qualquer instalação que só tenha atualizado de versão, e o Pepe cobra esses tokens a um
projeto. Um `utility_model` que aponte para uma ligação inexistente conta como se
estivesse por definir, pela mesma razão, e o `pepe doctor` avisa disso: um erro de
digitação não pode ser o motivo pelo qual algo começa a gastar dinheiro.

Um aviso sobre os planos "gratuitos" de modelos: o texto enviado para dar nome a uma
conversa é a **mensagem de abertura** do cliente, e é justamente aí que está o nome, o
telefone e a queixa. A maior parte dos planos gratuitos paga-se com os teus dados. Se não
puseste essa mensagem num conjunto de treino de boa vontade, não apontes `utility_model`
para um deles. O caminho sem modelo nenhum existe precisamente para isso não ser preciso.

A compactação, de propósito, não usa o modelo utilitário. Um resumo mal escrito não fica
só feio de ler, ele desinforma silenciosamente todos os turnos seguintes que o lerem, e o
agente não tem como perceber isso sozinho. O critério aqui é a forma como a falha
acontece, não o preço: se sair errado só parecer desleixado, é uma tarefa menor; se sair
errado deixar o agente enganado, já não é.

## Os segredos ficam só como referências

A configuração é um ficheiro JSON simples em `~/.pepe/config.json`, sem nenhuma base de
dados por trás. Para manter credenciais fora desse ficheiro, escreve-as como referências
`${ENV_VAR}`. O Pepe substitui pelo valor real, lido do ambiente, no momento em que abre
o ficheiro, e o valor propriamente dito nunca chega a ser gravado em disco.

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

Enquanto o Pepe está a correr, a chave real vem do ambiente; em disco, o ficheiro guarda
sempre só o marcador. O mesmo mecanismo serve para tokens de gateway, definições de
plugins e a palavra-passe do painel, por isso dá para partilhar ou versionar uma
configuração sem revelar nada. Basta exportar as variáveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador que se resolve em nada, porque a variável não está definida, é tratado como
"não definido" e não como uma cadeia vazia, por isso um segredo em falta aparece como um
"não configurado" bem claro, em vez de passar em branco sem se notar.

### Fazer isto pela conversa

Um agente com as ferramentas de leitura `config_get` e `doctor` consegue relatar o estado
da configuração e apanhar um segredo em falta numa conversa normal, sem precisar de mais
nada. Como as duas são só de leitura, nunca acionam a barreira de permissão.

> Tu: Está tudo configurado corretamente?
>
> Agente: (corre `doctor`) Encontrei um problema: a ligação de modelo "openrouter"
> refere-se a `${OPENROUTER_API_KEY}`, mas essa variável não está definida no ambiente.
> Exporta-a antes de servir.

A ferramenta `doctor` verifica a saúde de toda a configuração e assinala segredos
`${ENV}` por definir, agentes a apontar para modelos inexistentes, agendamentos
inválidos, e ligações que não respondem. Passa `live: true` para também sondar a rede.

<div class="note"><strong>As definições sensíveis à segurança não podem ser mudadas pela ferramenta geral de configuração.</strong> A ferramenta protegida <code>config_set</code> funciona fechada por omissão: só toca numa lista curta e explícita (o modelo e o agente predefinidos, o idioma, o fuso horário, algumas opções do Telegram, e <code>secrets.expose_env</code>, a lista de <em>nomes</em> de variáveis de ambiente que o shell do agente mantém depois da limpeza, para poder abrir um cofre para o qual já tem um token). Os valores dos segredos, as listas de ferramentas permitidas, os tokens de bot, o invólucro do sandbox e a palavra-passe do painel ficam de fora dessa lista de propósito, e por isso o <code>config_set</code> não os consegue tocar; esses és tu que defines, pela CLI ou pelo painel. A única coisa que um agente consegue mesmo gerar pela conversa são tokens de API, mas só através da ferramenta separada e protegida por permissão <code>manage_token</code>, nunca pelo <code>config_set</code>.</div>

## Armazenamento e cópia de segurança: só ficheiros, sem base de dados nenhuma

Está tudo dentro de `~/.pepe/` (ou de `PEPE_HOME`), sem nenhum servidor de base de dados
no meio. O `config.json` é a única fonte de verdade para projetos, agentes, modelos,
watches, crons, bots, servidores MCP e tokens de API já com hash aplicado. O
conhecimento de cada agente existe como ficheiros dentro de `agents/<name>/` e de
`projects/<slug>/agents/<name>/`, o histórico das conversas fica em `data/sessions/`, e
`data/mnesia/` é apenas uma cache descartável que se reconstrói sozinha quando precisa. O
`Pepe.Repo` e o Postgres já existem no código mas estão desligados
(`ecto_repos: []`), guardados ali como porta aberta para um futuro backend de base de
dados que hoje ainda não é usado.

Nenhum segredo é guardado em texto simples: são sempre referências `${ENV_VAR}`
resolvidas no momento da leitura, por isso vivem no teu ambiente, nunca nos ficheiros.

Fazer a cópia de segurança é um único comando. Ele arquiva as partes duráveis, ignora a
cache descartável, e lista as variáveis de ambiente secretas que precisas de guardar à
parte, já que essas ficam de fora do arquivo de propósito:

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /path/x.tgz
```

Para restaurar, corre `pepe restore esse-arquivo.tgz` e volta a exportar essas mesmas
variáveis. Também dá para tirar um único projeto e pô-lo a correr no seu próprio
servidor com `pepe extract`. A história completa está em [Cópia de segurança e
extração](/pt-pt/docs/backup/).
