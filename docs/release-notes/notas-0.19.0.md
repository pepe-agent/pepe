# Notas da Versão — 0.19.0

Uma versão focada em **aprendizado de máquina local**, **workflows com lógica real** e **scripts multi-ferramenta em um turno só**.

---

## ✨ Novidades

### Pepe.Insight: aprendizado de máquina local sobre seus dados

Agora o Pepe tem um subsistema que treina pequenos modelos diretamente nos dados que você já tem, sem enviar nada para fora, sem custos recorrentes de API.

**Como funciona:** você define uma pergunta (por exemplo, "vai chover amanhã?" ou "esse cliente vai se manter?"), aponta para os dados históricos que você já coleciona, e o Pepe treina um modelo compacto que responde essa mesma pergunta instantaneamente dali em diante. Cada chamada é praticamente grátis; só paga quando configura ou retreina.

**Que tipo de pergunta você pode fazer:**

- **Classificação:** vai passar ou reprovar? Aprovado ou recusado? Sim ou não?
- **Previsão de número:** quantas unidades vão vender? Qual o valor esperado?
- **Tendência ao longo do tempo:** quantas admissões no próximo mês? O crescimento vai acelerar?
- **Encontrar padrões naturais:** quais grupos de clientes existem nos dados? Que características anormais meu cliente novo tem?

O algoritmo é escolhido automaticamente conforme seus dados crescem: com centenas de linhas, usa algo rápido; com milhares, alterna para árvores de decisão (o mais robusto para dados tabulares); com dezenas de milhares, treina uma rede neural mais potente.

**Não só números:** suas colunas de texto (tipo "plano de assinatura", "região", "tipo de produto") agora funcionam direto: o Pepe codifica automaticamente para você.

**Usar é fácil:**
- Aponte para um banco de dados já conectado ou importe dados de um arquivo / API
- Peça "analisa meus dados e sugere previsões": o Pepe olha suas tabelas de verdade e sugere o que dá pra prever
- Confirme uma sugestão (ou descreva a sua), Pepe treina
- Pergunte pelo resultado e recebe a resposta na hora, sem gastar chamada de IA nenhuma

📍 *Onde encontrar: direto na conversa com o agente, pedindo pra treinar ou consultar uma previsão*

---

### Pepe.Graph: workflows que se corrigem sozinhos

Você agora pode encadear várias operações com estado compartilhado e **deixar que o agente revise uma etapa sem precisar refazer o workflow inteiro**.

Antes, um workflow tinha dois extremos: uma sequência rígida (um passo sempre leva ao próximo, ponto final) ou um agente soltando várias chamadas a outras ferramentas (mas sem "memória" compartilhada entre elas).

**Graph resolve o meio do caminho:**

- **Nomes e memória:** cada etapa nomeia o resultado, e etapas posteriores podem reutilizar ("use o valor que guardei como resultado_anterior")
- **Revisão em loop:** uma etapa pode revisar o resultado da anterior e mandar corrigir, sem precisar recomeçar do zero
- **Escalação opcional:** se algo fica questionável, o workflow pode pausar e esperar um humano decidir antes de prosseguir
- **Sem nova linguagem:** é tudo JSON, definível à mão, via terminal ou na conversa

**Um exemplo:** seu workflow extrai dados de uma página, outro nó valida se a extração faz sentido, e se não fizer, manda tentar de novo na página anterior. Fim da conversa: tudo resolvido no fluxo.

📍 *Onde encontrar: `mix pepe graph` no terminal, ou a ferramenta `manage_graph`/`run_graph` nas conversas*

---

### run_code: chamar várias ferramentas em um turno só

Seu agente agora pode escrever um script que **chama muitas ferramentas sem mandar reimprimir o histórico inteiro pro modelo a cada uma**.

Antes, qualquer tarefa que precisava de 5 passos (ler arquivo → processar → gravar → buscar URL → comparar) custava 5 rodadas inteiras com o modelo, re-enviando a conversa toda cada vez.

