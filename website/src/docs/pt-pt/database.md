---
title: Base de dados
description: Como deixar um agente responder a partir da tua própria base de dados Postgres, só de leitura, com os dados de cada cliente isolados pela própria base de dados, não pelo modelo.
---

A tool `db_query` permite que um agente responda diretamente a partir dos teus próprios
dados: corre consultas SQL só de leitura contra uma base de dados Postgres externa que o
operador configura (os dados de um cliente concreto, não o armazenamento interno do
Pepe). **Só funciona com Postgres.** Se essa base de dados guardar as linhas de vários
clientes nas mesmas tabelas, através de uma coluna ao estilo `company_id` que separa os
clientes de cada um, o Pepe fixa o valor de confiança do tenant na própria ligação e
nunca deixa o modelo vê-lo nem alterá-lo. O isolamento real fica a cargo do próprio
Postgres, através de Row-Level Security, e não de nenhuma decisão tomada em tempo de
execução pelo código do Pepe.

## Porque é que o modelo nunca vê o valor do tenant

Um argumento de tool que o modelo preenche sozinho pode sair errado, seja por engano,
seja porque uma página ou um documento que o agente leu o levou a usar um valor
diferente do esperado. Isso já não é uma simples falha de redação de texto, é uma fuga
real de dados entre clientes: um cliente a ver as linhas de outro. Por essa razão, a
especificação da tool `db_query` não tem nenhum parâmetro de tenant nem de
`company_id`: o modelo só fornece `connection` (um nome) e `query` (SQL só de leitura). O
valor do tenant vem da configuração definida pelo operador, é resolvido do lado do
servidor, e aplica-se automaticamente a todas as consultas feitas nessa ligação.

## Configurar o Row-Level Security primeiro

Esta é a parte que o Pepe não consegue fazer por ti: a própria base de dados do operador
precisa de um role dedicado, sem privilégios, e de uma política associada. Corre algo
assim uma única vez, à mão, na base de dados de destino:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- as tabelas que o agente deve poder ler

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Duas coisas importam particularmente aqui:

- **`NOBYPASSRLS`, nunca o dono da tabela.** Por predefinição, superutilizadores e donos
  de tabela ignoram o RLS mesmo com a política já criada. O role com que o Pepe se liga
  tem de ser um role comum e sem privilégios, ou a política não vale nada.
- **`current_setting('app.pepe_tenant_id', true)`.** Este nome exato é a convenção fixa
  do Pepe, não é algo configurável ligação a ligação. O `true` como segundo argumento diz
  para devolver `NULL` quando o valor não está definido, em vez de dar erro, e como
  `company_id = NULL` nunca é verdadeiro em SQL, uma ligação que por algum motivo corra
  sem esse valor definido fica sem acesso a nada, nunca com acesso a tudo. Falha fechada,
  por construção.

**Uma tabela sem política de RLS não fica protegida por esta funcionalidade, ponto
final.** O `db_query` corre exatamente da mesma forma contra qualquer tabela de uma
ligação; se uma tabela em particular está mesmo isolada depende inteiramente de ela ter
uma política que funcione. Isto é deliberado, não é uma lacuna que o Pepe devesse tapar:
tentar impor isolamento de tenant reescrevendo ou validando SQL arbitrário escrito por um
agente, dentro do código da aplicação, nunca se consegue tornar fiável, porque uma
cláusula `WITH`, um `JOIN` ou um agregado conseguem sempre disfarçar uma leitura e passar
por uma verificação feita ao nível do texto. O Row-Level Security é o único mecanismo que
de facto se sustenta independentemente de como a consulta foi escrita, precisamente
porque atua dentro do próprio motor da base de dados, e não sobre o texto da consulta.

## Adicionar uma ligação

A página **Bases de dados** do painel lista as ligações existentes, mostra se cada
uma tem âmbito de tenant definido, e traz um formulário para adicionar ou remover uma; o
campo da palavra-passe nunca vem preenchido, nem volta a aparecer depois de gravado. O
mesmo pela CLI:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc
```

```bash
pepe db list
pepe db remove clientes_prod
```

Uma ligação sem `--tenant-column` definido (ou com o campo "Coluna de tenant" vazio no
painel) fica sem âmbito nenhum, o que é perfeitamente normal para uma base de dados
que só guarda dados de um único cliente, sem nada para isolar. Já uma ligação com coluna
de tenant precisa também de um modo:

- **`fixed`**: o valor é um literal fixo, por exemplo uma ligação por cliente (a
  `clientes_prod` do exemplo acima é sempre `acme-inc`, seja quem for a perguntar).
- **`agent_field`**: o valor passa a ser `"project"` ou `"bare"`, resolvido a partir do
  próprio projeto ou do handle do *agente que está a chamar*, no momento da consulta.
  Útil quando uma única instalação do Pepe serve vários clientes, cada um mapeado ao seu
  próprio agente ou projeto.

Um agente também consegue gerir ligações pela própria conversa, com a tool `manage_db`
(as mesmas ações de adicionar, listar e remover), e consultar dados com `db_query` assim
que tiver as duas tools disponíveis. Ambas contam como tools de risco: não fazem parte do
conjunto sempre seguro, e por isso passam pelo aviso de permissão normal, como qualquer
outra tool que alcança recursos fora do Pepe.

## O que o agente vê

Um resultado de `db_query` chega envolvido no mesmo marcador de conteúdo não confiável
que já acompanha um resultado de `fetch_url`: é conteúdo vindo de fora da conversa, e é
tratado exatamente da mesma forma. A própria tool só serve para Postgres; não existe
equivalente para MySQL, SQLite ou qualquer outro motor, já que o Row-Level Security (e a
garantia de falha fechada descrita acima) é uma característica específica do Postgres.
