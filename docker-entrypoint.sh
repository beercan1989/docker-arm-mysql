#!/bin/bash
set -eo pipefail

## if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

## skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
  case "$arg" in
    -'?'|--help|--print-defaults|-V|--version)
      wantHelp=1
      break
      ;;
  esac
done

## Skip if want help has been flagged
if [ "$1" = 'mysqld' -a -z "${wantHelp}" ]; then

  ## Find the MySQL data directory
  DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

  ## Only run if the MySQL data directory hasn't been populated
  if [ ! -d "${DATA_DIR}/mysql" ]; then

    ## Enforce configuration requirements
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
      echo >&2 'error: database is uninitialized and password option is not specified '
      echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
      exit 1
    fi

    ## Make sure the data directory exists and is owened by MySQL
    mkdir -p "${DATA_DIR}"
    chown -R mysql:mysql "${DATA_DIR}"

    echo 'Initializing database'
    "$@" --initialize-insecure
    echo 'Database initialized'

    ## Start the MySQL daemon
    "$@" --skip-networking &
    pid="$!"

    ## MySQL command
    mysql=( mysql --protocol=socket -uroot -ppassword )

    ## Wait until MySQL has started up
    for i in {30..0}; do
      if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
        break
      fi
      echo 'MySQL init process in progress...'
      sleep 1
    done
    if [ "$i" = 0 ]; then
      echo >&2 'MySQL init process failed.'
      exit 1
    fi

    ## I don't know what this is doing...
    if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
      # sed is for https://bugs.mysql.com/bug.php?id=20545
      mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
    fi

    ## Either generate a random password or set using the provided value
    if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
      MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
      echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi
    "${mysql[@]}" <<-"
      -- What's done in this file shouldn't be replicated
      --  or products like mysql-fabric won't work
      SET @@SESSION.SQL_LOG_BIN=0;

      DELETE FROM mysql.user ;
      CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
      GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
      DROP DATABASE IF EXISTS test ;
      FLUSH PRIVILEGES ;
    "

    ## Update command with root password if set
    if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
      mysql=( mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" )
    fi

    ## Create database if specified
    if [ "$MYSQL_DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
      mysql=( mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" "$MYSQL_DATABASE" )
    fi

    ## Create database user if specified
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

      if [ "$MYSQL_DATABASE" ]; then
        echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
      fi

      echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
    fi

    ## If this is doing what I think, it enables running provision scripts
    echo
    for f in /docker-entrypoint-initdb.d/*; do
      case "$f" in
        *.sh)     echo "$0: running $f"; . "$f" ;;
        *.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
        *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
        *)        echo "$0: ignoring $f" ;;
      esac
      echo
    done

    ## I think its expires the root password or turns it into a one time use paassword.
    if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
      "${mysql[@]}" <<-"
        ALTER USER 'root'@'%' PASSWORD EXPIRE;
      "
    fi

    ## Stop the MySQL daemon we started to do the extra configuration
    if ! kill -s TERM "$pid" || ! wait "$pid"; then
      echo >&2 'MySQL init process failed.'
      exit 1
    fi

    echo
    echo 'MySQL init process done. Ready for start up.'
    echo
  fi

  ## Make sure the mysql user owns the data directory
  chown -R mysql:mysql "${DATA_DIR}"
fi

## Run the passed in command
exec "$@"
