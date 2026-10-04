#!/bin/sh

PHPFPMHOST=${PHPFPMHOST:-"php-fpm-mailcow"}
SOGOHOST=${SOGOHOST:-"$IPV4_NETWORK.248"}
RSPAMDHOST=${RSPAMDHOST:-"rspamd-mailcow"}

wait_host() {
  if printf "%s\n" "${WAIT_TCP}" | grep -E '^([yY][eE][sS]|[yY])+$' >/dev/null; then
    nc -z -w 2 "$1" "$2"
  else
    ping "$1" -c1 > /dev/null
  fi
}

until wait_host ${PHPFPMHOST} 9002; do
  echo "Waiting for PHP..."
  sleep 1
done
if ! printf "%s\n" "${SKIP_SOGO}" | grep -E '^([yY][eE][sS]|[yY])+$' >/dev/null; then
  until wait_host ${SOGOHOST} 20000; do
    echo "Waiting for SOGo..."
    sleep 1
  done
fi
if ! printf "%s\n" "${SKIP_RSPAMD}" | grep -E '^([yY][eE][sS]|[yY])+$' >/dev/null; then
  until wait_host ${RSPAMDHOST} 11334; do
    echo "Waiting for Rspamd..."
    sleep 1
  done
fi

python3 /bootstrap.py

exec "$@"
