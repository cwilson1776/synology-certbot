#!/bin/bash -e
# vim: syntax=bash:ts=2:sw=2:sts=2:et
scriptName=${0##*/}
scriptDir=${0%/*}
absScriptDir=$(cd ${scriptDir} && pwd -P)
absScriptName=${absScriptDir}/${scriptName}

export SYNO_DESCRIPTION="internal.example.com";
export DOMAIN="*.internal.example.com";
export EMAIL_ADDRESS="admin@example.com";
export CERTBOT_DIR_PATH="/volume1/docker/certbot/etc-letsencrypt";
export CERTBOT_LIB_PATH="/volume1/docker/certbot/var-lib-letsencrypt";
export LOG_PATH="/volume1/docker/certbot/var-log";
export CHALLENGE_TYPE="CLOUDFLARE"; # or HTTP
export SECRETS_PATH="/volume1/docker/certbot/credentials";
# export WEBROOT_PATH="/tmp/letsencrypt";
export EXP_LIMIT="30";

source "${absScriptDir}/syno-certbot.sh"
