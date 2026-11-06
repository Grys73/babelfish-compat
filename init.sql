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

-- sp_rename without @objtype. SQL Server then works out what the name is (an object, else table.column,
-- else table.index, else a user-defined type); Babelfish threw "Please provide @objtype" (EF Core's
-- RenameTable, EXEC sp_rename 'dbo.OldView', 'NewView'). The stock procedure gets the inference in front of
-- its own body; rerunnable (marker comment). No dynamic SQL: the name is only looked up (OBJECT_ID,
-- COL_LENGTH, sys.indexes, TYPE_ID), and the stock body checks it again.
do $$
declare d text := pg_get_functiondef('sys.sp_rename'::regproc);
declare n text;
begin
  if d like '%init.sql: infer%' then return; end if;
  n := replace(d, E' SET @objtype = sys.TRIM(@objtype);\n', E' SET @objtype = sys.TRIM(@objtype);
 -- init.sql: infer @objtype like SQL Server
 IF @objtype IS NULL AND @objname IS NOT NULL
  BEGIN
   DECLARE @c_tab sys.nvarchar(776) = CASE WHEN PARSENAME(@objname, 2) IS NOT NULL THEN
     COALESCE(QUOTENAME(PARSENAME(@objname, 4)) + N''.'', N'''') + COALESCE(QUOTENAME(PARSENAME(@objname, 3)) + N''.'', N'''') + QUOTENAME(PARSENAME(@objname, 2)) END;
   IF OBJECT_ID(@objname) IS NOT NULL
     SET @objtype = ''OBJECT'';
   ELSE IF @c_tab IS NOT NULL AND COL_LENGTH(@c_tab, PARSENAME(@objname, 1)) IS NOT NULL
     SET @objtype = ''COLUMN'';
   ELSE IF @c_tab IS NOT NULL AND EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(@c_tab) AND name = PARSENAME(@objname, 1))
     SET @objtype = ''INDEX'';
   ELSE IF TYPE_ID(@objname) IS NOT NULL
     SET @objtype = ''USERDATATYPE'';
   ELSE
     THROW 33557097, N''No item by the given @objname could be found in the current database'', 1;
  END
');
  if n = d then raise exception 'sys.sp_rename: SET @objtype line not found'; end if;
  execute n;
end $$;

-- sp_helptext (needs sp-helptext.patch, which takes it off the "not supported" list). One row per line with
-- its line end (CR LF kept), lines over 255 characters in 255-character pieces, column Text nvarchar(255), as
-- on SQL Server, so a program that concatenates the rows gets the definition back exactly. The text is
-- OBJECT_DEFINITION's: the original T-SQL of views, procedures, functions and triggers. @columnname (computed
-- columns) is not supported.
create or replace function sys.bbf_compat_helptext_lines(def text)
returns table (n bigint, line text)
language plpgsql immutable
set search_path = pg_catalog as $$
begin
  return query
    select row_number() over (order by l.ord, p.i), substr(l.t, p.i * 255 + 1, 255)
    from regexp_matches(def collate "C", E'[^\\n]*\\n|[^\\n]+$', 'g') with ordinality as l0(m, ord)
    cross join lateral (select l0.m[1] as t, l0.ord) l
    cross join lateral generate_series(0, greatest((length(l.t) - 1) / 255, 0)) as p(i);
end $$;
grant execute on function sys.bbf_compat_helptext_lines(text) to public;

