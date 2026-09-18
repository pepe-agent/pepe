---
title: Insight
description: Treina modelos locais de previsão, agrupamento, deteção de anomalias e previsão de tendências a partir dos teus próprios dados, para que uma pergunta repetida seja respondida na hora e de graça, em vez de ser raciocinada do zero de cada vez.
---

A tool `insight` deixa um agente transformar dados já verificados num modelo pequeno,
treinado e guardado por ele próprio, para que uma pergunta específica e repetida ("este
doente vai piorar", "este lead vai converter", "quantos internamentos para a semana que
vem") seja respondida na hora, sem nenhuma chamada ao modelo, assim que houver histórico
suficiente para aprender. O Pepe escolhe o algoritmo sozinho, de acordo com o volume real
de dados disponível; não há nada para configurar nem afinar.

Isto não é investigação de machine learning em aberto. É responder a uma pergunta bem
definida, a partir de dados que já tens, uma capacidade real e limitada, não descoberta
livre.

## Quatro tipos de pergunta

- **Classificação**: prever uma categoria. *Este doente vai ser readmitido nos próximos
  30 dias? Este pedido de suporte vai ser escalado para um gestor? Esta transação é
  fraudulenta?*
- **Regressão**: prever um número. *Quantos dias este doente provavelmente vai ficar
  internado? Quanto é que este cliente vai gastar no próximo mês? Quantas unidades deste
  produto se vão vender esta semana?*
- **Previsão de tendência**: prever um número **ao longo do tempo**. *Quantos
  internamentos para a semana que vem, com base na tendência até agora? Como fica a
  receita do próximo mês? Quantos pedidos de suporte esperar na segunda de manhã?*
- **Agrupamento**: juntar linhas parecidas entre si, sem qualquer alvo definido. *Que
  perfis de doente existem nestes dados, e qual doente não encaixa em nenhum deles? Que
  segmentos aparecem num ano inteiro de encomendas? Que transações destoam de tudo o
  resto?*

Nenhum destes tipos é exclusivo de saúde: o mesmo processo de classificação serve para
uma equipa de suporte a prever se um pedido vai escalar ou para uma clínica a prever risco
de readmissão. O que muda entre os dois é só a coluna-alvo e as colunas usadas para
prever, não o tipo de modelo.

Em termos de ML: classificação, regressão e previsão de tendência são aprendizagem
supervisionada, porque o modelo aprende a partir de exemplos onde a resposta já é
conhecida. O agrupamento é o único tipo não supervisionado aqui: não há resposta
conhecida nem exemplo rotulado, o modelo encontra os grupos sozinho a partir dos dados.

O agrupamento resolve deteção de anomalias de graça: uma linha muito longe do padrão
habitual do seu grupo volta marcada, usando o mesmo modelo que fez o agrupamento. Um
doente cujos sinais vitais o colocam bem longe do grupo onde normalmente estaria é
exatamente esse tipo de anomalia, vale a pena olhar antes que se torne uma emergência.

## De onde vêm os dados

Duas fontes, escolhidas na altura de definir o que prever:

- **Uma ligação a uma base de dados já configurada** (as mesmas que `db_query`/`manage_db`
  já usam, Postgres, isolada por tenant via Row-Level Security quando configurado, vê
  [Base de dados](/pt-pt/docs/database/)).
- **Linhas importadas**: entrega as linhas diretamente com `import_rows`. É o caminho para
  qualquer fonte para a qual o Pepe não tem conetor nativo: um agente lê um ficheiro,
  consulta outro motor de base de dados via `bash` (vê [Base de dados](/pt-pt/docs/database/)
  sobre o RLS, que só se aplica ao Postgres), ou vai buscar dados a uma API, e entrega as
  linhas resultantes. As duas fontes treinam pelo mesmo processo; o algoritmo nunca sabe de
  qual delas vieram os dados.

## Onde fica guardado

As linhas de uma ligação a uma base de dados nunca são copiadas para lado nenhum: cada
treino e cada contagem de linhas consulta a ligação na hora, tal como o `db_query` já faz.
Só fica guardado o que prever (alvo, colunas usadas, nome da tabela), não o dado em si.

As linhas importadas são diferentes: o `import_rows` guarda-as mesmo, no próprio
armazenamento operacional do Pepe (a mesma SQLite onde já vivem os commitments, os watches
e os traces), com um teto de 50 mil linhas por modelo, descartando as mais antigas assim
que passa disso.

O modelo treinado em si é um binário pequeno (poucos kilobytes, não megabytes) guardado
nesse mesmo armazenamento, seja qual for a fonte que o treinou. Perder esse ficheiro só
significa que a próxima previsão vai treinar de novo do zero; não guarda nada que uma
pessoa leia diretamente.

## Ainda não sabe o que prever?

Peça para "analisar os meus dados em busca de insights" e, para uma ligação de base de
dados, o `insight propose_targets` amostra linhas reais e sugere algo para cada tipo de
pergunta que o Insight sabe responder, não só classificação ou regressão: uma coluna de
baixa cardinalidade é uma categoria plausível para classificar, uma coluna numérica com
variação real é algo para prever por regressão, um nome tipo `status`/`risk`/`churn` pesa
a favor. Quando uma tabela também tem uma coluna que parece data ou hora, junta isso com
uma coluna numérica e sugere uma previsão de tendência ("acompanhar isto ao longo do
tempo"). E quando a tabela tem várias colunas numéricas com variação real, junta-as numa
sugestão de agrupamento ("agrupar as linhas por estas colunas e ver que grupos e valores
fora do padrão aparecem"), mesmo sem nenhuma coluna-alvo à vista. É uma heurística, não
uma garantia, e não define nada sozinha - é um ponto de partida para confirmar, não uma
spec pronta. Isto serve exatamente para quem não faz ideia de por onde começar: pergunte,
e o Pepe aponta candidatas reais em vez de ficar a olhar para uma folha em branco.

## Definir o que prever

Não há nenhuma sintaxe separada para aprender: descreve o que queres na conversa, e o
agente preenche a chamada real de `insight define`. Para uma spec de classificação ou
regressão, diz o alvo e que colunas usar para o prever: "prever se um doente é readmitido
em 30 dias, usando idade, dias internado e internamentos prévios, a partir da tabela
`altas` em `doentes_prod`". Uma previsão de tendência aponta uma coluna de tempo em vez de
(ou além de) outras colunas: "prever o total de internamentos por dia, sobre a coluna
`dia`". Um agrupamento não aponta nenhum alvo, só o que agrupar: "agrupar doentes por
idade, número de comorbilidades e internamentos prévios".

Depois, `insight import_rows` (para uma spec importada) ou `insight train_now` (para
qualquer uma delas) assim que houver histórico suficiente, e `insight_predict` para obter
uma resposta, ver o que está definido e o histórico de cada modelo. É uma ferramenta à
parte de propósito: `insight` (define/import_rows/train_now/delete) é a que muda alguma
coisa; `insight_predict` (predict/list/describe) só lê. Essa separação deixa um operador
autorizar previsões numa superfície sem humano envolvido (um cron, um webhook) sem também
dar a ela poder de redefinir ou retreinar o que está a ser previsto.

## Como o Pepe escolhe o algoritmo

Por omissão, nunca é uma escolha manual: o modelo é escolhido pelo volume real de dados
verificados que existe, a mesma filosofia de "descobrir sozinho" por trás do
[encaminhamento por complexidade](/pt-pt/docs/routing/):

- **De algumas centenas a poucos milhares de linhas**: regressão simples. Rápida, robusta,
  sem risco de decorar os dados à toa. Uma clínica com algumas centenas de registos de alta
  já fica com um modelo a funcionar na hora.
- **De poucos milhares a dezenas de milhares de linhas**: árvores com gradient boosting
  (XGBoost), o padrão mais forte para este tipo de dados na escala que a maioria dos
  operadores realmente tem.
- **Dezenas de milhares de linhas para cima**: uma rede neuronal pequena (compilada via
  EXLA quando disponível), reservada a quem tem um histórico realmente grande (centenas de
  milhões de eventos de doentes, por exemplo), dados suficientes para essa complexidade
  valer a pena.

Uma previsão de tendência é, no fundo, uma regressão, com a data/hora a transformar-se
automaticamente em atributos de tempo decorrido e dia da semana/mês, aplicam-se as mesmas
três faixas. Um modelo desta escala nunca treina em cima de todas as linhas de uma tabela
gigante: o treino usa uma amostra aleatória representativa (`TABLESAMPLE` do Postgres, e
não "as primeiras N linhas", o que enviesaria para a forma como a tabela está ordenada),
limitada a 200 mil linhas, a partir de um certo ponto, mais linhas deixam de melhorar o
modelo de forma relevante.

Um operador que já sabe qual algoritmo quer pode indicá-lo explicitamente com o `family`
do `define` ("linear", "gbm" ou "neural") em vez de o deixar automático - útil se já
comparou os próprios dados, ou simplesmente prefere o que já conhece. Deixe por definir a
menos que peçam; automático é a opção certa para quase todos.

O número de acerto ou erro que o Pepe apresenta vem de testar o modelo contra várias fatias
diferentes dos dados, não só uma - um número mais estável e mais fiável do que testar contra
uma única fatia aleatória daria, e mais próximo daquilo que o modelo vai realmente fazer com
dados que nunca viu. O modelo que responde às previsões a seguir é depois treinado de novo
sobre tudo o que existe, não apenas sobre a fatia usada para o testar.

## Retreino

Define `retrain_interval_s` numa spec e o Pepe retreina sozinho assim que houver linhas
novas suficientes (`min_new_rows`, por defeito 50), um modelo de risco de doente fica mais
preciso à medida que mais altas são registadas, sem ninguém ter de correr nada
manualmente. O `insight train_now` retreina na hora, independentemente disso.

Retreinar, com qualquer frequência, não custa nada em uso de modelo: é um temporizador
interno a verificar se já é altura e se chegaram linhas novas suficientes e, se sim, a
ajustar o modelo, computação simples do início ao fim, tal como o próprio `train_now`. Um
modelo só custa alguma coisa em dois momentos separados: uma vez, em conversa, quando
alguém descreve pela primeira vez o que prever, e depois, só se algo for montado para
transformar uma previsão num resumo escrito para uma pessoa ler (um aviso agendado, por
exemplo), a previsão em si, seja qual for a frequência com que retreina ou é consultada,
nunca precisa de um.

## O que isto não faz

Cada modelo responde a uma única pergunta, definida à partida, a partir de dados
estruturados. Um número entra tal e qual, e uma coluna com um número razoável de valores
diferentes (até 20, por exemplo um plano ou uma região) já fica algo que o modelo consegue
usar sozinho, sem qualquer configuração. Uma coluna com muitos mais valores distintos do que
isso, como um ID de cliente, continua a não poder ser usada desta forma. Não lê texto livre
(um resumo de alta, um PDF de processo clínico), esses dados têm de se tornar colunas antes
de o Insight os conseguir usar. Não faz séries temporais além de tendência e sazonalidade semanal/anual, e não faz
imagem nem áudio. Se a pergunta precisa de juízo em vez de um padrão nos dados passados,
isso é trabalho do próprio agente, a raciocinar turno a turno, não do Insight.
