#!/bin/bash
# Startup script for this OTRS container. 
#
# The script by default loads a fresh OTRS install ready to be customized through 
# the admin web interface. 
#
# If the environment variable OTRS_INSTALL is set to yes, then the default web 
# installer can be run from localhost/otrs/installer.pl.
#
# If the environment variable OTRS_INSTALL="restore", then the configuration backup 
# files will be loaded from ${OTRS_ROOT}/backups. This means you need to build 
# the image with the backup files (sql and Confg.pm) you want to use, or, mount a 
# host volume to map where you store the backup files to ${OTRS_ROOT}/backups.
#
# To change the default database and admin interface user passwords you can define 
# the following env vars too:
# - OTRS_DB_PASSWORD to set the database password
# - OTRS_ROOT_PASSWORD to set the admin user 'root@localhost' password. 
#

#Default configuration values
DEFAULT_OTRS_ADMIN_EMAIL="admin@example.com"
DEFAULT_OTRS_ORGANIZATION="Example Company"
DEFAULT_OTRS_SYSTEM_ID="98"
DEFAULT_OTRS_AGENT_LOGO_HEIGHT="67"
DEFAULT_OTRS_AGENT_LOGO_RIGHT="38"
DEFAULT_OTRS_AGENT_LOGO_TOP="4"
DEFAULT_OTRS_AGENT_LOGO_WIDTH="270"
DEFAULT_OTRS_CUSTOMER_LOGO_HEIGHT="50"
DEFAULT_OTRS_CUSTOMER_LOGO_RIGHT="25"
DEFAULT_OTRS_CUSTOMER_LOGO_TOP="2"
DEFAULT_OTRS_CUSTOMER_LOGO_WIDTH="135"
OTRS_BACKUP_DIR="/var/otrs/backups"

[ -z "${OTRS_INSTALL}" ] && OTRS_INSTALL="no"

mysqlcmd="mysql -uroot -h $MARIADB_PORT_3306_TCP_ADDR -p$MARIADB_ENV_MYSQL_ROOT_PASSWORD "

