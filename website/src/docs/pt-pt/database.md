---
title: Base de dados
description: Deixa um agente ler de uma base de dados Postgres externa, com a multi-tenência do próprio cliente aplicada pela base de dados, não pelo modelo.
---

A tool `db_query` deixa um agente correr uma consulta SQL só-de-leitura contra uma base de
dados Postgres externa configurada pelo operador - dados do próprio cliente, não o
armazenamento interno do Pepe. **Só Postgres.** Se essa base de dados tem a própria
multi-tenência (uma coluna ao estilo `company_id` a separar os próprios clientes desse
cliente), o Pepe amarra o valor de tenant de confiança à ligação e nunca deixa o modelo vê-lo
ou defini-lo - o isolamento real é aplicado pelo próprio Postgres, via Row-Level Security,
não por algo que o código do Pepe decida em tempo de execução.

## Porque é que o modelo nunca vê o valor do tenant

Um argumento de tool que o modelo preenche pode sair errado - por engano, ou porque uma
página ou documento que o agente leu lhe disse para usar um valor diferente. Isso não é uma
falha de redação, é uma fuga real de dados entre clientes. Por isso o esquema da tool
`db_query` não tem nenhum parâmetro de tenant/`company_id`: o modelo só fornece `connection`
(um nome) e `query` (SQL só-de-leitura). O valor do tenant vem da configuração que o operador
definiu, resolvido do lado do servidor, e aplicado a cada consulta dessa ligação
automaticamente.

## Configurar Row-Level Security (faz isto primeiro)

Esta é a parte que o Pepe não consegue fazer por ti: a própria base de dados do operador
precisa de um role dedicado e sem privilégios, e de uma política. Corre algo assim uma vez, à
mão, na base de dados alvo:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- as tabelas que o agente deva ler

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Duas coisas importam aqui:

- **`NOBYPASSRLS`, e nunca o dono da tabela.** Superutilizadores e donos de tabela ignoram
  RLS por defeito, mesmo com a política definida. O role com que o Pepe se liga tem de ser um
  role comum, sem privilégios, para a política significar alguma coisa.
- **`current_setting('app.pepe_tenant_id', true)`** - este nome exato de GUC é a convenção
  fixa do Pepe, não é configurável por ligação. O `true` como segundo argumento significa
  "devolve `NULL` se não estiver definido, não dês erro" - e `company_id = NULL` nunca é
  verdadeiro em SQL, por isso uma ligação que de alguma forma corra sem o valor definido fica
  sem acesso a nada, não com acesso a tudo. Falha fechada, por construção.

**Uma tabela sem política de RLS não está protegida por esta funcionalidade de forma
alguma.** O `db_query` corre da mesma forma contra cada tabela de uma ligação; se uma tabela
em concreto está de facto isolada depende inteiramente de se *essa tabela* tem uma política
que funcione. Isto é deliberado, não uma brecha para tapar no Pepe: tentar aplicar
isolamento de tenant a reescrever ou a validar SQL arbitrário escrito pelo agente no código
da aplicação não se consegue tornar fiável (uma cláusula `WITH`, um `JOIN`, um agregado podem
contrabandear uma leitura para lá de uma verificação ao nível do texto). Row-Level Security é
o único mecanismo que de facto se sustenta independentemente de como a consulta está escrita,
porque atua dentro do próprio motor da base de dados, não sobre o texto da consulta.

## Adicionar uma ligação

A página **Bases de dados** do painel lista as ligações, mostra se cada uma tem âmbito de
tenant, e tem um formulário para adicionar ou remover uma - o campo da palavra-passe nunca vem
preenchido nem é reexibido depois de guardado. O mesmo pelo CLI:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc

pepe db list
pepe db remove clientes_prod
```

Uma ligação sem `--tenant-column` (ou com o campo "Coluna de tenant" vazio no painel) não tem
âmbito - está bem para uma base de dados de um só cliente, sem nada para isolar. Uma com
coluna de tenant também precisa de um modo:

- **`fixed`** - o valor é um literal, p. ex. uma ligação por cliente
  (`clientes_prod` acima é sempre `acme-inc`, seja quem for a perguntar).
- **`agent_field`** - o valor é `"project"` ou `"bare"`, resolvido a partir do
  próprio projeto ou nome do *agente que chama* no momento da consulta - útil quando uma só
  instalação do Pepe serve vários clientes, cada um mapeado para o seu próprio agente/projeto.

Um agente também pode gerir ligações a partir de uma conversa com a tool `manage_db` (as
mesmas ações add/list/remove), e consultar com `db_query` assim que tiver as duas tools.
Ambas são tools de risco - não estão no conjunto sempre-seguro, e passam pelo aviso de
permissão habitual como qualquer outra tool que alcança para fora.

## O que o agente vê

Um resultado de `db_query` volta envolto no mesmo marcador de conteúdo não fiável que um
resultado de `fetch_url` carrega - é conteúdo de fora da conversa, tratado da mesma forma. A
tool em si é só para Postgres; não há equivalente para MySQL, SQLite ou qualquer outro motor,
já que Row-Level Security (e a garantia de falha fechada acima) é específica do Postgres.
