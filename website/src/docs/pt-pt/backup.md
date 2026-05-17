---
title: Cópia de segurança e extração
description: Arquive a instalação inteira, ou retire uma empresa para correr no seu próprio servidor, e restaure qualquer uma das duas com um único comando.
---

Tudo o que o Pepe sabe vive como ficheiros em `~/.pepe/` (ou `PEPE_HOME`), por isso mover isto é mover um diretório. Dois comandos criam um arquivo dele, e um restaura qualquer um dos dois.

## Cópia de segurança: a instalação inteira

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /caminho/x.tgz
```

Este é o arquivo do género "não perca esta máquina". Empacota todas as empresas, todos os espaços de trabalho dos agentes, o espaço partilhado, as sessões e os livros-razão de utilização, e ignora `data/mnesia/` (uma cache descartável que se reconstrói sozinha). Restaurado numa máquina vazia, é a mesma máquina outra vez.

## Extração: uma empresa, por si só

```bash
pepe extract acme                 # gera acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /caminho/acme.tgz
```

Uma empresa que cresceu dentro de uma instalação partilhada pode sair para correr no seu próprio servidor. Não se chega lá a copiar uma pasta, porque os registos dessa empresa estão entrelaçados no `config.json` partilhado como identificadores `acme/agente`. A extração reescreve esses identificadores para nomes de raiz simples, por isso o arquivo é uma **instalação nova e de um único inquilino que por acaso é aquela empresa** — coloque-a num servidor novo e execute.

Só aquela empresa viaja: os seus agentes, modelos, crons, watches, bots, tokens, espaços de trabalho e histórico de utilização. Nada dos outros inquilinos vai junto. Se um dos seus agentes depende de um **modelo partilhado** (um que vive na raiz, não dentro da empresa), esse modelo também é puxado para o arquivo, para que o pacote funcione numa máquina vazia; o comando diz-lhe quais.

## Restauro: qualquer um dos arquivos

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

Uma cópia de segurança e uma extração têm a mesma forma — um `~/.pepe` dentro de um tarball — por isso um único comando restaura os dois. Descompacta para `~/.pepe` (ou `PEPE_HOME`). Como um restauro **substitui** o que lá está, recusa-se a escrever por cima de um diretório não vazio a menos que passe `--force`.

## Os segredos nunca estão no arquivo

Os segredos são referências `${ENV_VAR}`, resolvidas no momento da leitura, por isso vivem no seu ambiente e nunca nos ficheiros (veja [Segredos](/pt-pt/docs/secrets/)). Isto significa que **não** estão numa cópia de segurança nem numa extração, por conceção. Cada um destes comandos imprime as variáveis que o arquivo referencia e se cada uma está definida no momento, para que possa aprovisioná-las no destino. Reexporte-as aí e a configuração resolve-se; esqueça uma e aquilo que ela desbloqueava fica simplesmente ausente.