**Agora:** o agente escreve um script em linguagem simples (Lua), o Pepe roda **todas** as ferramentas dele e volta só com o resultado final.

**Quando é útil:**
- Limpeza de dados: ler → separar → gravar → validar
- Relatórios: buscar várias fontes, processar, montar documento
- Auditorias: verificar muitas condições consecutivas

O script roda em um sandbox seguro (sem acesso ao sistema operacional), respeita as mesmas permissões que o agente já tem (se não pode rodar `bash`, o script também não consegue), e um timeout automático evita scripts travados.

📍 *Onde encontrar: a ferramenta `run_code` (argumento `script` ou `code`)*

---

### Permissões pendentes: aprove depois em canais sem humano

Quando o agente roda em um cron ou webhook (sem ninguém vendo em tempo real), às vezes uma ferramenta exige que um humano diga "sim".

Antes, a resposta era não, ponto. Agora, a solicitação **fica armazenada** esperando seu "sim" ou "não" quando você tiver tempo.

```
- Um webhook chega pedindo que o agente gere um relatório (exige permissão)
- Agente não consegue continuar, pede espera
- Você vê a solicitação no terminal: `mix pepe approvals list`
- Você aprova: `mix pepe approvals approve ID`
- O resultado volta na conversa do agente automaticamente
```

Se aprovar com `--always`, o agente para de perguntar por aquela mesma ferramenta, aquele mesmo contexto de risco, naquela mesma conversa.

Se negar, o agente recebe sua mensagem e sabe continuar de outra forma (ou falhar graciosamente).

📍 *Onde encontrar: `mix pepe approvals` no terminal*

---

### Ledger de concessões: sempre permitir, mas auditável e revogável

Aquele botão de "sempre permitir" que você clica no dashboard agora fica anotado e pode ser desfeit em qualquer momento.

Antes, clicar em "sempre" gravava a permissão direto no config, invisível, sem jeito de saber quando foi, por onde veio, ou reverter só aquela uma.

**Agora:**

- Cada concessão é um registro: ferramenta, agente, quando, de onde, quem pediu
- `mix pepe grants list` mostra todas
- `mix pepe grants revoke ID` desfaz aquela específica no mesmo instante
- Auditar quem confiou em que fica trivial

📍 *Onde encontrar: `mix pepe grants` no terminal, ou o dashboard*

---

### Upload e download de arquivos no dashboard

A conversa no dashboard agora pode trocar arquivos nas duas direções, não só texto.

**Upload (você → agente):** clique no ícone de anexo (ou arraste na caixa de mensagem), escolha até 5 arquivos. Imagens em agentes de visão são enviadas como imagens; PDFs e textos são extraídos e lidos normalmente.

**Download (agente → você):** quando o agente precisa entregar um arquivo (relatório, planilha, documento), o Pepe gera um link temporário (válido 24h, seguro contra adivinhação) e você baixa direto.

📍 *Onde encontrar: a conversa do dashboard*

---

### Renomear conversa direto no título

Agora tem um ícone de lápis (✏️) que aparece perto do título da conversa no dashboard, clique pra editar o nome na hora, sem rodar `/name`.

📍 *Onde encontrar: o título da conversa no dashboard, em cima*

---

### Pepe.Insight com colunas de texto e validação cruzada

**Colunas categóricas (texto):** se seus dados têm colunas como "tipo_plano" (valores: "free", "pro", "enterprise"), o Pepe agora treina com elas direto, codifica automaticamente pra você.

**Validação cruzada em lugar de divisão única:** antes, o Pepe treinava em 80% dos dados e testava em 20%, e o número de acurácia dependia de qual divisão saia. Agora, treina em 5 divisões diferentes e média os resultados, muito mais confiável. Também mostra o desvio padrão, pra você saber se o número é estável ou varia bastante.