create or replace procedure sys.sp_helptext(IN "@objname" sys.nvarchar, IN "@columnname" sys.sysname DEFAULT NULL::sys.varchar)
language pltsql
as '{"version_num": "1", "typmod_array": ["776", "-1"], "original_probin": ""}', $procedure$
BEGIN
 DECLARE @c_id INT = OBJECT_ID(@objname);
 DECLARE @c_def sys.nvarchar(MAX);
 DECLARE @c_msg sys.nvarchar(4000);
 IF @columnname IS NOT NULL
  THROW 33557097, N'sp_helptext @columnname is not supported in Babelfish', 1;
 IF @c_id IS NULL
  BEGIN
   SET @c_msg = N'The object ''' + @objname + N''' does not exist in database ''' + DB_NAME() + N''' or is invalid for this operation.';
   THROW 33557097, @c_msg, 1;
  END
 SET @c_def = OBJECT_DEFINITION(@c_id);
 IF @c_def IS NULL
  BEGIN
   SET @c_msg = N'There is no text for object ''' + @objname + N'''.';
   THROW 33557097, @c_msg, 1;
  END
 SELECT CAST(line AS sys.nvarchar(255)) AS [Text] FROM sys.bbf_compat_helptext_lines(@c_def) ORDER BY n;
END;
$procedure$;
grant execute on procedure sys.sp_helptext(sys.nvarchar, sys.sysname) to public;

-- sp_MSforeachdb: @command1..3, @replacechar, @precommand/@postcommand, for every database the caller may
-- use (HAS_DBACCESS), as on SQL Server. The commands are the caller's own SQL and run with the caller's
-- rights (no SECURITY DEFINER). The name goes in quoted: [?] becomes QUOTENAME(name), a bare ? the name with
-- ' doubled (the usual '?' inside a string literal), so a database name cannot end the bracket or the
-- literal it stands in. INSERT INTO @t EXEC sp_MSforeachdb ... needs insert-exec-batch.patch.
-- Known gap: Babelfish resolves a cross-database [?].sys.x reference only in DML statements, not in an IF
-- condition, so IF EXISTS (SELECT ... FROM [?].sys.tables ...) finds nothing; use
-- IF OBJECT_ID('[?].dbo.t', 'U') IS NOT NULL instead (works on both servers).
create or replace procedure sys.sp_msforeachdb(IN "@command1" sys.nvarchar, IN "@replacechar" sys.nchar DEFAULT '?'::sys.nchar,
  IN "@command2" sys.nvarchar DEFAULT NULL::sys.varchar, IN "@command3" sys.nvarchar DEFAULT NULL::sys.varchar,
  IN "@precommand" sys.nvarchar DEFAULT NULL::sys.varchar, IN "@postcommand" sys.nvarchar DEFAULT NULL::sys.varchar)
language pltsql
as '{"version_num": "1", "typmod_array": ["2000", "1", "2000", "2000", "2000", "2000"], "original_probin": ""}', $procedure$
BEGIN
 DECLARE @c_name sys.sysname;
 DECLARE @c_cmd sys.nvarchar(MAX);
 DECLARE @c_i INT;
 IF @command1 IS NULL
  THROW 33557097, N'Procedure or function ''sp_MSforeachdb'' expects parameter ''@command1'', which was not supplied.', 1;
 IF @precommand IS NOT NULL EXEC (@precommand);
 DECLARE c_dbs CURSOR LOCAL FAST_FORWARD FOR
  SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY database_id;
 OPEN c_dbs;
 FETCH NEXT FROM c_dbs INTO @c_name;
 WHILE @@FETCH_STATUS = 0
  BEGIN
   SET @c_i = 1;
   WHILE @c_i <= 3
    BEGIN
     SET @c_cmd = CASE @c_i WHEN 1 THEN @command1 WHEN 2 THEN @command2 ELSE @command3 END;
     IF @c_cmd IS NOT NULL
      BEGIN
       SET @c_cmd = REPLACE(@c_cmd, N'[' + @replacechar + N']', QUOTENAME(@c_name));
       SET @c_cmd = REPLACE(@c_cmd, @replacechar, REPLACE(@c_name, N'''', N''''''));
       EXEC (@c_cmd);
      END
     SET @c_i = @c_i + 1;
    END
   FETCH NEXT FROM c_dbs INTO @c_name;
  END
 CLOSE c_dbs;
 DEALLOCATE c_dbs;
 IF @postcommand IS NOT NULL EXEC (@postcommand);
END;
$procedure$;
grant execute on procedure sys.sp_msforeachdb(sys.nvarchar, sys.nchar, sys.nvarchar, sys.nvarchar, sys.nvarchar, sys.nvarchar) to public;

-- FILESTREAM columns read as varbinary (with filestream-pathname.patch). Babelfish already accepts
-- varbinary(max) FILESTREAM (escape_hatch_storage_options = 'ignore' keeps a plain varbinary(max) column) and
-- drops ROWGUIDCOL (escape_hatch_rowguidcol_column = 'ignore'). Clients that check for FILESTREAM support
-- before using such a column look in sys.filegroups (a type FD filegroup) and sys.database_files (a type 2
-- file). sys.filegroups lists one after its stock rows; Babelfish's sys.database_files is empty (WHERE false),
-- and lists that one file. The views belong to the extension: replaced in place,
-- same columns and types. Every database then reports FILESTREAM; leave this block out if a client should
-- not use FILESTREAM columns at all.
create or replace view sys.filegroups as
 select name, data_space_id, type collate sys.database_default as type, type_desc, is_default, is_system,
   null::sys.uniqueidentifier as filegroup_guid, 0 as log_filegroup_id, 0::sys.bit as is_read_only,
   0::sys.bit as is_autogrow_all_files
 from sys.data_spaces ds where type = 'FG'::sys.bpchar
 union all
 select 'FILESTREAM'::sys.nvarchar(128), 2, ('FD'::sys.bpchar(2)) collate sys.database_default,
   'FILESTREAM_DATA_FILEGROUP'::sys.nvarchar(60), 0::sys.bit, 0::sys.bit,
   null::sys.uniqueidentifier, 0, 0::sys.bit, 0::sys.bit;
grant select on sys.filegroups to public;

create or replace view sys.database_files as
 select 65537 as file_id, null::sys.uniqueidentifier as file_guid, 2::sys.tinyint as type,
   'FILESTREAM'::sys.varchar::sys.nvarchar(60) as type_desc, 2 as data_space_id,
   'FILESTREAM'::sys.varchar::sys.sysname as name, ''::sys.varchar::sys.nvarchar(260) as physical_name,
   0::sys.tinyint as state, 'ONLINE'::sys.varchar::sys.nvarchar(60) as state_desc,
   0 as size, -1 as max_size, 0 as growth, 0::sys.bit as is_media_read_only, 0::sys.bit as is_read_only,
   0::sys.bit as is_sparse, 0::sys.bit as is_percent_growth, 0::sys.bit as is_name_reserved,
   0::numeric(25,0) as create_lsn, 0::numeric(25,0) as drop_lsn, 0::numeric(25,0) as read_only_lsn,
   0::numeric(25,0) as read_write_lsn, 0::numeric(25,0) as differential_base_lsn,
   null::sys.uniqueidentifier as differential_base_guid, null::sys.datetime as differential_base_time,
   0::numeric(25,0) as redo_start_lsn, null::sys.uniqueidentifier as redo_start_fork_guid,
   0::numeric(25,0) as redo_target_lsn, null::sys.uniqueidentifier as redo_target_fork_guid,
   0::numeric(25,0) as backup_lsn;
grant select on sys.database_files to public;

-- GET_FILESTREAM_TRANSACTION_CONTEXT(): the token for opening a FILESTREAM value as a file (SqlFileStream).
-- There are no such files here, so there is no token: NULL, as SQL Server answers outside a transaction.
create or replace function sys.get_filestream_transaction_context() returns sys.bbf_varbinary
language plpgsql immutable as $$ begin return null; end $$;
grant execute on function sys.get_filestream_transaction_context() to public;

-- INSERT ... EXEC (<expression>) (with insert-exec-expr.patch and insert-exec-batch.patch). Babelfish took only
-- a string literal there; INSERT INTO @t EXEC ('select ... from dbo.' + @tbl) or EXEC (@sql) was a syntax error.
-- The patch turns any other expression into a call of this procedure, whose EXEC (@sql) hands its rows to the
-- INSERT. Caller's rights (no SECURITY DEFINER), as the caller's own EXEC (...) would run.
create or replace procedure sys.bbf_compat_insert_exec(IN "@sql" sys.nvarchar)
language pltsql
as '{"version_num": "1", "typmod_array": ["-1"], "original_probin": ""}', $procedure$
BEGIN
 EXEC (@sql);
END;
$procedure$;
grant execute on procedure sys.bbf_compat_insert_exec(sys.nvarchar) to public;
