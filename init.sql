-- Compatibility functions, run once when the cluster is initialised (start.sh).
-- All T-SQL databases live in one Postgres database, so once is enough.

-- Computed columns. Babelfish maps them to Postgres generated columns, which accept only IMMUTABLE
-- functions. T-SQL string concatenation ('+') goes through sys.babelfish_concat_wrapper*, which are STABLE,
-- so a column like  Name AS ltrim(first) + ' ' + ltrim(last)  was rejected ("generation expression is not
-- immutable"). The result depends only on the arguments, so IMMUTABLE is accurate; SQL Server NULL
-- semantics are unchanged.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'sys' and p.proname like 'babelfish\_concat\_wrapper%' and p.provolatile <> 'i'
  loop
    execute 'alter function ' || r.f || ' immutable';
  end loop;
end $$;

-- BINARY_CHECKSUM(varbinary). Babelfish has no BINARY_CHECKSUM. Here: the first 4 bytes of SHA2_256 as int,
-- IMMUTABLE so it may stand in a computed column. The values differ from SQL Server's (its algorithm is not
-- documented); like there, a changed value almost always changes the checksum, so change detection works.
-- plpgsql, not sql: a sql function body is inlined and parsed in the caller's T-SQL dialect, where $1 is a
-- money literal.
create or replace function sys.binary_checksum(data sys.bbf_varbinary) returns int
language plpgsql immutable parallel safe as
$$ begin return cast(sys.substring(sys.hashbytes('SHA2_256'::sys.varchar, data), 1, 4) as int); end $$;
grant execute on function sys.binary_checksum(sys.bbf_varbinary) to public;

-- @@langid. Babelfish has no sys.langid(), and its sys.syslanguages lists locales, not SQL Server languages.
-- The session language is babelfishpg_tsql.language (session-language.patch stores it by name, like SQL
-- Server's @@language); the number is SQL Server's langid, so data keyed by langid keeps working.
create or replace function sys.langid() returns smallint
language sql stable parallel safe as $$
  select coalesce((select l.id from (values
    (0, 'us_english'),
    (1, 'deutsch'),
    (2, 'français'),
    (3, '日本語'),
    (4, 'dansk'),
    (5, 'español'),
    (6, 'italiano'),
    (7, 'nederlands'),
    (8, 'norsk'),
    (9, 'português'),
    (10, 'suomi'),
    (11, 'svenska'),
    (12, 'čeština'),
    (13, 'magyar'),
    (14, 'polski'),
    (15, 'română'),
    (16, 'hrvatski'),
    (17, 'slovenčina'),
    (18, 'slovenski'),
    (19, 'ελληνικά'),
    (20, 'български'),
    (21, 'русский'),
    (22, 'türkçe'),
    (23, 'british'),
    (24, 'eesti'),
    (25, 'latviešu'),
    (26, 'lietuvių'),
    (27, 'português (brasil)'),
    (28, '繁體中文'),
    (29, '한국어'),
    (30, '简体中文'),
    (31, 'arabic'),
    (32, 'ไทย'),
    (33, 'norsk (bokmål)')
  ) as l(id, name) where l.name = lower(current_setting('babelfishpg_tsql.language'))), 0)::smallint
$$;
grant execute on function sys.langid() to public;