**Sugestões melhores:** `insight propose_targets` agora sugere não só "classifique essa coluna" ou "preveja esse número", mas também "acompanhe esse número ao longo do tempo" (previsão de tendência) e "encontre grupos naturais nesses dados" (clustering).

📍 *Onde encontrar: direto na conversa com o agente*

---

### Skills em pacote

Um skill agora pode ser mais que um arquivo Markdown: pode ser uma pasta com vários arquivos (scripts, documentos de referência, etc.).

Se um skill tem uma pasta `scripts/`, o agente consegue rodar aquele script sem reescrever do zero, já vem pronto, testado, no jeito que o autor criou.

📍 *Onde encontrar: `mix pepe skill install` (reconhece pacotes automaticamente)*

---

### Dica de capacidade relacionada

Alguns agentes agora mencionam, de forma bem sutil, uma ferramenta relacionada que você talvez goste de usar.

Por exemplo, se ajuda você com uma tarefa única, pode mencionar: "ah, se isso precisar rodar periodicamente, tem a ferramenta de agendamento".

Não é um menu, não aparece sempre, só quando faz sentido. Ativa com `mix pepe agent add --capability-nudge`.

📍 *Onde encontrar: depois de uma resposta bem-sucedida do agente*

---

## 🔧 Melhorias

### O Anthropic agora cacheia seu histórico

Se está usando Claude (via API Anthropic ou assinatura), cada conversa longa reutiliza a parte do histórico que não mudou, economizando tokens.

É automático, sem precisar configurar nada. Só funciona com os modelos Claude; outros provedores continuam como antes.

---

### Ler arquivos grandes agora é prático

Antes, `read_file` podia devolver um arquivo gigante inteiro e o modelo re-enviava tudo de novo em cada turno. Agora:

- Arquivo muito grande? Só a primeira metade é lida, com indicação de quantas linhas tem e como ler o resto
- Você pode pedir "próximas 30 linhas a partir da linha 500": sem re-enviar o que já leu

Tamanho limite é adaptativo: depende do modelo que está usando.

---

### Compactação de contexto começa mais cedo

Quando a conversa fica muito longa, o Pepe resume a parte do meio antes de ficar ruim: agora começa em 60% do limite, em vez de 75%. Deixa mais espaço pra você trabalhar sem susto.

---

### Telegram: responder por texto, não só botão

Num grupo, às vezes é difícil clicar em botão. Agora pode responder "!permitir", "!negar", "!sempre" em texto que funciona igual.

Pedimos `!` (ex: "!sempre", não só "sempre") porque "sempre" é uma palavra comum que sairia acidentalmente.

---

### Melhor rastreamento de execução

Langfuse (se você usa) agora recebe muito mais info: de qual canal veio, quanto cada passo custou, quando terminou. Tudo com timestamps reais, não fictícios.

---

## 🐛 Correções

### Imagem anexada chega de verdade pro modelo

Antes, quando você anexava uma foto no dashboard ou no Telegram, o agente via o texto descritivo, mas nunca a imagem em si (mesmo em modelos de visão que conseguem ver imagens).

**Corrigido:** agora a imagem vai junto e o modelo consegue vê-la de verdade.

---

### Bash roda no lugar certo

Quando o agente rodava um comando de terminal, costumava rodar em um diretório aleatório (dependo de onde você tinha digitado `mix pepe`), não onde os arquivos da conversa estavam.

Agora `bash`, assim como `read_file` e `write_file`, trabalham no mesmo local, sem surpresa.

---

### Hora atual é sempre agora

O agente agora sabe a hora real, não a hora em que a conversa começou (o que antes podia deixar uma conversa de horas dizendo que "são 14h20" a noite inteira).

---

### Grupo no Telegram: nome de quem mandou não muda no histórico

Quando várias pessoas falam num grupo, o nome de cada uma aparecia em cada mensagem dela no histórico, o que confundia o agente. Ele via "Maria: ..." em três mensagens seguidas e achava que era a mesma pessoa.

