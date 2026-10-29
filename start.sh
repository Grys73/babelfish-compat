#!/bin/sh
BABELFISH_HOME=/opt/babelfish
BABELFISH_DATA=/var/lib/babelfish/data

cd ${BABELFISH_HOME}/bin

# Set default argument values
USERNAME=babelfish_user
PASSWORD=
DATABASE=babelfish_db
MIGRATION_MODE=single-db
LANGUAGE=us_english

# Populate argument values from command
while getopts u:p:d:m:l: flag; do
	case "${flag}" in
		u) USERNAME=${OPTARG};;
		p) PASSWORD=${OPTARG};;
		d) DATABASE=${OPTARG};;
		m) MIGRATION_MODE=${OPTARG};;
		l) LANGUAGE=${OPTARG};;
	esac
done

# Initialize database cluster if it does not exist
if [ ! -f ${BABELFISH_DATA}/postgresql.conf ]; then
	# no default superuser password (the image listens on all addresses)
	if [ -z "${PASSWORD}" ]; then
		echo "start.sh: -p <password> is required on the first start" >&2
		exit 1
	fi
	./initdb -D ${BABELFISH_DATA}/ -E "UTF8"
	cat <<- EOF >> ${BABELFISH_DATA}/pg_hba.conf
		# Allow all connections
		host	all		all		0.0.0.0/0		md5
		host	all		all		::0/0				md5
	EOF
	cat <<- EOF >> ${BABELFISH_DATA}/postgresql.conf
		#------------------------------------------------------------------------------
		# BABELFISH RELATED OPTIONS
		# These are going to step over previous duplicated variables.
		#------------------------------------------------------------------------------
		listen_addresses = '*'
		allow_system_table_mods = on
		shared_preload_libraries = 'babelfishpg_tds'
		babelfishpg_tds.listen_addresses = '*'  
		babelfishpg_tsql.migration_mode = '${MIGRATION_MODE}'
		# Compatibility: default session language (language-default.patch),
		# REPEATABLE READ mapped to Postgres isolation, unsupported options ignored, not rejected
		babelfishpg_tsql.language = '${LANGUAGE}'
		babelfishpg_tsql.isolation_level_repeatable_read = 'pg_isolation'
		babelfishpg_tsql.escape_hatch_checkpoint = 'ignore'
		babelfishpg_tsql.escape_hatch_constraint_name_for_default = 'ignore'
		babelfishpg_tsql.escape_hatch_database_misc_options = 'ignore'
		babelfishpg_tsql.escape_hatch_for_replication = 'ignore'
		babelfishpg_tsql.escape_hatch_fulltext = 'ignore'
		babelfishpg_tsql.escape_hatch_identity_function = 'ignore'
		babelfishpg_tsql.escape_hatch_ignore_dup_key = 'ignore'
		babelfishpg_tsql.escape_hatch_index_clustering = 'ignore'
		babelfishpg_tsql.escape_hatch_index_columnstore = 'ignore'
		babelfishpg_tsql.escape_hatch_inline_function_option = 'ignore'
		babelfishpg_tsql.escape_hatch_insert_bulk_options = 'ignore'
		babelfishpg_tsql.escape_hatch_join_hints = 'ignore'
		babelfishpg_tsql.escape_hatch_language_non_english = 'ignore'
		babelfishpg_tsql.escape_hatch_nocheck_add_constraint = 'ignore'
		babelfishpg_tsql.escape_hatch_nocheck_existing_constraint = 'ignore'
		babelfishpg_tsql.escape_hatch_query_hints = 'ignore'
		babelfishpg_tsql.escape_hatch_rowguidcol_column = 'ignore'
		babelfishpg_tsql.escape_hatch_rowversion = 'ignore'
		babelfishpg_tsql.escape_hatch_schemabinding_function = 'ignore'
		babelfishpg_tsql.escape_hatch_schemabinding_procedure = 'ignore'
		babelfishpg_tsql.escape_hatch_schemabinding_trigger = 'ignore'
		babelfishpg_tsql.escape_hatch_schemabinding_view = 'ignore'
		babelfishpg_tsql.escape_hatch_session_settings = 'ignore'
		babelfishpg_tsql.escape_hatch_set_transaction_isolation_level = 'ignore'
		babelfishpg_tsql.escape_hatch_showplan_all = 'ignore'
		babelfishpg_tsql.escape_hatch_storage_on_partition = 'ignore'
		babelfishpg_tsql.escape_hatch_storage_options = 'ignore'
		babelfishpg_tsql.escape_hatch_table_hints = 'ignore'
	EOF
	./pg_ctl -D ${BABELFISH_DATA}/ start

	# Passwords as psql variables (:'pw' quotes them), so any character is safe
	./psql -v ON_ERROR_STOP=1 -v pw="${PASSWORD}" -v usr="${USERNAME}" <<- 'EOSQL'
		ALTER USER postgres WITH PASSWORD :'pw';
		CREATE USER :"usr" WITH SUPERUSER CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
	EOSQL

	./psql \
		-c "DROP DATABASE IF EXISTS ${DATABASE};" \
		-c "CREATE DATABASE ${DATABASE} OWNER ${USERNAME};" \
		-c "\c ${DATABASE}" \
		-c "CREATE EXTENSION IF NOT EXISTS \"babelfishpg_tds\" CASCADE;" \
		-c "GRANT ALL ON SCHEMA sys to ${USERNAME};" \
		-c "ALTER USER ${USERNAME} CREATEDB;" \
		-c "ALTER SYSTEM SET babelfishpg_tsql.database_name = '${DATABASE}';" \
		-c "SELECT pg_reload_conf();"

	# After reloading to apply the migration_mode setting in postgresql.conf, initialize a new connection.
	./psql -d ${DATABASE} \
		-c "CALL SYS.INITIALIZE_BABELFISH('${USERNAME}');"

	# Compatibility functions, see init.sql
	./psql -d ${DATABASE} -v ON_ERROR_STOP=1 -f /init.sql

	./pg_ctl -D ${BABELFISH_DATA}/ stop
fi

# Start postgres engine
exec ./postgres -D ${BABELFISH_DATA}/ -i
