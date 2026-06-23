---
title: Configuração
description: Entenda onde o Pepe guarda configuração, segredos e estado de execução.
---

## Onde sua configuração vive

Tudo o que você fez acima está agora em `~/.pepe/config.json`: a conexão do modelo,
o agente e quaisquer canais. Sem banco de dados, sem migrações. Para mover uma
configuração para outra máquina, copie esse arquivo e defina as mesmas variáveis de
ambiente para as quais suas referências `${VAR}` apontam.

```bash
pepe config
```

Isso imprime o caminho da configuração e um resumo do que está definido. Um arquivo completo se parece com isto:

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

`auto_approve` lista as ferramentas que aquele agente pode rodar sem parar para perguntar, como explicado na página de Segurança. Você muda onde o arquivo fica com `PEPE_HOME` (um diretório) ou `PEPE_CONFIG` (um arquivo).

### O que um agente guarda em disco

Cada agente também ganha um diretório persistente em `~/.pepe/agents/<name>/`. Ele guarda o `SOUL.md` do agente (a persona dele) e todo arquivo que ele cria enquanto trabalha (`MEMORY.md`, `people.md` e o que mais ele decidir manter). O `~/.pepe/shared/` é compartilhado entre todos os agentes.

Um agente que ainda não tem identidade (sem `SOUL.md`, ainda na semente padrão) se apresenta como Pepe, avisa que não tem nome nem características definidas, e se oferece para configurar isso. Depois ele salva as suas escolhas no `SOUL.md` e se renomeia com a ferramenta `rename_agent`.

### Um modelo barato para as tarefinhas (`utility_model`)

Algumas chamadas de modelo não são o agente pensando, são o agente arrumando a casa. Dar nome a uma conversa, para que a barra lateral do painel diga alguma coisa, é a primeira delas. Aponte o `utility_model` para qualquer conexão que você já tenha e essas chamadas vão para lá:

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

Também dá para fazer isso no painel, em Agents, depois Edit, depois Chores. E um agente que tem a ferramenta `manage_agent` consegue fazer pela conversa: "faça suas tarefinhas no groq-fast".

**Deixe sem definir e as conversas continuam ganhando nome**, a partir das primeiras palavras da mensagem de abertura. Isso é grátis, é offline, e a primeira mensagem de ninguém é enviada a lugar nenhum para ser lida. Não é muito pior para aquilo que uma barra lateral serve de verdade, que é você reconhecer a conversa. O que o Pepe nunca vai fazer é cair de volta no modelo do próprio agente, porque isso começaria a gastar em toda instalação que apenas atualizou de versão, e o Pepe cobra esses tokens de um projeto. Um `utility_model` apontando para uma conexão que não existe conta como não definido, pelo mesmo motivo, e o `pepe doctor` avisa: um erro de digitação não pode ser o que começa a gastar.

Um aviso sobre as camadas "gratuitas" de modelos. O texto enviado para dar nome a uma conversa é a **mensagem de abertura** do cliente, que é onde moram o nome, o telefone e a reclamação. A maioria das camadas gratuitas se paga com os seus dados. Se você não colocaria essa mensagem num conjunto de treinamento, não aponte o `utility_model` para uma delas. O caminho sem modelo existe justamente para você não precisar.

A compactação deliberadamente não usa o modelo utilitário. Um resumo mal escrito não só é ruim de ler, ele desinforma silenciosamente cada turno que o lê depois, e o agente não tem como perceber. O teste é o formato da falha, não o preço: se errar ali só ficaria desajeitado, é uma tarefinha; se errar ali deixaria o agente errado, não é.

## Os segredos ficam como referências

A configuração fica em um arquivo JSON simples em `~/.pepe/config.json`. Não há banco de dados. Para manter as credenciais fora desse arquivo, escreva-as como referências `${ENV_VAR}`. O Pepe as interpola contra o ambiente no momento da leitura e nunca persiste o valor expandido.

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

> Você: Está tudo configurado corretamente?
>
> Agente: (roda `doctor`) Encontrei um problema: a conexão de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variável não está definida no ambiente. Exporte-a antes de servir.

A ferramenta `doctor` faz uma verificação de saúde de toda a configuração e sinaliza segredos `${ENV}` não definidos, agentes apontando para modelos ausentes, agendamentos inválidos e conexões inalcançáveis. Passe `live: true` para também sondar a rede.

<div class="note"><strong>Ajustes sensíveis à segurança não são editáveis pela ferramenta geral de configuração.</strong> A ferramenta protegida `config_set` recusa por padrão (fail-closed): ela só mexe numa lista de permissão curta (o modelo e o agente padrão, o idioma, o fuso horário, algumas poucas opções do Telegram e `secrets.expose_env` — a lista de *nomes* de variáveis de ambiente que o shell do agente mantém depois da limpeza, para abrir um cofre para o qual tem um token). *Valores* de segredo, listas de ferramentas permitidas, tokens de bot, o invólucro do ambiente isolado e a senha do painel ficam de propósito fora dessa lista, então o `config_set` não consegue mudá-los. Você define esses por conta própria com a CLI ou o painel. Os tokens da API são a única coisa que um agente consegue gerar pela conversa, mas apenas pela ferramenta separada e protegida por barreira de permissão `manage_token`, nunca pelo `config_set`.</div>

## Armazenamento e backup: é tudo arquivo, sem banco de dados

Tudo vive dentro de `~/.pepe/` (ou de `PEPE_HOME`). Não há servidor de banco de dados. O `config.json` é a única fonte da verdade para projetos, agentes, modelos, watches, crons, bots, servidores MCP e tokens de API já com hash. Projetos, modelos e agentes carregam um id interno estável, e o nome ou slug é apenas um rótulo mutável: toda referência entre eles (rota, permissão, padrão, binding de cron, bot ou token) é por id, então renomear qualquer um só troca o rótulo e move o diretório, sem deixar nada pendurado. O conhecimento de um agente vive como arquivos em `agents/<name>/` e em `projects/<slug>/agents/<name>/`, o histórico das conversas em `data/sessions/`, e o `data/mnesia/` é um cache descartável que se reconstrói sozinho. O `Pepe.Repo` e o Postgres existem no código, mas estão desligados (`ecto_repos: []`); são a porta deixada aberta para um futuro backend de banco de dados, hoje sem uso.

Os segredos nunca são guardados em texto puro. São referências `${ENV_VAR}` resolvidas no momento da leitura, então eles vivem no seu ambiente, e não nos arquivos.

Faça backup com um comando só. Ele arquiva as partes duráveis, pula o cache descartável, e lista as variáveis de ambiente secretas que você precisa guardar em separado, porque elas de propósito não entram no arquivo:

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /path/x.tgz
```

Para restaurar, `pepe restore esse-arquivo.tgz` e exporte essas variáveis de novo. Você também pode retirar um único projeto para rodar no próprio servidor com `pepe extract`. Veja [Backup e extração](/pt-br/docs/backup/) para a história completa.
