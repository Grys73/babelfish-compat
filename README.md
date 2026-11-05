# babelfish-compat

A Docker image of [Babelfish for PostgreSQL](https://babelfishpg.org/) 5.6.0, built from source, with a
few small compatibility patches and settings for existing T-SQL applications (ADO / OLE DB /
SqlClient clients, EF Core migrations and MERGE, bulk loads, computed columns, multilingual data).

This is a personal project by Krzysiek Niedziela. It is not part of the Babelfish project, and the
patches have not been submitted upstream.

**AI assistance:** the patches and scripts were written with an AI coding assistant (Claude, by
Anthropic) and tested by me against a real application database (restore comparison with SQL Server,
an end-to-end test suite). Read them before you rely on them.

## Why 5.6.0 from source

Babelfish 5.4.0 (the newest official bundle and the newest community image) has BABEL-6317: in a bulk
load (SqlBulkCopy / TDS BulkLoadBCP) a DONE token split across two TDS packets is misparsed, the
server drops the connection, and the client only sees the error on its next command. Rows disappear
silently. It is fixed upstream in 8e8f182 (tag `BABEL_5_6_0`). There is no release bundle for 5.6.0,
so the Dockerfile assembles one the same way the bundle is made: the `BABEL_5_6_0__PG_17_10` tag of
`postgresql_modified_for_babelfish` plus the `contrib/babelfishpg_*` folders of `babelfish_extensions`
tag `BABEL_5_6_0`.

## Build and run

```
docker build -t babelfish-compat .
docker run -d --name bbf -p 1433:1433 -v bbfdata:/var/lib/babelfish/data babelfish-compat -u sa -p <password> -d babelfishdb -m multi-db
```

`start.sh` flags: `-u` superuser, `-p` password (also set for `postgres`; required on the first start,
there is no default), `-d` the Babelfish
database, `-m` migration mode (`single-db` / `multi-db`), `-l` default session language (default
`us_english`; any SQL Server language name or alias, e.g. `polski` / `Polish`). They only matter on
the first start, when the data volume is empty.

The first start also writes into `postgresql.conf`:

- `babelfishpg_tsql.language`: the default session language (needs `language-default.patch`).
- `babelfishpg_tsql.isolation_level_repeatable_read = 'pg_isolation'`: `SET TRANSACTION ISOLATION
  LEVEL REPEATABLE READ` works instead of failing.
- the `babelfishpg_tsql.escape_hatch_*` settings = `ignore`: unsupported options (`WITH NOCHECK`,
  `rowversion`, table hints, ...) are ignored instead of failing the statement. These cannot be set
  with `ALTER SYSTEM`. The `escape_hatch_login_*` ones stay `strict`, so login options Babelfish
  cannot honour (hashed or old passwords, MUST_CHANGE, UNLOCK) fail instead of being dropped.

and runs `init.sql` once (see below).

The ANTLR / PostgreSQL / extension build steps come from
[jonathanpotts/docker-babelfishpg](https://github.com/jonathanpotts/docker-babelfishpg). Nothing in
the Dockerfile is amd64-specific; `docker buildx build --platform linux/arm64` works (slow under QEMU).

## Patches

Applied with `patch -p1` on top of the tags, in name order; a failing hunk stops the build.

| Patch | Files | What it fixes |
|---|---|---|
| `empty-lob-not-null.patch` | tdsbulkload.c | A bulk load stored an empty `text` / `ntext` / `image` value as NULL. TDS marks NULL for these types with a zero-length text pointer; the code also treated a value of length 0 as NULL. |
| `session-language.patch` | gram-tsql-rule.y, guc.c | `SET LANGUAGE` and the login language always ended on `us_english`. The SQL Server languages (by name or alias) are now kept as the session language, stored by name like SQL Server's `@@language`, so applications that select data by language see it. Dates and messages stay `us_english`. |
| `language-default.patch` | guc.c | A server default language (`babelfishpg_tsql.language` in `postgresql.conf` or `ALTER SYSTEM`) crashed backends on start and on a configuration reload: the assign hook sent the change to the client through the protocol plugin also where there is no request. Now only inside a transaction. A connection without a login language then gets the server default, as on SQL Server. |
| `udt-arg-quote.patch` | hooks.c | Scalar functions with user-defined-type arguments failed to create in databases whose name needs quoting (e.g. starts with a digit): the schema name was put bare into a re-parsed GRANT list. |
| `xml-strip-bom.patch` | PostgreSQL xml.c, tdstypeio.c | SQL Server never stores or returns a byte order mark in an `xml` value; Babelfish kept a leading U+FEFF. SqlClient sends every `xml` parameter and bulk value as UTF-16 with FF FE, so every .NET write stored one, and `XDocument.Parse` then failed on read. Stripped on input and on output (output also covers values stored earlier). |
| `applock-per-database.patch` | applock.c | `sp_getapplock` locks belong to a database on SQL Server, but all Babelfish databases share one Postgres database, so two databases taking the same resource name blocked each other. The resource is now prefixed with the T-SQL database id. `@LockTimeout = 0` returns -1 when the lock is taken, as on SQL Server. |
| `object-id-type.patch` | functions.c | `OBJECT_ID(name, 'U')` and `OBJECT_ID(name, 'V')` ignored the type and returned the id of any relation with that name. `'U'` now finds only tables and `'V'` only views. |
| `odbc-date-literals.patch` | TSqlParser.g4, tsqlIface.cpp, tsqlUnsupportedFeatureHandler.cpp | ODBC escapes `{d 'yyyy-mm-dd'}` and `{ts 'yyyy-mm-dd hh:mi:ss[.fff]'}` are read as `datetime` in the ODBC canonical format (CONVERT style 121) whatever the session language, also in `sp_*` parameters. |
| `select-lock-hints.patch` | tsqlIface.cpp | Lock hints in a SELECT (`HOLDLOCK` / `SERIALIZABLE` / `REPEATABLEREAD`, `UPDLOCK`, `XLOCK` / `TABLOCKX`, `NOWAIT`, `READPAST`) were dropped, so read-then-update code (numbering, upserts) ran without its lock and could produce duplicates. They become row locks (`FOR SHARE` / `FOR NO KEY UPDATE` / `FOR UPDATE OF`, `NOWAIT`, `SKIP LOCKED`), also inside procedures, triggers and functions created after the patch. PostgreSQL has no key-range locks, so rows inserted by other sessions are not blocked. Where Postgres accepts no locking clause (UNION, DISTINCT, GROUP BY, aggregates, window functions, SELECT INTO, FOR XML/JSON, outer joins) the hints stay ignored. |
| `numeric-junk.patch` | PostgreSQL scan.l | Since PostgreSQL 15 a number glued to a word (`WHEN 111THEN`, `1.5AS`) is "trailing junk after numeric literal". SQL Server reads it as the number followed by the word; in T-SQL mode the scanner now does the same. PostgreSQL mode still rejects it. |
| `enr-type-default.patch` | PostgreSQL queryenvironment.c | A table variable with a default or check on a column of a user-defined type (`declare @t table(c MyType not null default '')`) failed with "temporary objects cannot reference permanent non-system objects": the default casts to the type, and only the column itself was allowed to reference a permanent type. References to types and collations now stay with the table variable, like the column's type. |
| `tsql-merge.patch` | kwlist.h, gram-tsql-rule.y, tsqlUnsupportedFeatureHandler.cpp, tsqlIface.cpp, multidb.c, pl_exec.c, pl_exec-2.c, prepare.c, tdsresponse.c; PostgreSQL nodeModifyTable.c, execMain.c, rewriteHandler.c/.h | T-SQL `MERGE` was "not currently supported". It now runs on PostgreSQL 17's MERGE (see "MERGE limits" below). The T-SQL front end adds the optional `INTO`, drops table hints (`WITH (HOLDLOCK)`) and `OPTION (...)`, and turns `OUTPUT` into `RETURNING`: `$action` -> `merge_action()`, `inserted.c` -> the target column, `deleted.c` -> the target column on DELETE rows (NULL on the others), `OUTPUT ... INTO @t / #t / table` -> `WITH m AS (MERGE ... RETURNING ...) INSERT INTO t SELECT * FROM m`. Covers the usual upsert (`MERGE t WITH (HOLDLOCK) USING (SELECT ...) ON ... WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT`) and EF Core's batched insert (`MERGE ... USING (VALUES ...) ON 1=0 WHEN NOT MATCHED THEN INSERT ... OUTPUT INSERTED.[Id], i._Position INTO @inserted0`). Schema-qualified and cross-database targets and sources get the same name mapping as INSERT / UPDATE / DELETE. The MERGE keywords are unreserved, so `merge`, `matched`, `source` and `target` stay usable as names. Targets with T-SQL INSTEAD OF triggers (views and tables) work: matched UPDATE / DELETE rows reach the trigger's `inserted` / `deleted` as in a plain UPDATE / DELETE. TDS reports the row count as SQL Server does. |
| `sp-helptext.patch` | tsqlUnsupportedFeatureHandler.cpp | Takes `sp_helptext` off the "not supported" list; the procedure itself is in `init.sql`. |
| `insert-exec-batch.patch` | pl_exec-2.c, pl_handler.c | `EXEC (@sql)` inside a procedure that runs under `INSERT ... EXECUTE` sent its result set to the client instead of the INSERT, so e.g. `INSERT INTO @t EXEC sp_MSforeachdb ...` stayed empty. The dynamic batch now gets the caller's row type and puts its rows into the caller's result, as on SQL Server. `sp_executesql` inside such a procedure is not changed. |
| `computed-default.patch` | tablecmds.c | A computed column that reads no columns and whose only non-immutable parts are the current date/time functions (`[Created] AS GETDATE()` as EF Core migrations create it; also `GETUTCDATE()`, `SYSDATETIME()`, `SYSUTCDATETIME()`, `SYSDATETIMEOFFSET()`, `CURRENT_TIMESTAMP`) failed with "generation expression is not immutable". **Semantic change:** it becomes a plain column with that expression as its DEFAULT, so the value is the insert time, not "now" on every read, and the column can be written by INSERT / UPDATE (on SQL Server a computed column cannot). Fine for insert timestamps; see "Security notes". Other non-immutable expressions (`RAND()`, `NEWID()`, language-dependent string-to-date casts, `CAST(GETDATE() AS date)`) and expressions that also read columns (`DATEDIFF(day, x, GETDATE())`) still fail as before. `AS GETDATE() PERSISTED` is converted too, where SQL Server refuses it (error 4936). |
| `drop-listed-default.patch` | pl_handler.c | `sys.default_constraints` names a column default `DF_<table>_<oid>` (PostgreSQL defaults are not constraints and have no names). EF Core's DropColumn / AlterColumn reads that name and runs `ALTER TABLE t DROP CONSTRAINT [DF_t_12345]`, which failed. A DROP CONSTRAINT with a name of that form that is not a real constraint, and whose oid is a default of the same table, now drops the column default. Real constraints are dropped as before. |
| `index-rename.patch` | procedures.c | Babelfish stores an index under a name built from the index name and the table name and looks it up that way. After `sp_rename 'Old', 'New'` the indexes kept the old table name, so a following `sp_rename 'New.IX_Old_x', 'IX_New_x', 'INDEX'` or `DROP INDEX ... ON New` (both in EF Core migrations) failed. A table rename now renames its indexes to the new table's names. Indexes of constraints are not named that way and stay. A rename done on the PostgreSQL side (`ALTER TABLE ... RENAME`) does not rename them, so do not mix the two on one table. |

### MERGE limits

- Refused with an error, because PostgreSQL 17 cannot do them: `OUTPUT deleted.*` / `deleted.c` in a MERGE
  that updates (PostgreSQL 17 cannot return the row before an UPDATE), `MERGE TOP (n)`, more than one OUTPUT
  clause, `OUTPUT inserted.*` / `deleted.*` in a MERGE that both inserts and deletes, and `UPDATE SET @var = ...`
  or a method call in the SET list.
- Table hints are dropped. `WITH (HOLDLOCK)` does not serialise on the key range as on SQL Server: PostgreSQL
  locks the target rows MERGE matches but has no key-range locks, so two concurrent upserts of the same new key
  end in a unique-key violation (or a duplicate row, if the key has no unique index) instead of one waiting for
  the other. Keep a unique index on the MERGE key and retry on the error.
- MERGE runs with PostgreSQL 17 semantics. `WHEN NOT MATCHED BY SOURCE` is supported, and a target row matched
  twice is an error, as on SQL Server.

## init.sql

- `sys.babelfish_concat_wrapper*` made `IMMUTABLE`. Babelfish maps computed columns to Postgres
  generated columns, which accept only immutable functions, and T-SQL string `+` goes through these
  STABLE wrappers, so `Name AS ltrim(first) + ' ' + last` was rejected. The result depends only on the
  arguments; NULL semantics are unchanged.
- `sys.binary_checksum(varbinary)`: Babelfish has no `BINARY_CHECKSUM`. This one returns the first 4
  bytes of SHA2_256 as `int` and is immutable, so it can stand in a computed column. **The values
  differ from SQL Server's**; use it for change detection, not to compare with checksums computed on
  SQL Server.
- `sys.langid()` (`@@langid`): the SQL Server langid of the session language, so data keyed by
  `@@langid` keeps working.
- `sp_rename` without `@objtype`: SQL Server's inference (an object, else `table.column`, else
  `table.index`, else a user-defined type, else "No item by the given @objname could be found") is put in
  front of the stock procedure's body; it only looks the name up (no dynamic SQL). EF Core's RenameTable
  and plain `EXEC sp_rename 'dbo.Old', 'New'` need it. Rerunnable.
- `sp_helptext` (with `sp-helptext.patch`): one row per line with its CR LF, lines over 255 characters in
  255-character pieces, column `Text nvarchar(255)`, from `OBJECT_DEFINITION` (views, procedures,
  functions, triggers), so concatenating the rows gives the definition back exactly. `@columnname` is
  refused.
- `sp_MSforeachdb`: `@command1..3`, `@replacechar`, `@precommand` / `@postcommand`, for every database the
  caller can access, with the caller's rights. `[?]` becomes `QUOTENAME(name)`, a bare `?` the name with
  `'` doubled. `INSERT INTO @t EXEC sp_MSforeachdb ...` needs `insert-exec-batch.patch`. Known gap:
  Babelfish resolves a cross-database `[db].sys.x` reference only in DML statements, not in an `IF`
  condition, so `IF EXISTS (SELECT ... FROM [?].sys.tables ...)` finds nothing; `IF OBJECT_ID('[?].dbo.t',
  'U') IS NOT NULL` works on both servers.

None of these is `SECURITY DEFINER`.

On an existing data volume, run `init.sql` by hand with `psql -d babelfishdb` and set the
language with `ALTER SYSTEM SET babelfishpg_tsql.language = '...'` + `select pg_reload_conf()`.

## Security notes

A review of the patches and `init.sql` found no privilege escalation; nothing in `init.sql` runs with
elevated rights. Two low-severity behaviour differences remain, by design:

- **`sp_helptext` shows definitions to anyone with SELECT / EXECUTE on the object.** It uses Babelfish's
  `OBJECT_DEFINITION`, which is gated by the object privilege, not by SQL Server's VIEW DEFINITION, and
  Babelfish does not honour `WITH ENCRYPTION` (it stores the text in clear). `sp_helptext` adds no access:
  `sys.sql_modules` and `OBJECT_DEFINITION()` already return the same text to the same login in stock
  Babelfish. It only answers for the current database. If module source is confidential in your setup, do
  not rely on `WITH ENCRYPTION` on Babelfish.
- **Columns converted by `computed-default.patch` are writable.** On SQL Server `[Created] AS GETDATE()`
  cannot be the target of INSERT or UPDATE, so it is tamper-proof for every login. Here any login with
  INSERT / UPDATE on the table can set it. If you rely on such columns as audit stamps, add a trigger that
  rejects explicit values.

The superuser password has no default (`-p` is required on the first start) and is passed to psql as a
variable, not spliced into SQL.

## Tests

Run on x64 in throwaway containers, against a baseline image built the same way without the six patches
added in this update (`tsql-merge`, `sp-helptext`, `insert-exec-batch`, `computed-default`,
`drop-listed-default`, `index-rename`) and without the new init.sql blocks:

- PostgreSQL `make check`: 227/227 passed; isolation suite: 118/118 passed (both images, including the
  PostgreSQL MERGE tests).
- Babelfish JDBC test suite (3598 test files, multi-db): 144 failing files on the baseline (unsupported
  features such as spatial types and linked servers, environment-dependent output). With the patches, 5
  further files differ, all because of intended behaviour changes:
  - `4936_2`, `Test-Computed-Columns-vu-verify`: a computed column `AS GETDATE()` is now accepted (see
    `computed-default.patch`); the tests expect the old error.
  - `Test-sp_rename-vu-verify`: `sp_rename` without `@objtype` now reports SQL Server's "No item by the given
    @objname could be found" instead of "Please provide @objtype".
  - `db_owner-vu-verify`: index names now follow a renamed table (`index-rename.patch`).
  - `PARTITION-vu-cleanup`: the test renames a table with `sp_rename` and back with a PostgreSQL-side
    `ALTER TABLE ... RENAME`, which does not rename the indexes (see `index-rename.patch`).
- The first run found two regressions, both fixed before publishing: a schema-qualified MERGE target or
  source outside `master` was not mapped to the database's schema, and `computed-default` converted every
  column-free volatile expression (now limited to the current date/time functions).
- Application checks, on the final build: MERGE upserts (with HOLDLOCK, on views with INSTEAD OF triggers,
  cross-database), EF Core batched inserts through MERGE ... OUTPUT INTO, a real application's 80 EF Core
  migrations on an empty database with the stock SQL Server provider (DropColumn, RenameTable / RenameIndex,
  computed GETDATE columns), `sp_helptext`, `sp_MSforeachdb` under INSERT EXEC.

## Licence

- `Dockerfile`, `start.sh`, `init.sql`: MIT, see `LICENSE` (based on jonathanpotts/docker-babelfishpg,
  MIT).
- `patches/`: each patch is released under the licence of the files it changes: Apache 2.0 for
  `contrib/babelfishpg_*` (`LICENSE-APACHE-2.0`) and the PostgreSQL licence for the PostgreSQL source
  (`LICENSE-POSTGRESQL`).
- Babelfish itself is downloaded from the upstream tags at build time and keeps its own licences.
