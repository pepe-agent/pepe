---
title: Backup e extração
description: Arquive a instalação inteira, ou tire um projeto para rodar no próprio servidor, e restaure qualquer um dos dois com um único comando.
---

Tudo o que o Pepe sabe existe como arquivos dentro de `~/.pepe/` (ou
`PEPE_HOME`), então mover isso é simplesmente mover um diretório. Dois
comandos empacotam esse diretório, e um terceiro restaura qualquer um dos dois
pacotes.

## Backup: a instalação inteira

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /caminho/x.tgz
```

Esse é o arquivo do tipo "não posso perder esta máquina". Ele empacota todos
os projetos, todos os workspaces de agente, o espaço compartilhado, as
sessões e os livros-razão de uso, e deixa de fora `data/mnesia/` (um cache
descartável que se reconstrói sozinho). Restaurado numa máquina vazia, ele
recria a mesma máquina de antes.

Dá para rodar com o Pepe no ar: o banco de dados (compromissos, watches,
traces, boards, uso) nunca é copiado enquanto pode estar no meio de uma
escrita. Em vez disso, o `backup` tira um snapshot pela própria conexão ativa,
com consistência garantida como retrato de um único instante
(transacionalmente consistente), e verifica esse snapshot antes de colocá-lo
no arquivo. Se a verificação falhar, o comando aborta em vez de embarcar algo
quebrado. Para reverificar um arquivo que você já tem:

```bash
pepe backup verify pepe-backup-2026-07-14.tgz
```

## Extração: um projeto, por conta própria

```bash
pepe extract acme                 # gera acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /caminho/acme.tgz
```

Um projeto que cresceu dentro de uma instalação compartilhada pode sair para
rodar no próprio servidor. Só copiar uma pasta não resolve, porque as entradas
desse projeto estão entrelaçadas no `config.json` compartilhado como
identificadores `acme/agente`. A extração reescreve esses identificadores para
os nomes simples de um projeto default recém-criado, então o que sai é uma
**instalação nova, de projeto único, que por acaso é aquele projeto**: basta
colocar num servidor novo e rodar.

Só aquele projeto faz a viagem: seus agentes, modelos, crons, watches, bots,
tokens, workspaces e histórico de uso. Nada dos outros tenants vai junto. Se
algum dos agentes dele depende de um **modelo compartilhado** (um que vive no
projeto default, e não dentro do projeto extraído), esse modelo também é
puxado para o arquivo, para o pacote funcionar sozinho numa máquina vazia; o
comando informa quais modelos entraram por esse motivo.

## Restauração: qualquer um dos dois arquivos

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

Um backup e uma extração têm a mesma forma por baixo (um `~/.pepe` dentro de
um tarball), então um único comando restaura os dois. Ele descompacta em
`~/.pepe` (ou `PEPE_HOME`). Como uma restauração **substitui** o que já está
lá, ela recusa sobrescrever um diretório não vazio a menos que você passe
`--force`.

O banco de dados de um backup passa pela mesma verificação de integridade na
volta: a restauração recusa um banco que falhe nela, e recusa também
sobrescrever um sobre o qual uma instância do Pepe ativa pareça estar
escrevendo no momento. Nesse caso, pare essa instância primeiro e tente de
novo.

## Os segredos nunca vão no arquivo

Segredos são referências `${ENV_VAR}`, resolvidas no momento da leitura, então
vivem no seu ambiente e nunca dentro dos arquivos (veja
[Segredos](/pt-br/docs/secrets/)). Isso significa que eles **não** entram nem
num backup nem numa extração, por design. Cada um desses comandos imprime as
variáveis que o arquivo referencia e se cada uma está definida no momento, para
que você consiga provisioná-las de novo no destino. Reexporte-as lá e a
configuração volta a se resolver sozinha; esqueça alguma, e o que quer que ela
liberasse simplesmente fica ausente.
