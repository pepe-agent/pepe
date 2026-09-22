---
title: Editores de código
description: Ligue um agente do Pepe ao seu editor pelo Agent Client Protocol.
---

## Seu agente dentro do editor

Os editores aprenderam a conversar com agentes do mesmo jeito que já conversavam com servidores de linguagem: sobem um processo pequeno em segundo plano e trocam mensagens com ele. O protocolo disso é o [Agent Client Protocol](https://agentclientprotocol.com), um padrão aberto que não pertence a nenhum editor nem a nenhum agente em particular.

O Pepe fala esse protocolo. Você aponta o editor para um comando e o agente que já configurou passa a responder no painel de conversa do próprio editor, com as ferramentas, a memória, as habilidades e as permissões dele. Nada é duplicado: é o mesmo agente que responde no Telegram, no painel web e no console.

### Como subir

```bash
pepe acp                 # o agente padrão
pepe acp suporte         # um agente específico
pepe acp --project acme  # o agente padrão daquele projeto
```

Você quase nunca vai digitar isso. Quem executa é o editor, como processo filho, conversando pela entrada e pela saída dele. O que você configura no editor é essa linha de comando.

Procure nas preferências do editor por agentes externos, personalizados ou ACP e informe o comando acima. Se ele pedir o executável e os argumentos separadamente, o executável é `pepe` e a lista de argumentos é `["acp"]`, mais o nome do agente quando quiser um específico.

**Está rodando a partir do código-fonte?** Aí o comando é `MIX_QUIET=1 mix pepe acp`. O `MIX_QUIET=1` faz diferença: o protocolo não admite nada na saída além das próprias mensagens, e sem ele a linha "Compiling..." da ferramenta de build cai ali no meio e confunde o editor.

### O que você ganha

**A resposta enquanto ela é escrita.** O texto vai aparecendo no painel conforme o agente escreve, igual ao console.

**Cada chamada de ferramenta, na hora.** Quando o agente lê um arquivo, roda um comando ou pesquisa na web, o editor mostra a chamada e depois o resultado. Você vê os argumentos de verdade, não só o nome da ferramenta.

**Um pedido de permissão para valer.** Essa é a parte que compensa. Quando o agente quer fazer algo que depende do seu aval, o editor pergunta ali mesmo, com o comando exato na sua frente e as mesmas respostas que você teria em qualquer outro canal:

- permitir uma vez
- permitir tudo nesta tarefa
- permitir nesta sessão
- permitir sempre
- não permitir

A sua resposta significa exatamente o que significa no resto do Pepe. "Permitir sempre" grava a mesma permissão permanente que gravaria se você tivesse respondido no Telegram, limitada ao que você estava realmente olhando e não ao nome da ferramenta. Se a tarefa leu alguma coisa vinda de fora da conversa, as permissões permanentes ficam suspensas para ela e o agente volta a perguntar, e é por isso que a resposta recomendada muda nessa situação. Veja [Segurança](../security/) para o alcance de cada resposta.

**Cancelar.** Interrompa a vez pelo editor e o agente para, inclusive quando está parado esperando uma permissão que ninguém respondeu.

### O que não dá, e por quê

O Pepe implementa o núcleo do protocolo e avisa, logo no aperto de mão inicial, quais partes ficaram de fora, para o editor nunca oferecer algo que não vai funcionar:

**Retomar uma conversa antiga.** A sessão vive enquanto o editor mantiver o processo de pé. Fechou o editor, acabou. Conversas de vida longa ficam nos canais feitos para isso.

**Fazer login.** Não há onde. O Pepe se autentica no provedor de modelo com a configuração dele mesmo.

**Imagem, áudio e anexos no prompt.** Só texto, por enquanto. Você ainda pode apontar um arquivo para o agente mencionando o caminho: ele lê sozinho.

**Servidores MCP configurados no editor.** Se o seu editor estiver preparado para entregar servidores MCP ao agente, o Pepe recusa em vez de aceitar e silenciosamente não usar. Configure-os no agente, com `pepe mcp add`, e eles valem em todos os canais de uma vez. Veja [MCP](../mcp/).

**Ler arquivos e abrir terminais através do editor.** O agente já tem ferramentas próprias para as duas coisas, rodando na mesma máquina. Passar por fora só criaria um segundo conjunto de regras para manter de acordo com o primeiro.

### O que o agente pode fazer

Tudo o que o agente alcança aqui vem da configuração dele, não do editor. `pepe agent list` mostra quais ferramentas ele tem e `pepe tools` mostra o que existe. Um agente sem `bash` também não roda comandos a partir do seu editor, e um agente com `bash` pergunta antes.

Se quiser um agente para o editor mais restrito que o do dia a dia, crie um segundo e aponte o editor para ele:

```bash
pepe agent add revisor --prompt "Você revisa código. Seja direto." --tools read_file,list_dir
pepe acp revisor
```

### Veja também

- [Segurança](../security/) explica o que cada resposta de permissão concede de fato.
- [Agentes](../agents/) explica como criar e moldar o agente que vai atender aqui.
- [API HTTP](../api/) é o outro caminho para chegar a um agente pelo seu próprio programa.