Agora só a mensagem mais recente carrega o nome; as antigas guardam só o texto, sem reescrever. Conforme a conversa fica longa, isso economiza espaço também.

---

### Primeira ferramenta de um agente novo não trava em loop

Quando criava um agente novo numa conversa, e esse agente tentava usar uma ferramenta que exigia aprovação, podia ficar pedindo aprovação pra sempre sem jeito de responder.

**Corrigido:** agora funciona como qualquer outro agente.

---

### Upgrade não trava em loop de boot

Quando o Pepe recebia uma atualização de código e tentava iniciar, às vezes o novo código tentava usar uma tabela antes da migration que criava aquela tabela, e travava no loop tentando reiniciar, reiniciar, reiniciar.

**Corrigido:** migrations rodam primeiro, código novo roda depois.

---

### Durabilidade de compactação

O resumo de uma conversa longa (técnico: o estado de "micro-compaction") costumava ficar armazenado para sempre, mesmo que ninguém mais usasse aquela conversa.

Agora expira se ficar sem usar por 7 dias.

---

### Permissões no Telegram: text reply funciona direito

Quando você respondia por texto (não botão) a uma pergunta de permissão:

- Antes: sua resposta podia desaparecer sem nenhuma mensagem
- Antes: a mesma resposta de text em um bot podia resolver pergunta de outro bot
- Antes: bot recebia resposta de quem não tinha autorização e silenciava

**Agora:** tudo funciona como devia: resposta confirmada, escopo certo, não-autorizado recebe aviso.

---

### Langfuse recebe timing real

Antes, Langfuse recebia "cada ferramenta demorou 1.8s" (distribuição igualitária da duração total). Agora recebe o timing real de cada uma.

---

### Skill package escolhe o arquivo certo

Um skill em pacote que tinha vários arquivos com o mesmo nome (ex: documentação em raiz) costumava instalar do arquivo errado, aleatoriamente.

**Corrigido:** agora prioriza o arquivo que é de verdade o "coração" do pacote.

---

### Privilégio de agent-admin escalonado

Um agente com permissão de `manage_agent` conseguia criar um segundo agente super-admin numa conversa que já tinha um, ou fazer parecer um projeto vazio que na verdade já tinha agentes.

**Corrigido:** agora só o primeiro agente de verdade é que sai super-admin (e você ainda pode dizer "não, esse não" com `--can-manage none`).

---

### Erros de permissão no Telegram: mais informação

Quando alguém do grupo clicava num botão de permissão e era negado, o Pepe não guardava nada sobre quem tentou.

Agora loga quem foi, qual era o ID deles no Telegram (tem surpresa: pode ser diferente de quem digita texto no mesmo grupo), e qual foi o resultado.

---

### Script em lote não alcançava ferramenta fora do escopo do agente

O `run_code` (o script que chama várias ferramentas de uma vez) podia, em teoria, chamar uma ferramenta que não estava na lista liberada para aquele agente específico, contornando um limite que o operador tinha configurado de propósito.

**Corrigido:** agora o script só alcança exatamente as ferramentas que o agente já tem permissão de usar, igual a uma chamada direta.

---

### Navegador não perde tempo com um link inválido

Antes de abrir o navegador (que demora, é um processo pesado), o Pepe agora confere se o link é válido primeiro. Um link quebrado ou mal formado é recusado na hora, sem esperar o navegador tentar e falhar sozinho.

---

### Variáveis de ambiente secretas não fingem estar vazias

Quando o agente checava se uma credencial (tipo `API_KEY`) estava configurada, se estivesse vazia podia ser por dois motivos:

1. Ninguém nunca configurou
2. Você (operador) deliberadamente escondeu, porque o agente não precisa saber

Antes, o agente achava que era caso 1 em ambos. Agora distingue: se está escondida, sabe que existe mas não consegue ver.

---

*Atualizado em 18/09/2026*
