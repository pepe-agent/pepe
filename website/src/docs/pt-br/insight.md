---
title: Insight
description: Treine modelos locais de previsão, agrupamento, detecção de anomalia e previsão de tendência a partir dos seus próprios dados, para que uma pergunta repetida seja respondida na hora e de graça, em vez de raciocinada do zero toda vez.
---

A tool `insight` deixa um agente transformar dado já verificado em um modelo pequeno,
treinado e guardado por ele mesmo, para que uma pergunta específica e repetida ("esse
paciente vai piorar", "esse lead vai converter", "quantas internações semana que vem")
seja respondida na hora, sem chamada de modelo nenhuma, assim que houver histórico
suficiente para aprender. O Pepe escolhe o algoritmo sozinho, de acordo com o volume real de
dado disponível; não há nada para configurar ou ajustar.

Isso não é pesquisa de machine learning em aberto. É responder uma pergunta bem definida, a
partir de um dado que você já tem, uma capacidade real e limitada, não descoberta livre.

## Quatro tipos de pergunta

- **Classificação**: prever uma categoria. *Esse paciente vai reinternar em até 30 dias?
  Esse chamado de suporte vai escalar para um gerente? Essa transação é uma fraude?*
- **Regressão**: prever um número. *Quantos dias esse paciente provavelmente vai ficar
  internado? Quanto esse cliente vai gastar mês que vem? Quantas unidades desse produto
  vão vender essa semana?*
- **Previsão de tendência**: prever um número **ao longo do tempo**. *Quantas internações
  semana que vem, baseado na tendência até agora? Como fica a receita do mês que vem?
  Quantos chamados de suporte esperar na segunda de manhã?*
- **Agrupamento**: juntar registros parecidos entre si, sem nenhum alvo definido. *Quais
  perfis de paciente existem nesse dado, e qual paciente não se encaixa em nenhum deles?
  Quais segmentos aparecem num ano inteiro de pedidos? Quais transações destoam de todo o
  resto?*

Nenhum desses tipos é exclusivo de saúde: o mesmo pipeline de classificação serve para um
time de suporte prevendo se um chamado vai escalar, ou para uma clínica prevendo risco de
reinternação. O que muda entre os dois é só a coluna-alvo e as colunas usadas para
prever, não o tipo de modelo.

Em termos de ML: classificação, regressão e previsão de tendência são aprendizado
supervisionado, porque o modelo aprende a partir de exemplos onde a resposta já é
conhecida. Agrupamento é o único tipo não supervisionado aqui: não há resposta conhecida
nem exemplo rotulado, o modelo encontra os grupos sozinho a partir dos dados.

O agrupamento já resolve detecção de anomalia de graça: um registro muito longe do padrão
do grupo dele volta marcado, usando o mesmo modelo que fez o agrupamento. Um paciente cujos
sinais vitais o colocam bem longe do grupo em que ele normalmente estaria é exatamente esse
tipo de anomalia, vale a pena olhar antes que vire uma emergência.

## De onde vem o dado

Duas fontes, escolhidas na hora de definir o que prever:

- **Uma conexão de banco já cadastrada** (as mesmas que `db_query`/`manage_db` já usam,
  Postgres, isolada por tenant via Row-Level Security quando configurado, veja [Banco de
  dados](/pt-br/docs/database/)).
- **Linhas importadas**: entregue as linhas direto com `import_rows`. É o caminho para
  qualquer fonte que o Pepe não tem conector nativo: um agente lê um arquivo, consulta outro
  motor de banco via `bash` (veja [Banco de dados](/pt-br/docs/database/) sobre o RLS, que só vale
  para Postgres), ou puxa de uma API, e entrega as linhas resultantes. As duas fontes
  treinam pelo mesmo pipeline, exatamente igual; o algoritmo nunca sabe de qual delas veio
  o dado.

## Onde fica guardado

As linhas de uma conexão de banco nunca são copiadas pra lugar nenhum: todo treino e toda
contagem de linhas consulta a conexão na hora, do mesmo jeito que o `db_query` já faz. Só
fica salvo o que prever (alvo, colunas usadas, nome da tabela), não o dado em si.

Linhas importadas são diferentes: o `import_rows` guarda elas de verdade, no próprio
armazenamento operacional do Pepe (a mesma SQLite onde já vivem commitments, watches e
traces), com um teto de 50 mil linhas por modelo, descartando as mais antigas quando passa
disso.

O modelo treinado em si é um binário pequeno (poucos kilobytes, não megabytes) guardado
nesse mesmo armazenamento, não importa de qual fonte veio o treino. Perder esse arquivo só
significa que a próxima previsão vai treinar de novo do zero; ele não guarda nada que uma
pessoa leia diretamente.

## Ainda não sabe o que prever?

Peça para "analisar meus dados em busca de insights" e, para uma conexão de banco, o
`insight propose_targets` amostra linhas reais e sugere algo pra cada tipo de pergunta que
o Insight sabe responder, não só classificação ou regressão: uma coluna de baixa
cardinalidade é uma categoria plausível para classificar, uma coluna numérica com variação
real é algo para prever por regressão, um nome tipo `status`/`risk`/`churn` pesa a favor.
Quando uma tabela também tem uma coluna que parece data ou horário, ele junta isso com uma
coluna numérica e sugere uma previsão de tendência ("acompanhar isso ao longo do tempo").
E quando a tabela tem várias colunas numéricas com variação real, ele junta elas numa
sugestão de agrupamento ("agrupar as linhas por essas colunas e ver que grupos e valores
fora do padrão aparecem"), mesmo sem nenhuma coluna-alvo à vista. É uma heurística, não uma
garantia, e não define nada sozinha - é um ponto de partida para confirmar, não uma spec
pronta. Isso serve justamente pra quem não tem a menor ideia de por onde começar: pergunta,
e o Pepe aponta candidatas reais em vez de você ficar olhando pra uma tela em branco.

## Definindo o que prever

Não existe uma sintaxe separada para aprender: descreva o que você quer na conversa, e o
agente preenche a chamada real de `insight define`. Para uma spec de classificação ou
regressão, diga o alvo e quais colunas usar para prever: "prever se um paciente reinterna
em até 30 dias, usando idade, dias internado e internações prévias, a partir da tabela
`altas` em `pacientes_prod`". Uma previsão de tendência aponta uma coluna de tempo em vez
de (ou além de) outras colunas: "prever o total de internações por dia, sobre a coluna
`dia`". Um agrupamento não aponta alvo nenhum, só o que agrupar: "agrupar pacientes por
idade, número de comorbidades e internações prévias".

Depois, `insight import_rows` (para uma spec importada) ou `insight train_now` (para
qualquer uma das duas) assim que houver histórico suficiente, e `insight_predict` para ter
uma resposta, ver o que está definido e o histórico de cada modelo. É uma tool separada de
propósito: `insight` (define/import_rows/train_now/delete) é a que muda alguma coisa;
`insight_predict` (predict/list/describe) só lê. Essa separação deixa um operador liberar
previsão para uma superfície sem humano no loop (um cron, um webhook) sem também dar a ela
poder de redefinir ou retreinar o que está sendo previsto.

## Como o Pepe escolhe o algoritmo

Por padrão, nunca é escolha manual: o modelo é escolhido pelo volume real de dado
verificado que existe, a mesma filosofia de "descobrir sozinho" por trás do [roteamento
por complexidade](/pt-br/docs/routing/):

- **De algumas centenas a poucos milhares de linhas**: regressão simples. Rápida, robusta,
  sem risco de decorar o dado à toa. Uma clínica com algumas centenas de registros de alta já
  sai com um modelo funcionando na hora.
- **De poucos milhares a dezenas de milhares de linhas**: árvores com gradient boosting
  (XGBoost), o padrão mais forte para esse tipo de dado no volume que a maioria dos
  operadores realmente tem.
- **Dezenas de milhares de linhas para cima**: uma rede neural pequena (compilada via EXLA
  quando disponível), reservada para quem tem histórico realmente grande (centenas de
  milhões de eventos de paciente, por exemplo), dado suficiente para essa complexidade
  valer a pena.

Uma exceção: o binário de Windows vem sem essa terceira faixa. A biblioteca que compila
essa parte não publica versão para Windows, e não há o que corrigir do nosso lado. Todo o
resto desta página funciona lá igualzinho; o Pepe simplesmente para nas árvores com
gradient boosting, e pedir "neural" na mão avisa isso com todas as letras, em vez de
quebrar no meio do treino.

Uma previsão de tendência é uma regressão por baixo dos panos, com o horário virando
atributos de tempo decorrido e dia da semana/mês automaticamente, as mesmas três faixas se
aplicam. Um modelo nesse porte nunca treina em cima de todas as linhas de uma tabela
gigante: o treino usa uma amostra aleatória representativa (`TABLESAMPLE` do Postgres, não
"as primeiras N linhas", que puxaria viés para como a tabela está ordenada), limitada a
200 mil linhas, depois de um certo ponto, mais linha não melhora o modelo de forma
relevante.

Um operador que já sabe qual algoritmo quer pode indicar explicitamente com o `family` do
`define` ("linear", "gbm" ou "neural"), em vez de deixar automático - útil se ele já
comparou os próprios dados, ou só prefere o que já conhece. Deixe sem definir a menos que
peçam; automático é o padrão certo para quase todo mundo.

O número de acerto ou erro que o Pepe mostra vem de testar o modelo contra vários pedaços
diferentes do dado, não só um - um número mais estável e mais confiável do que testar contra
um único recorte aleatório daria, e mais próximo do que o modelo realmente vai fazer com dado
que nunca viu. O modelo que efetivamente responde as previsões depois é treinado de novo em
cima de tudo que existe, não só no pedaço usado pra testar.

## Retreino

Defina `retrain_interval_s` numa spec e o Pepe retreina sozinho assim que houver linhas
novas suficientes (`min_new_rows`, padrão 50), um modelo de risco de paciente fica mais
preciso conforme mais altas são registradas, sem ninguém rodar nada manualmente. O
`insight train_now` retreina na hora, independente disso.

Retreinar, em qualquer frequência, não custa nada em uso de modelo: é um temporizador
interno conferindo se já é hora e se chegou linha nova suficiente e, se sim, ajustando o
modelo, computação simples do início ao fim, igual ao próprio `train_now`. Um modelo só
custa alguma coisa em dois momentos separados: uma vez, em conversa, quando alguém descreve
pela primeira vez o que prever, e depois, só se algo for montado pra transformar uma
previsão num resumo escrito pra uma pessoa ler (um aviso programado, por exemplo), a
previsão em si, não importa com que frequência retreina ou é consultada, nunca precisa de
um.

## O que isso não faz

Todo modelo responde uma pergunta só, definida de antemão, a partir de dado estruturado. Um
número entra direto, e uma coluna com um número razoável de valores diferentes (até 20, tipo
um plano ou uma região) já vira algo que o modelo consegue usar sozinho, sem configurar nada.
Uma coluna com muito mais valores distintos do que isso, tipo um ID de cliente, ainda não dá
pra usar assim. Não lê texto livre (um resumo de alta, um PDF de prontuário), esse dado
precisa virar coluna antes do Insight conseguir usar. Não faz série temporal além de
tendência e sazonalidade semanal/anual, e não faz imagem nem áudio. Se a pergunta precisa
de julgamento em vez de um padrão no dado passado, aí é trabalho do próprio agente,
raciocinando turno a turno, não do Insight.
