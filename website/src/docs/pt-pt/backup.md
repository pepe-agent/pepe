---
title: Cópia de segurança e extração
description: Arquiva a instalação inteira, ou retira um projeto para correr sozinho no seu próprio servidor, e restaura qualquer um dos dois com um único comando.
---

Tudo o que o Pepe sabe existe como ficheiros dentro de `~/.pepe/` (ou `PEPE_HOME`), por isso mover isto é só mover um diretório. Há dois comandos que criam um arquivo a partir daí, e um terceiro que restaura qualquer um dos dois.

## Cópia de segurança: a instalação inteira

```bash
pepe backup                       # gera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /caminho/x.tgz
```

Este é o arquivo pensado para o cenário "perdi esta máquina". Empacota todos os projetos, todos os workspaces dos agentes, o espaço partilhado, as sessões e os livros-razão de utilização, e deixa de fora `data/mnesia/` (uma cache descartável que se reconstrói sozinha). Restaurado numa máquina vazia, o resultado é a mesma máquina de sempre.

Podes correr este comando com o Pepe em funcionamento. A base de dados (compromissos, watches, traces, boards, utilização) nunca chega a ser copiada enquanto pode estar a meio de uma escrita: em vez disso, o `backup` tira uma captura através da própria ligação ativa, garantida como consistente num único instante (consistente do ponto de vista transacional), e só depois de a verificar é que a mete no arquivo. Se a verificação falhar, o comando aborta em vez de enviar uma captura defeituosa. Para voltares a verificar um arquivo que já tens:

```bash
pepe backup verify pepe-backup-2026-07-14.tgz
```

## Extração: um projeto sozinho

```bash
pepe extract acme                 # gera acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /caminho/acme.tgz
```

Um projeto que cresceu dentro de uma instalação partilhada pode sair de lá para correr no seu próprio servidor. Copiar uma pasta não chega, porque as entradas desse projeto estão entretecidas no `config.json` partilhado sob a forma de identificadores `acme/agente`. A extração reescreve esses identificadores para os nomes simples de um projeto default novo em folha, e é assim que o arquivo acaba por ser uma **instalação nova, de um único inquilino, que por acaso é exatamente aquele projeto**: basta colocá-la num servidor novo e arrancar.

Só esse projeto viaja: os seus agentes, modelos, crons, watches, bots, tokens, workspaces e histórico de utilização. Nada dos outros inquilinos segue junto. E se algum dos seus agentes depender de um **modelo partilhado** (um que vive no projeto default, não dentro deste), esse modelo é puxado para dentro do arquivo também, para que o pacote funcione mesmo numa máquina vazia; o próprio comando diz-te quais foram.

## Restauro: qualquer um dos dois arquivos

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

Uma cópia de segurança e uma extração partilham a mesma forma, um `~/.pepe` dentro de um tarball, por isso um único comando restaura as duas. O que ele faz é descompactar para `~/.pepe` (ou `PEPE_HOME`). Como um restauro **substitui** o que já lá estiver, recusa-se a escrever por cima de um diretório que não esteja vazio, a menos que passes `--force`.

A base de dados de uma cópia de segurança passa pela mesma verificação de integridade no regresso: o restauro recusa uma base de dados que falhe nessa verificação, e recusa também sobrescrever uma sobre a qual uma instância do Pepe já em funcionamento pareça estar a escrever nesse momento. Nesse caso, o caminho é parar essa instância primeiro e só depois tentar de novo.

## Os segredos nunca vão no arquivo

Os segredos são referências `${ENV_VAR}`, resolvidas apenas no momento da leitura, por isso vivem no teu ambiente e nunca nos ficheiros (consulta [Segredos](/pt-pt/docs/secrets/)). Por isso mesmo, de propósito, **não** aparecem nem numa cópia de segurança nem numa extração. Cada um destes comandos imprime as variáveis que o arquivo referencia e se cada uma delas está definida naquele momento, para que as possas provisionar no destino. Volta a exportá-las lá e a configuração resolve-se sozinha; esquece uma, e o que ela desbloqueava fica simplesmente em falta.
