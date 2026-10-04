#!/bin/bash

source /source_env.sh

if [[ -n "${DBHOST}" ]]; then
  DB_CONN_ARGS="--protocol=tcp --host=${DBHOST} --port=${DBPORT:-3306}"
else
  DB_CONN_ARGS="--socket=/var/run/mysqld/mysqld.sock"
fi

MAX_AGE=$(redis-cli --raw -h redis-mailcow -a ${REDISPASS} --no-auth-warning GET Q_MAX_AGE)

if [[ -z ${MAX_AGE} ]]; then
  echo "Max age for quarantine items not defined"
  exit 1
fi

NUM_REGEXP='^[0-9]+$'
if ! [[ ${MAX_AGE} =~ ${NUM_REGEXP} ]] ; then
  echo "Max age for quarantine items invalid"
  exit 1
fi

TO_DELETE=$(mariadb --skip-ssl ${DB_CONN_ARGS} -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SELECT COUNT(id) FROM quarantine WHERE created < NOW() - INTERVAL ${MAX_AGE//[!0-9]/} DAY" -BN)
mariadb --skip-ssl ${DB_CONN_ARGS} -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "DELETE FROM quarantine WHERE created < NOW() - INTERVAL ${MAX_AGE//[!0-9]/} DAY"
echo "Deleted ${TO_DELETE} items from quarantine table (max age is ${MAX_AGE//[!0-9]/} days)"
