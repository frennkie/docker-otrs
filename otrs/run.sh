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

. ./functions.sh

while true; do
  out="`$mysqlcmd -e "SELECT COUNT(*) FROM mysql.user;" 2>&1`"
  echo -e $out
  echo "$out" | grep "COUNT"
  if [ $? -eq 0 ]; then
    echo -e "\n\e[92mServer is up !\e[0m\n"
    break
  fi
  echo -e "\nDB server still isn't up, sleeping a little bit ...\n"
  sleep 2
done

#If OTRS_INSTALL isn't defined load a default install
if [ "$OTRS_INSTALL" != "yes" ]; then
  if [ "$OTRS_INSTALL" == "no" ]; then
    if [ -e "${OTRS_ROOT}var/tmp/firsttime" ]; then
      #Load default install
      echo -e "\n\e[92mStarting a clean\e[0m OTRS $OTRS_VERSION \e[92minstallation ready to be configured !!\n\e[0m"
      load_defaults
      #Set default admin user password
      echo -e "Setting password for default admin account root@localhost..."
      #${OTRS_ROOT}bin/otrs.SetPassword.pl --agent root@localhost $OTRS_ROOT_PASSWORD
      su -c "${OTRS_ROOT}bin/otrs.Console.pl Admin::User::SetPassword root@localhost $OTRS_ROOT_PASSWORD" -s /bin/bash otrs
      su -c "${OTRS_ROOT}bin/otrs.Console.pl Admin::WebService::Add --name GenericTicketConnectorREST --source-path /GenericTicketConnectorREST.yml" -s /bin/bash otrs
    fi
  # If OTRS_INSTALL == restore, load the backup files in ${OTRS_ROOT}/backups
  elif [ "$OTRS_INSTALL" == "restore" ];then
    echo -e "\n\e[92mRestoring \e[0m OTRS \e[92m backup: $OTRS_BACKUP_DATE for host ${OTRS_HOSTNAME}\n\e[0m"
    restore_backup $OTRS_BACKUP_DATE
  fi
  set_skins
  set_ticker_counter
  set_default_language
  rm -fr ${OTRS_ROOT}var/tmp/firsttime
  #Start OTRS
  ${OTRS_ROOT}bin/otrs.SetPermissions.pl --otrs-user=otrs --web-group=apache /opt/otrs
  ${OTRS_ROOT}bin/Cron.sh start otrs
  su -c "${OTRS_ROOT}bin/otrs.Daemon.pl start" -s /bin/bash otrs
  #/usr/bin/perl ${OTRS_ROOT}bin/otrs.Scheduler.pl -w 1
  set_fetch_email_time
  #${OTRS_ROOT}bin/otrs.RebuildConfig.pl
  su -c "${OTRS_ROOT}bin/otrs.Console.pl Maint::Config::Rebuild" -s /bin/bash otrs
  #${OTRS_ROOT}bin/otrs.DeleteCache.pl
  su -c "${OTRS_ROOT}bin/otrs.Console.pl Maint::Cache::Delete" -s /bin/bash otrs
else
  #If neither of previous cases is true the installer will be run.
  echo -e "\n\e[92mStarting \e[0m OTRS $OTRS_VERSION \e[92minstaller !!\n\e[0m"
fi

#Launch supervisord
echo -e "Starting supervisord..."
supervisord&
echo -e "Restarting OTRS daemon..."
su -c "${OTRS_ROOT}bin/otrs.Daemon.pl stop" -s /bin/bash otrs
sleep 2
su -c "${OTRS_ROOT}bin/otrs.Daemon.pl start" -s /bin/bash otrs

while true; do
  sleep 1000
done
