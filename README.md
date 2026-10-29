# babelfish-compat

A Docker image of [Babelfish for PostgreSQL](https://babelfishpg.org/) 5.6.0, built from source, with a
few small patches and settings that make it behave more like SQL Server for existing applications
(ADO / OLE DB / SqlClient clients, bulk loads, computed columns, multilingual data).

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

`start.sh` flags: `-u` superuser, `-p` password (also set for `postgres`), `-d` the Babelfish
database, `-m` migration mode (`single-db` / `multi-db`), `-l` default session language (default
`us_english`; any SQL Server language name or alias, e.g. `polski` / `Polish`). They only matter on
the first start, when the data volume is empty.

The first start also writes into `postgresql.conf`:

- `babelfishpg_tsql.language`: the default session language (needs `language-default.patch`).
- `babelfishpg_tsql.isolation_level_repeatable_read = 'pg_isolation'`: `SET TRANSACTION ISOLATION
  LEVEL REPEATABLE READ` works instead of failing.
- every `babelfishpg_tsql.escape_hatch_*` = `ignore`: unsupported options (`WITH NOCHECK`,
  `rowversion`, table hints, ...) are ignored instead of failing the statement. These cannot be set
  with `ALTER SYSTEM`.

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

On an existing data volume, run `init.sql` by hand with `psql -d babelfishdb` and set the
language with `ALTER SYSTEM SET babelfishpg_tsql.language = '...'` + `select pg_reload_conf()`.

## Licence

- `Dockerfile`, `start.sh`, `init.sql`: MIT, see `LICENSE` (based on jonathanpotts/docker-babelfishpg,
  MIT).
- `patches/`: each patch is released under the licence of the files it changes: Apache 2.0 for
  `contrib/babelfishpg_*` (`LICENSE-APACHE-2.0`) and the PostgreSQL licence for the PostgreSQL source
  (`LICENSE-POSTGRESQL`).
- Babelfish itself is downloaded from the upstream tags at build time and keeps its own licences.
