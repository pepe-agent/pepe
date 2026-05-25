---
title: Backup e extração
description: Arquive a instalação inteira, ou retire um projeto para rodar no próprio servidor, e restaure qualquer uma das duas com um único comando.
---

Tudo o que o Pepe sabe vive como arquivos sob `~/.pepe/` (ou `PEPE_HOME`), então mover isso é mover um diretório. Dois comandos criam um arquivo compactado dele, e um restaura qualquer um dos dois.

## Backup: a instalação inteira

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /caminho/x.tgz
```

Este é o arquivo do tipo "não perca esta máquina". Ele empacota todos os projetos, todos os workspaces dos agentes, o espaço compartilhado, as sessões e os livros-razão de uso, e pula `data/mnesia/` (um cache descartável que se reconstrói sozinho). Restaurado em uma máquina vazia, ele é a mesma máquina de novo.

## Extração: um projeto, por conta própria

```bash
pepe extract acme                 # gera acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /caminho/acme.tgz
```

Um projeto que cresceu dentro de uma instalação compartilhada pode sair para rodar no próprio servidor. Você não chega lá copiando uma pasta, porque as entradas desse projeto estão entrelaçadas no `config.json` compartilhado como identificadores `acme/agente`. A extração reescreve esses identificadores para nomes simples do projeto default, então o arquivo é uma **instalação nova e de um único projeto que por acaso é aquele projeto** — coloque em um servidor novo e execute.

Só aquele projeto viaja: seus agentes, modelos, crons, watches, bots, tokens, workspaces e histórico de uso. Nada dos outros projetos vai junto. Se um dos seus agentes depende de um **modelo compartilhado** (um que vive no projeto default, não dentro do projeto extraído), esse modelo também é puxado para o arquivo, para o pacote funcionar em uma máquina vazia; o comando informa quais.

## Restauração: qualquer um dos arquivos

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

Um backup e uma extração têm a mesma forma — um `~/.pepe` dentro de um tarball — então um único comando restaura os dois. Ele descompacta em `~/.pepe` (ou `PEPE_HOME`). Como uma restauração **substitui** o que está lá, ela se recusa a sobrescrever um diretório não vazio a menos que você passe `--force`.

## Os segredos nunca estão no arquivo

Segredos são referências `${ENV_VAR}`, resolvidas no momento da leitura, então vivem no seu ambiente e nunca nos arquivos (veja [Segredos](/pt-br/docs/secrets/)). Isso significa que eles **não** estão em um backup nem em uma extração, por design. Cada um desses comandos imprime as variáveis que o arquivo referencia e se cada uma está definida no momento, para que você possa provisioná-las no destino. Reexporte-as lá e a configuração se resolve; esqueça uma e o que quer que ela liberasse simplesmente não estará presente.
