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
		# REPEATABLE READ and SERIALIZABLE mapped to Postgres isolation, unsupported options ignored, not rejected.
		# Postgres SERIALIZABLE does not block like SQL Server's: a conflicting transaction fails with
		# SQLSTATE 40001 (could not serialize access) and has to be retried.
		babelfishpg_tsql.language = '${LANGUAGE}'
		babelfishpg_tsql.isolation_level_repeatable_read = 'pg_isolation'
		babelfishpg_tsql.isolation_level_serializable = 'pg_isolation'
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
	sha256sum /init.sql | cut -d' ' -f1 > ${BABELFISH_DATA}/init.sql.sha256

	./pg_ctl -D ${BABELFISH_DATA}/ stop
fi

# A new image on an existing data volume: the block above does not run, so apply this image's init.sql
# when it differs from the one applied last (hash in the data directory). init.sql is rerunnable; it runs in
# one transaction, so a failure leaves the previous objects as they were and the server still starts.
INIT_WANT=$(sha256sum /init.sql | cut -d' ' -f1)
INIT_HAVE=$(cat ${BABELFISH_DATA}/init.sql.sha256 2>/dev/null)
if [ "${INIT_WANT}" != "${INIT_HAVE}" ]; then
	echo "start.sh: init.sql changed (${INIT_HAVE:-never recorded} -> ${INIT_WANT}), applying it" >&2
	# Postgres TCP closed while init.sql runs (local socket only)
	./pg_ctl -D ${BABELFISH_DATA}/ -w -o "-c listen_addresses=''" start
	INIT_DB=$(./psql -d postgres -At -c "SHOW babelfishpg_tsql.database_name" 2>/dev/null)
	if ./psql -d "${INIT_DB:-${DATABASE}}" -v ON_ERROR_STOP=1 -q --single-transaction -f /init.sql; then
		echo "${INIT_WANT}" > ${BABELFISH_DATA}/init.sql.sha256
		echo "start.sh: init.sql applied to ${INIT_DB:-${DATABASE}}" >&2
	else
		echo "start.sh: WARNING init.sql failed on ${INIT_DB:-${DATABASE}}; nothing changed, retried on the next start" >&2
	fi
	./pg_ctl -D ${BABELFISH_DATA}/ -w stop
fi

# Start postgres engine
# Optional TLS (tds8-strict.patch): mount a server certificate and key at
# /run/secrets/server.crt and /run/secrets/server.key (or set TLS_CERT/TLS_KEY).
# Both ports then accept TLS; TDS clients can use Encrypt=Strict (TDS 8.0).
# TDS_STRICT_ONLY=on closes TDS connections that do not start with TLS.
TLS_CERT=${TLS_CERT:-/run/secrets/server.crt}
TLS_KEY=${TLS_KEY:-/run/secrets/server.key}
set --
if [ -f "${TLS_CERT}" ] && [ -f "${TLS_KEY}" ]; then
	# PostgreSQL refuses a key readable by others; mounted files often are
	install -m 600 "${TLS_CERT}" ${BABELFISH_DATA}/server.crt
	install -m 600 "${TLS_KEY}" ${BABELFISH_DATA}/server.key
	set -- -c ssl=on -c ssl_cert_file=server.crt -c ssl_key_file=server.key
	if [ "${TDS_STRICT_ONLY}" = "on" ]; then
		set -- "$@" -c babelfishpg_tds.tds_ssl_strict_only=on
	fi
fi

exec ./postgres -D ${BABELFISH_DATA}/ -i "$@"
