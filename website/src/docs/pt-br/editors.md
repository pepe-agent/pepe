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

**Sua conversa persiste.** Fechar o editor não acaba com ela. Toda conversa de ACP é salva do mesmo jeito que uma do painel web ou do Telegram, então o histórico do seu editor consegue listar sessões passadas, retomar uma de onde você parou ou recuperar uma que você começou em outro diretório de projeto. Duas janelas do editor não conseguem pisar na mesma conversa em silêncio: se uma já está aberta em outro lugar, você é avisado e recebe a opção de bifurcar em vez disso, o que continua do mesmo ponto com um id novo e separado. Sessões sem uso há 30 dias, ou as mais antigas depois de 200, são limpas sozinhas; nenhuma que ainda está aberta é tocada.

**Comandos com barra, direto no painel de conversa.** Digite `/status`, `/rewind 2`, `/model`, `/usage` e o resto, os mesmos comandos e as mesmas respostas que você teria no Telegram ou no `mix pepe chat`: eles aparecem na paleta de comandos do editor com a própria descrição. Alguns, como `/rewind` e `/undo`, reescrevem a conversa e esperam terminar uma vez em andamento; outros, como `/status` e `/steer`, funcionam a qualquer momento. Qualquer coisa que você digitar que não seja um desses vai para o agente como uma mensagem comum.

**Um painel de plano e um medidor de contexto, quando o agente usa isso.** Uma tarefa de vários passos que o agente acompanha com a própria ferramenta de planejamento aparece como uma lista de tarefas no editor, atualizada conforme os passos são concluídos. Depois de cada resposta, o editor também fica sabendo quanto da janela de contexto do modelo a conversa está ocupando, o mesmo número que o `/context` mostra.

**Trocar de modelo ou de quanto ele pode fazer sem perguntar, no meio da conversa.** As configurações de sessão do seu próprio editor (não o `pepe agent add`, não o `config.json`) deixam você escolher entre os modelos já configurados para esse agente, e escolher um modo de aprovação de edições: perguntar antes de cada mudança em arquivo (o padrão), deixar passar sem perguntar as edições dentro do projeto, ou deixar passar sem perguntar as edições em qualquer lugar. Um caminho sensível, uma chamada que uma política escalou, ou qualquer coisa depois que a conversa leu conteúdo de fora continua perguntando não importa o modo: os modos só afrouxam a pergunta de edição de arquivo, nunca nenhum outro controle de permissão.

**Imagem, áudio e arquivos trazidos para o prompt com `@`.** O que de fato é usado depende do agente com quem você está falando: uma imagem é entregue como imagem mesmo para um modelo com visão, e recusada com um motivo claro para um que não vê; uma nota de voz é transcrita se você tem uma via de transcrição configurada (veja [Voz](../voice/)); o contexto de arquivo embutido (o que o seu editor manda quando você menciona um arquivo com `@`) sempre funciona. Nada é descartado em silêncio: um bloco que o agente não consegue usar é informado a você, não jogado fora.

**Servidores MCP configurados no editor.** Se o seu editor estiver preparado para entregar servidores MCP ao agente para este projeto, o Pepe agora usa eles só nessa conversa: nunca gravados no `config.json`, nunca disponíveis para outra sessão, canal ou agente, e param assim que o editor se desconecta. Um servidor que não sobe não derruba a conversa; você é avisado, e o resto continua funcionando. Configure-os no agente, com `pepe mcp add`, quando quiser disponíveis em todos os canais de uma vez. Veja [MCP](../mcp/).

### Configurando uma conexão de modelo direto do editor

O `session/new` num agente sem conexão de modelo utilizável falha na hora e diz ao editor para oferecer autenticação, então você nunca fica com uma conexão que abre de boa e depois falha na primeira mensagem. Não há onde fazer login (o Pepe se autentica no provedor de modelo com a configuração dele mesmo, não a do editor), então o que é oferecido de fato é uma escolha entre dois jeitos de resolver: usar as conexões de modelo que você já tem configuradas no Pepe, se tiver alguma, ou abrir um terminal que roda a configuração interativa do Pepe (`pepe acp --setup`) para adicionar uma.

### O que não dá, e por quê

**Ler arquivos e abrir terminais através do editor.** O agente já tem ferramentas próprias para as duas coisas, rodando na mesma máquina. Passar por fora só criaria um segundo conjunto de regras para manter de acordo com o primeiro.

**Fazer uma pergunta no meio de uma chamada de ferramenta (elicitação).** Toda pergunta que o Pepe precisa que uma pessoa responda é ou um pedido de permissão ou uma mensagem na conversa: não existe um terceiro tipo de interrupção para o qual montar uma interface à parte.

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
