defineEnvVar DOCKERFILES_LOCATION \
             "The folder containing the dockerfiles" \
             "/Dockerfiles";
defineEnvVar RSNAPSHOT_CONF \
             "The rsnapshot configuration file" \
             "/etc/rsnapshot.conf";
defineEnvVar BACKUP_HOST \
             "The remote backup host" \
             "eulerjlean.no-ip.com";
defineEnvVar BACKUP_REMOTE_USER \
             "The remote user for sending backup files remotely" \
             "${BACKUP_REMOTE_USER}";
defineEnvVar CUSTOM_BACKUP_SCRIPT_FOLDER \
             "The folder where the backup scripts, if any, are located" \
             "/usr/local/bin";
defineEnvVar CUSTOM_BACKUP_SCRIPT_PREFIX \
             "The prefix for all backup scripts" \
             "backup-";