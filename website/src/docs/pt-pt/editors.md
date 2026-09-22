---
title: Editores de código
description: Liga um agente do Pepe ao teu editor através do Agent Client Protocol.
---

## O teu agente dentro do editor

Os editores aprenderam a falar com agentes da mesma maneira que já falavam com servidores de linguagem: arrancam um processo pequeno em segundo plano e trocam mensagens com ele. O protocolo para isso é o [Agent Client Protocol](https://agentclientprotocol.com), uma norma aberta que não pertence a nenhum editor nem a nenhum agente em concreto.

O Pepe fala essa norma. Apontas o editor para um comando e o agente que já configuraste passa a responder no painel de conversa do próprio editor, com as ferramentas, a memória, as competências e as permissões dele. Nada é duplicado: é o mesmo agente que responde no Telegram, no painel web e na consola.

### Como arrancar

```bash
pepe acp                 # o agente predefinido
pepe acp apoio           # um agente concreto
pepe acp --project acme  # o agente predefinido desse projeto
```

Raramente vais escrever isto. Quem o executa é o editor, como processo filho, falando com ele pela entrada e pela saída. O que configuras no editor é essa linha de comando.

Procura nas preferências do editor por agentes externos, personalizados ou ACP e indica o comando acima. Se te pedir o executável e os argumentos em separado, o executável é `pepe` e a lista de argumentos é `["acp"]`, mais o nome do agente quando quiseres um em concreto.

**Estás a correr a partir do código-fonte?** Então o comando é `MIX_QUIET=1 mix pepe acp`. O `MIX_QUIET=1` conta: o protocolo não admite nada na saída além das suas próprias mensagens, e sem ele a linha "Compiling..." da ferramenta de compilação cai ali pelo meio e baralha o editor.

### O que ganhas

**A resposta à medida que é escrita.** O texto vai surgindo no painel conforme o agente escreve, tal como na consola.

**Cada chamada de ferramenta, no momento.** Quando o agente lê um ficheiro, corre um comando ou pesquisa na web, o editor mostra a chamada e depois o resultado. Vês os argumentos reais, não apenas o nome da ferramenta.

**Um pedido de permissão a sério.** É esta a parte que compensa. Quando o agente quer fazer algo que depende do teu aval, o editor pergunta-te ali mesmo, com o comando exato à tua frente e as mesmas respostas que terias em qualquer outro canal:

- permitir uma vez
- permitir tudo nesta tarefa
- permitir nesta sessão
- permitir sempre
- não permitir

A tua resposta significa exatamente o que significa no resto do Pepe. "Permitir sempre" grava a mesma permissão permanente que gravaria se tivesses respondido no Telegram, limitada àquilo que estavas realmente a ver e não ao nome da ferramenta. Se a tarefa leu alguma coisa vinda de fora da conversa, as permissões permanentes ficam suspensas para ela e o agente volta a perguntar, e é por isso que a resposta recomendada muda nessa situação. Vê [Segurança](../security/) para o alcance de cada resposta.

**Cancelar.** Interrompes a vez a partir do editor e o agente para, mesmo quando está à espera de uma permissão que ninguém respondeu.

### O que não faz, e porquê

O Pepe implementa o núcleo do protocolo e avisa, logo no aperto de mão inicial, que partes ficaram de fora, para que o editor nunca te ofereça algo que não vai funcionar:

**Retomar uma conversa anterior.** A sessão dura enquanto o editor mantiver o processo de pé. Fechado o editor, acabou. As conversas de vida longa ficam nos canais feitos para isso.

**Iniciar sessão.** Não há onde. O Pepe autentica-se no fornecedor do modelo com a configuração dele próprio.

**Imagem, áudio e anexos no prompt.** Só texto, para já. Podes na mesma apontar um ficheiro ao agente mencionando o caminho: ele lê-o sozinho.

**Servidores MCP configurados no editor.** Se o teu editor estiver preparado para entregar servidores MCP ao agente, o Pepe recusa em vez de aceitar e depois não os usar às escondidas. Configura-os no agente, com `pepe mcp add`, e passam a valer em todos os canais de uma vez. Vê [MCP](../mcp/).

**Ler ficheiros e abrir terminais através do editor.** O agente já tem ferramentas próprias para ambas as coisas, a correr na mesma máquina. Dar essa volta só criaria um segundo conjunto de regras para manter de acordo com o primeiro.

### O que o agente pode fazer

Tudo o que o agente alcança aqui vem da configuração dele, não da do editor. `pepe agent list` mostra as ferramentas que tem e `pepe tools` mostra as que existem. Um agente sem `bash` também não corre comandos a partir do teu editor, e um agente com `bash` pergunta antes.

Se quiseres para o editor um agente mais restrito do que o do dia a dia, cria um segundo e aponta o editor para esse:

```bash
pepe agent add revisor --prompt "Revês código. Sê direto." --tools read_file,list_dir
pepe acp revisor
```

### Vê também

- [Segurança](../security/) explica o que cada resposta de permissão concede na prática.
- [Agentes](../agents/) explica como criar e moldar o agente que atende aqui.
- [API HTTP](../api/) é o outro caminho para chegar a um agente a partir do teu próprio programa.
