---
title: Configuração
description: Entende onde o Pepe guarda configuração, segredos e estado de execução.
---

## Onde vive a tua configuração

Tudo o que fizeste acima está agora em `~/.pepe/config.json`: a ligação ao modelo,
o agente e quaisquer canais. Sem base de dados, sem migrações. Para levar uma
configuração para outra máquina, copia esse ficheiro e define as mesmas variáveis de
ambiente para as quais as tuas referências `${VAR}` apontam.

```bash
pepe config
```

Isso imprime o caminho da configuração e um resumo do que está definido. Um ficheiro completo tem este aspeto:

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

`auto_approve` lista as ferramentas que aquele agente pode executar sem parar para te perguntar, tal como é explicado na página de Segurança. Podes mudar onde o ficheiro fica com `PEPE_HOME` (uma diretoria) ou `PEPE_CONFIG` (um ficheiro).

### O que um agente guarda em disco

Cada agente ganha também uma diretoria persistente em `~/.pepe/agents/<name>/`. Guarda o `SOUL.md` do agente (a sua persona) e todos os ficheiros que ele cria enquanto trabalha (`MEMORY.md`, `people.md` e o que mais decidir manter). O `~/.pepe/shared/` é partilhado por todos os agentes.

Um agente que ainda não tem identidade (sem `SOUL.md`, ainda na semente predefinida) apresenta-se como Pepe, diz-te que não tem nome nem características definidas, e oferece-se para configurar isso. Depois guarda as tuas escolhas no `SOUL.md` e renomeia-se com a ferramenta `rename_agent`.

### Um modelo barato para as tarefas menores (`utility_model`)

Algumas chamadas ao modelo não são o agente a pensar, são o agente a arrumar a casa. Dar nome a uma conversa, para que a barra lateral do painel diga alguma coisa, é a primeira delas. Aponta o `utility_model` para qualquer ligação que já tenhas e essas chamadas vão para lá:

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

O `model` faz o trabalho e o `utility_model` dá nome à conversa. O mesmo pela CLI:

```bash
pepe agent add assistant --model openrouter --utility-model groq-fast
```

Também está no painel, em Agents, depois Edit, depois Chores. E um agente que tenha a ferramenta `manage_agent` consegue fazê-lo pela conversa: "faz as tuas tarefas menores no groq-fast".

**Deixa por definir e as conversas continuam a receber nome**, a partir das primeiras palavras da mensagem de abertura. É gratuito, é offline, e a primeira mensagem de ninguém é enviada seja para onde for para ser lida. Não é muito pior para aquilo que uma barra lateral serve realmente, que é reconheceres a conversa. O que o Pepe nunca fará é recorrer ao modelo do próprio agente, porque isso começaria a gastar em cada instalação que apenas atualizou de versão, e o Pepe imputa esses tokens a um projeto. Um `utility_model` a nomear uma ligação que não existe conta como por definir, pelo mesmo motivo, e o `pepe doctor` di-lo: um erro de escrita não pode ser aquilo que começa a gastar.

Um aviso sobre os escalões "gratuitos" de modelos. O texto enviado para dar nome a uma conversa é a **mensagem de abertura** do cliente, que é onde estão o nome, o número de telefone e a reclamação. A maioria dos escalões gratuitos paga-se com os teus dados. Se não colocarias essa mensagem num conjunto de treino, não apontes o `utility_model` para um deles. O caminho sem modelo existe precisamente para não teres de o fazer.

A compactação deliberadamente não usa o modelo utilitário. Um resumo mal escrito não é apenas mau de ler: desinforma silenciosamente todos os turnos que o leem a seguir, e o agente não tem como perceber. O teste é o formato da falha, não o preço: se estar errado ali apenas parecesse desastrado, é uma tarefa menor; se deixasse o agente errado, não é.

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

<div class="note"><strong>As definições sensíveis à segurança não são editáveis pela ferramenta geral de configuração.</strong> A ferramenta protegida `config_set` fecha por predefinição: só mexe numa lista de permissões curta (o modelo e o agente predefinidos, o idioma, o fuso horário, algumas opções do Telegram e `secrets.expose_env` — a lista de *nomes* de variáveis de ambiente que o shell do agente mantém depois da limpeza, para abrir um cofre para o qual tem um token). Os *valores* de segredo, as listas de ferramentas permitidas, os tokens de bot, o invólucro do ambiente isolado e a palavra-passe do painel ficam de propósito fora dessa lista, pelo que o `config_set` não os consegue alterar. És tu que os defines, através da CLI ou do painel. Os tokens da API são a única coisa que um agente consegue gerar pela conversa, mas apenas através da ferramenta separada e protegida por permissões `manage_token`, nunca através do `config_set`.</div>

## Armazenamento e cópia de segurança: são todos ficheiros, sem base de dados

Tudo vive dentro de `~/.pepe/` (ou de `PEPE_HOME`). Não há servidor de base de dados. O `config.json` é a única fonte de verdade para projetos, agentes, modelos, watches, crons, bots, servidores MCP e tokens de API já com hash. O conhecimento de um agente vive como ficheiros em `agents/<name>/` e em `projects/<slug>/agents/<name>/`, o histórico das conversas em `data/sessions/`, e o `data/mnesia/` é uma cache descartável que se reconstrói sozinha. O `Pepe.Repo` e o Postgres existem no código, mas estão desligados (`ecto_repos: []`); são a porta deixada aberta para um futuro backend de base de dados, hoje sem uso.

Os segredos nunca são guardados em texto simples. São referências `${ENV_VAR}` resolvidas no momento da leitura, por isso vivem no teu ambiente e não nos ficheiros.

Faz a cópia de segurança com um único comando. Ele arquiva as partes duráveis, salta a cache descartável, e lista as variáveis de ambiente secretas que tens de guardar em separado, porque de propósito não vão dentro do arquivo:

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /path/x.tgz
```

Para restaurar, `pepe restore esse-arquivo.tgz` e exporta novamente essas variáveis. Também pode retirar um único projeto para correr no seu próprio servidor com `pepe extract`. Veja [Cópia de segurança e extração](/pt-pt/docs/backup/) para a história completa.