function create_db(){
  echo -e "Creating OTRS database..."
  $mysqlcmd -e "CREATE DATABASE IF NOT EXISTS otrs;"
  [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't create OTRS database !!\n" && exit 1
  $mysqlcmd -e " GRANT ALL ON otrs.* to 'otrs'@'%' identified by '$OTRS_DB_PASSWORD'";
  [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't create database user !!\n" && exit 1
}  

function restore_backup(){
  [ -z $1 ] && echo -e "\n\e[1;31mERROR:\e[0m OTRS_BACKUP_DATE not set.\n" && exit 1
  set_variables
  copy_default_config

  #As this is a restore, drop database first.

  $mysqlcmd -e 'use otrs'
  if [ $? -eq 0  ]; then
    if [ "$OTRS_DROP_DATABASE" == "yes" ]; then
      echo -e "\nOTRS_DROP_DATABASE=\e[92m$OTRS_DROP_DATABASE\e[0m, Dropping existing database\n"
      $mysqlcmd -e 'drop database otrs'
    else
      echo -e "\n\e[1;31mERROR:\e[0m Couldn't load OTRS backup, databse already exists !!\n" && exit 1
    fi  
  fi

  create_db
  update_config_password $OTRS_DB_PASSWORD

  #Make a copy of installed skins so they aren't overwritten by the backup.
  tmpdir=`mktemp -d`
  [ ! -z $OTRS_AGENT_SKIN ] && cp -rp ${SKINS_PATH}Agent $tmpdir/
  [ ! -z $OTRS_CUSTOMER_SKIN ] && cp -rp ${SKINS_PATH}Customer $tmpdir/
  #Run restore backup command
  ${OTRS_ROOT}scripts/restore.pl -b $OTRS_BACKUP_DIR/$1 -d ${OTRS_ROOT}
  [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't load OTRS backup !!\n" && exit 1

  backup_version=`tar -xOf $OTRS_BACKUP_DIR/$1/Application.tar.gz ./RELEASE|grep -o 'VERSION = [^,]*' | cut -d '=' -f2 |tr -d '[[:space:]]'`
  OTRS_INSTALLED_VERSION=`echo $OTRS_VERSION|cut -d '-' -f1`
  echo -e "\e[92mOTRS version of backup being restored: \e[1;31m$backup_version\e[1;0m"
  echo -e "\e[92mOTRS version of this container: \e[1;31m$OTRS_INSTALLED_VERSION\e[1;0m"

  check_version $OTRS_INSTALLED_VERSION $backup_version
  if [ $? -eq 0 ]; then
    echo -e "Backup version older than current OTRS version, fixing..."
    #Update version on ${OTRS_ROOT}/RELEASE so it the website shows the correct version.
    sed -i -r "s/(VERSION *= *).*/\1$OTRS_INSTALLED_VERSION/" ${OTRS_ROOT}RELEASE
    echo -e "Done."
  fi

  #Restore configured password overwritten by restore
  update_config_password $OTRS_DB_PASSWORD
  #Copy back skins over restored files
  [ ! -z $OTRS_CUSTOMER_SKIN ] && cp -rfp $tmpdir/* ${SKINS_PATH} && rm -fr $tmpdir

  #Update the skin preferences  in the users from the backup
  set_users_skin
}

# return 0 if program version is equal or greater than check version
check_version()
{
    local version=$1 check=$2
    local winner=$(echo -e "$version\n$check" | sed '/^$/d' | sort -nr | head -1)
    [[ "$winner" = "$version" ]] && return 0
    return 1
}

function random_string(){
  echo `cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1`
}

function update_config_password(){
  #Change database password on configuration file
  sed  -i "s/\($Self->{'DatabasePw'} *= *\).*/\1'$1';/" ${OTRS_ROOT}Kernel/Config.pm
}

function copy_default_config(){
  echo -e "Copying configuration file..."
  cp -f ${OTRS_ROOT}docker/defaults/Config.pm.default ${OTRS_ROOT}Kernel/Config.pm
  [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't load OTRS config file !!\n" && exit 1
}

function set_variables(){
  [ -z "${OTRS_HOSTNAME}" ] && OTRS_HOSTNAME="otrs-`random_string`" && echo "OTRS_ROOT_HOSTNAME not set, setting hostname to '$OTRS_HOSTNAME'"
  [ -z "${OTRS_ADMIN_EMAIL}" ] && echo "OTRS_ADMIN_EMAIL not set, setting admin email to '$DEFAULT_OTRS_ADMIN_EMAIL'" && OTRS_ADMIN_EMAIL=$DEFAULT_OTRS_ADMIN_EMAIL
  [ -z "${OTRS_ORGANIZATION}" ] && echo "OTRS_ORGANIZATION setting organization to '$DEFAULT_OTRS_ORGANIZATION'" && OTRS_ORGANIZATION=$DEFAULT_OTRS_ORGANIZATION
  [ -z "${OTRS_SYSTEM_ID}" ] && echo "OTRS_SYSTEM_ID not set, setting System ID to '$DEFAULT_OTRS_SYSTEM_ID'"  && OTRS_SYSTEM_ID=$DEFAULT_OTRS_SYSTEM_ID
  [ -z "${OTRS_DB_PASSWORD}" ] && OTRS_DB_PASSWORD=`random_string` && echo "OTRS_DB_PASSWORD not set, setting password to '$OTRS_DB_PASSWORD'"
  [ -z "${OTRS_ROOT_PASSWORD}" ] && echo "OTRS_ROOT_PASSWORD not set, setting password to '$DEFAULT_OTRS_PASSWORD'" && OTRS_ROOT_PASSWORD=$DEFAULT_OTRS_PASSWORD

  #Set default skin to use for Agent interface
  [ ! -z "${OTRS_AGENT_SKIN}" ] && echo "Setting Agent Skin to '$OTRS_AGENT_SKIN'"
  if [ ! -z "${OTRS_AGENT_LOGO}" ]; then
    echo "Setting Agent Logo to: '$OTRS_AGENT_LOGO'"
    [ -z "${OTRS_AGENT_LOGO_HEIGHT}" ] && echo "OTRS_AGENT_LOGO_HEIGHT not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_HEIGHT'" && OTRS_AGENT_LOGO_HEIGHT=$DEFAULT_OTRS_AGENT_LOGO_HEIGHT
    [ -z "${OTRS_AGENT_LOGO_RIGHT}" ] && echo "OTRS_AGENT_LOGO_RIGHT not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_RIGHT'" && OTRS_AGENT_LOGO_RIGHT=$DEFAULT_OTRS_AGENT_LOGO_RIGHT
    [ -z "${OTRS_AGENT_LOGO_TOP}" ] && echo "OTRS_AGENT_LOGO_TOP not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_TOP'" && OTRS_AGENT_LOGO_TOP=$DEFAULT_OTRS_AGENT_LOGO_TOP
    [ -z "${OTRS_AGENT_LOGO_WIDTH}" ] && echo "OTRS_AGENT_LOGO_WIDTH not set, setting default value '$DEFAULT_OTRS_AGENT_LOGO_WIDTH'" && OTRS_AGENT_LOGO_WIDTH=$DEFAULT_OTRS_AGENT_LOGO_WIDTH
  fi
  [ ! -z "${OTRS_CUSTOMER_SKIN}" ] && echo "Setting Customer Skin to '$OTRS_CUSTOMER_SKIN'"
  if [ ! -z "${OTRS_CUSTOMER_LOGO}" ]; then 
    echo "Setting Customer Logo to: '$OTRS_CUSTOMER_LOGO'"
    [ -z "${OTRS_CUSTOMER_LOGO_HEIGHT}" ] && echo "OTRS_CUSTOMER_LOGO_HEIGHT not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_HEIGHT'" && OTRS_CUSTOMER_LOGO_HEIGHT=$DEFAULT_OTRS_CUSTOMER_LOGO_HEIGHT
    [ -z "${OTRS_CUSTOMER_LOGO_RIGHT}" ] && echo "OTRS_CUSTOMER_LOGO_RIGHT not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_RIGHT'" && OTRS_CUSTOMER_LOGO_RIGHT=$DEFAULT_OTRS_CUSTOMER_LOGO_RIGHT
    [ -z "${OTRS_CUSTOMER_LOGO_TOP}" ] && echo "OTRS_CUSTOMER_LOGO_TOP not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_TOP'" && OTRS_CUSTOMER_LOGO_TOP=$DEFAULT_OTRS_CUSTOMER_LOGO_TOP
    [ -z "${OTRS_CUSTOMER_LOGO_WIDTH}" ] && echo "OTRS_CUSTOMER_LOGO_WIDTH not set, setting default value '$DEFAULT_OTRS_CUSTOMER_LOGO_WIDTH'" && OTRS_CUSTOMER_LOGO_WIDTH=$DEFAULT_OTRS_CUSTOMER_LOGO_WIDTH
  fi  
}

function load_defaults(){
  set_variables
  copy_default_config
  update_config_password $OTRS_DB_PASSWORD
  
  #Add default config options
  sed -i "/$Self->{'SecureMode'} = 1;/a \
 \$Self->{'FQDN'} = '$OTRS_HOSTNAME';\
\n\$Self->{'AdminEmail'} = '$OTRS_ADMIN_EMAIL';\
\n\$Self->{'Organization'} = '$OTRS_ORGANIZATION';\
\n\$Self->{'CustomerHeadline'} = '$OTRS_ORGANIZATION';\
\n\$Self->{'SystemID'} = '$OTRS_SYSTEM_ID';"\
 ${OTRS_ROOT}Kernel/Config.pm

  #Check if database doesn't exists yet (it could if this is a container redeploy)
  $mysqlcmd -e 'use otrs'
  if [ $? -gt 0 ]; then
    create_db

    #Check that a backup isn't being restored
    if [ "$OTRS_INSTALL" == "no" ]; then
      echo -e "Loading default db schema..."
      $mysqlcmd otrs < ${OTRS_ROOT}scripts/database/otrs-schema.mysql.sql
      [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't load OTRS database schema !!\n" && exit 1
      echo -e "Loading initial db inserts..."
      $mysqlcmd otrs < ${OTRS_ROOT}scripts/database/otrs-initial_insert.mysql.sql
      [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't load OTRS database initial inserts !!\n" && exit 1
    fi
  fi
}

function set_default_language(){
  if [ ! -z $OTRS_LANGUAGE ]; then
    echo -e "Setting default language to: \e[92m'$OTRS_LANGUAGE'\e[0m"
    sed -i "/$Self->{'SecureMode'} = 1;/a \
    \$Self->{'DefaultLanguage'} = '$OTRS_LANGUAGE';"\
    ${OTRS_ROOT}Kernel/Config.pm
 fi
}

function set_ticker_counter() {
  if [ ! -z "${OTRS_TICKET_COUNTER}" ]; then
    echo -e "Setting the start of the ticket counter to: \e[92m'$OTRS_TICKET_COUNTER'\e[0m"
    echo "$OTRS_TICKET_COUNTER" > ${OTRS_ROOT}var/log/TicketCounter.log
  fi
  if [ ! -z $OTRS_NUMBER_GENERATOR ]; then
    echo -e "Setting ticket number generator to: \e[92m'$OTRS_NUMBER_GENERATOR'\e[0m"
    sed -i "/$Self->{'SecureMode'} = 1;/a \$Self->{'Ticket::NumberGenerator'} =  'Kernel::System::Ticket::Number::${OTRS_NUMBER_GENERATOR}';"\
     ${OTRS_ROOT}Kernel/Config.pm
  fi
}

function set_skins() {
  [ ! -z $OTRS_AGENT_SKIN ] &&  sed -i "/$Self->{'SecureMode'} = 1;/a \
\$Self->{'Loader::Agent::DefaultSelectedSkin'} =  '$OTRS_AGENT_SKIN';\
\n\$Self->{'Loader::Customer::SelectedSkin'} =  '$OTRS_CUSTOMER_SKIN';"\
 ${OTRS_ROOT}Kernel/Config.pm
 
  #Set Agent interface logo
  [ ! -z $OTRS_AGENT_LOGO ] && set_agent_logo

  #Set Customer interface logo
  [ ! -z $OTRS_CUSTOMER_LOGO ] && set_customer_logo
}

function set_users_skin(){
  echo -e "Updating default skin for users in backup..."
  $mysqlcmd -e "UPDATE user_preferences SET preferences_value = '$OTRS_AGENT_SKIN' WHERE preferences_key = 'UserSkin'" otrs
  [ $? -gt 0 ] && echo -e "\n\e[1;31mERROR:\e[0m Couldn't change default skin for existing users !!\n" 
}  

function set_agent_logo() {
  set_logo "Agent" $OTRS_AGENT_LOGO_HEIGHT $OTRS_AGENT_LOGO_RIGHT $OTRS_AGENT_LOGO_TOP $OTRS_AGENT_LOGO_WIDTH $OTRS_AGENT_LOGO
}

function set_customer_logo() {
  set_logo "Customer" $OTRS_CUSTOMER_LOGO_HEIGHT $OTRS_CUSTOMER_LOGO_RIGHT $OTRS_CUSTOMER_LOGO_TOP $OTRS_CUSTOMER_LOGO_WIDTH $OTRS_CUSTOMER_LOGO
}

function set_logo () {
  interface=$1
  logo_height=$2
  logo_right=$3
  logo_top=$4
  logo_width=$5
  logo_url=$6
  
  sed -i "/$Self->{'SecureMode'} = 1;/a \
 \$Self->{'${interface}Logo'} =  {\n'StyleHeight' => '${logo_height}px',\
\n'StyleRight' => '${logo_right}px',\
\n'StyleTop' => '${logo_top}px',\
\n'StyleWidth' => '${logo_width}px',\
\n'URL' => '$logo_url'\n};" ${OTRS_ROOT}Kernel/Config.pm
}

# function set_customer_logo() {
#   sed -i "/$Self->{'SecureMode'} = 1;/a\$Self->{'CustomerLogo'} =  {\n'StyleHeight' => '${OTRS_CUSTOMER_LOGO_HEIGHT}px',\n'StyleRight' => '${OTRS_CUSTOMER_LOGO_RIGHT}px',\n'StyleTop' => '${OTRS_CUSTOMER_LOGO_TOP}px',\n'StyleWidth' => '${OTRS_CUSTOMER_LOGO_WIDTH}px',\n'URL' => '$OTRS_CUSTOMER_LOGO'\n};" ${OTRS_ROOT}Kernel/Config.pm
# }

function set_fetch_email_time(){
  if [ ! -z $OTRS_POSTMASTER_FETCH_TIME ]; then
    echo -e "Setting Postmaster fetch emails time to \e[92m$OTRS_POSTMASTER_FETCH_TIME\e[0m minutes"

    if [ $OTRS_POSTMASTER_FETCH_TIME -eq 0 ]; then

      #Disable email fetching
      sed -i -e '/otrs.PostMasterMailbox.pl/ s/^#*/#/' /var/spool/cron/otrs
    else
      #sed -i -e '/otrs.PostMasterMailbox.pl/ s/^#*//' /var/spool/cron/otrs
      ${OTRS_ROOT}scripts/otrs_postmaster_time.sh $OTRS_POSTMASTER_FETCH_TIME
    fi
  fi
}
