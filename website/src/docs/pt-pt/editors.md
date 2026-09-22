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

**A tua conversa persiste.** Fechar o editor não a termina. Cada conversa de ACP é guardada da mesma forma que uma do painel web ou do Telegram, por isso o histórico do teu editor consegue listar sessões anteriores, retomar uma de onde a deixaste ou recuperar uma que começaste noutro diretório de projeto. Duas janelas do editor não conseguem pisar a mesma conversa às escondidas: se uma já está aberta noutro sítio, és avisado e recebes a opção de a bifurcar em vez disso, o que continua a partir do mesmo ponto com um id novo e separado. Sessões sem uso há 30 dias, ou as mais antigas a partir de 200, são limpas sozinhas; nenhuma que ainda esteja aberta é tocada.

**Comandos com barra, dentro do próprio painel.** Escreve `/status`, `/rewind 2`, `/model`, `/usage` e os restantes, os mesmos comandos e as mesmas respostas que terias no Telegram ou no `mix pepe chat`: aparecem na paleta de comandos do editor com a sua própria descrição. Alguns, como `/rewind` e `/undo`, reescrevem a conversa e esperam que termine uma vez em curso; outros, como `/status` e `/steer`, funcionam a qualquer momento. Tudo o que escrevas que não seja um destes segue para o agente como uma mensagem normal.

**Um painel de plano e um medidor de contexto, quando o agente os usa.** Uma tarefa de vários passos que o agente acompanha com a sua própria ferramenta de planeamento aparece como uma lista de verificação no editor, atualizada conforme os passos são concluídos. Depois de cada resposta, o editor também fica a saber quanto da janela de contexto do modelo a conversa está a ocupar, o mesmo número que o `/context` mostra.

**Trocar de modelo ou de quanto pode fazer sem perguntar, a meio da conversa.** As definições de sessão do teu próprio editor (não o `pepe agent add`, não o `config.json`) deixam-te escolher entre os modelos já configurados para este agente, e escolher um modo de aprovação de edições: perguntar antes de cada alteração a um ficheiro (o modo predefinido), deixar passar sem perguntar as edições dentro do projeto, ou deixar passar sem perguntar as edições em qualquer sítio. Um caminho sensível, uma chamada que uma política escalou, ou qualquer coisa depois de a conversa ter lido conteúdo de fora continua a perguntar seja qual for o modo: os modos só aliviam a pergunta de edição de ficheiros, nunca nenhum outro controlo de permissão.

**Imagem, áudio e ficheiros trazidos para o prompt com `@`.** O que é realmente usado depende do agente com quem falas: uma imagem é entregue como imagem a um modelo com visão e recusada com um motivo claro a um que não vê; uma nota de voz é transcrita se tiveres uma via de transcrição configurada (vê [Voz](../voice/)); o contexto de ficheiro incorporado (o que o teu editor envia quando mencionas um ficheiro com `@`) funciona sempre. Nada é descartado às escondidas: um bloco que o agente não consegue usar é-te comunicado, não é deitado fora.

**Servidores MCP configurados no editor.** Se o teu editor estiver preparado para entregar servidores MCP ao agente para este projeto, o Pepe passa agora a usá-los só nessa conversa: nunca gravados no `config.json`, nunca disponíveis para outra sessão, canal ou agente, e param assim que o editor se desliga. Um servidor que não arranca não interrompe a conversa; és avisado, e o resto continua a funcionar. Configura-os no agente, com `pepe mcp add`, quando os quiseres disponíveis em todos os canais de uma vez. Vê [MCP](../mcp/).

### Configurar uma ligação a um modelo a partir do próprio editor

O `session/new` num agente sem uma ligação a modelo utilizável falha de imediato e diz ao editor para oferecer autenticação, para nunca ficares com uma ligação que abre bem e depois falha na primeira mensagem. Não há onde iniciar sessão (o Pepe autentica-se junto do fornecedor do modelo com a sua própria configuração, não a do editor), por isso o que é oferecido na prática é uma escolha entre duas formas de resolver: usar as ligações de modelo que já tens configuradas no Pepe, se as tiveres, ou abrir um terminal que executa a configuração interativa do Pepe (`pepe acp --setup`) para adicionar uma.

### O que não faz, e porquê

**Ler ficheiros e abrir terminais através do editor.** O agente já tem ferramentas próprias para ambas as coisas, a correr na mesma máquina. Dar essa volta só criaria um segundo conjunto de regras para manter de acordo com o primeiro.

**Fazer-te uma pergunta a meio de uma chamada de ferramenta (elicitação).** Toda a pergunta que o Pepe precisa que uma pessoa responda é ou um pedido de permissão ou uma mensagem na conversa: não há um terceiro tipo de interrupção para o qual montar uma interface à parte.

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
