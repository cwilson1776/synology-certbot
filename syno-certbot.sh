#!/bin/false "This script should be sourced in a shell, not executed directly"
# vim: syntax=bash:ts=2:sw=2:sts=2:et
# Derived from: https://github.com/paolopasqua/synology-certbot
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
  exit 1
fi
# This file should be sourced by a parameters file rather than
# executed directly. That parameters file should set a number
# of environment variables, not least of which the following:
#   scriptName=${0##*/}
#   scriptDir=${0%/*}
#   absScriptDir=$(cd ${scriptDir} && pwd -P)
#   absScriptName=${absScriptDir}/${scriptName}
#
# About the domain: 
#   SYNO_DESCRIPTION="internal.example.com";
#   DOMAIN="*.internal.example.com";
#   EMAIL_ADDRESS="admin@example.com";
# About the docker host environment:
#   CERTBOT_DIR_PATH="/volume1/docker/certbot/etc-letsencrypt";
#   CERTBOT_LIB_PATH="/volume1/docker/certbot/var-lib-letsencrypt";
#   LOG_PATH="/volume1/docker/certbot/var-log";
# Certbot authentication mechanism:
#   CHALLENGE_TYPE="CLOUDFLARE";
#       For dns-01 challenges. Uses ACME protocol and the certbot/dns-cloudflare
#       docker image. Requires a 'cloudflare.ini' file in this directory:
#           SECRETS_PATH="/volume1/docker/certbot/credentials";
#       It should define your Cloudflare API Token for the zone:
#       dns_cloudflare_api_token = XXXXXXXXXXX
#   # CHALLENGE_TYPE="HTTP";
#      For http-01 challenges. Uses the certbot/certbot docker image.
#      Requires the following variable definition:
#          WEBROOT_PATH="/tmp/letsencrypt";
#      Will spin up an nginx webserver in the docker image, with port 80
#      tcp/udp exposed on the host, serving from that directory (internal
#      to the docker container; no need to create it on your docker host).
#      Certbot will place the required files there automatically, but your
#      firewall must be configured to forward port 80 to the host on which
#      this script runs. This probably doesn't work very well on synology,
#      since synology has its own nginx server on ports 80/443. But this
#      script could be used in -s mode on another host, and then the
#      certificates installed on the synology manually.
# Other data:
#   EXP_LIMIT="30"; # If cert will expire in less than X days, renew (else
#                     do nothing.

syno_cert_folder="/usr/syno/etc/certificate/_archive"
info_path="${syno_cert_folder}/INFO"

usage() {
cat <<- EOF
	Usage: ${scriptName} [-hnevs] [-m MODE]
	Manage a Let's Encrypt certificate for a given domain: create,
	renew, and deploy as synology's default certificate.

	Options:
	  -h         Show this help
	  -n         Dry-run; uses the LE staging server and communicates with
	             Cloudflare, but does not save the result at all. Rather, it
	             simply verifies the configuration works as expected.
	             Implies -s.
	  -S         staging; uses the LE staging server and communicates with
	             Cloudflare and saves the result into /etc/live/{domain}/.
	             The certificate is not a trusted one, but this process is
	             not subject to rate limits. Implies -s.
	  -e         Echo only. This simply prints the commands that would
	             be executed, and takes no other action.
	  -m MODE    MODE is 'auto', 'create', 'renew', or 'deploy' (default: auto)
		     create: if cert already exists, will forcibly renew even
	                     if not nearing expiration. Deploys to syno (unless -s)
	             renew:  Will renew if nearing expiration; if updated, deploys
	                     to syno (unless -s)
	             auto:   Will create if not exist, renew if nearing expiration,
	                     or do nothing. If updated, deploys to syno (unless -s)
	             deploy: Checks if certificate in /etc/letsencrypt is
	                     newer than syno's, and updates syno if so.
	  -v         Verbose mode
	  -s         Skip deployment (don't install the cert)

	Note that this script must be executed as root.
EOF
  exit $1
}

cmd() {
  if [ -n "${opt_verbose}" -o -n "${opt_echo_only}" ]; then
    echo "${scriptName} CMD: ${@}" >&2
  fi
  if [ -z "${opt_echo_only}" ]; then
    "${@}"
  fi
}

cmd_eval() {
  if [ -n "${opt_verbose}" -o -n "${opt_echo_only}" ]; then
    echo "${scriptName} CMD: ${@/eval/}" >&2
  fi
  if [ -z "${opt_echo_only}" ]; then
    "${@}"
  fi
}

error() {
  echo "${scriptName} ERROR: $@" >&2
}

warning() {
  echo "${scriptName} WARNING: $@" >&2
}

info() {
  echo "${scriptName} INFO: $@" >&2
}


__status_force_renew=
opt_dryrun=
opt_mode=auto
opt_deploy=1
opt_echo_only=
opt_deploy_only=
opt_verbose=
opt_staging=
while getopts ":hnevm:sS" o; do
  case "${o}" in
  h) usage 0 ;;
  n) opt_dryrun=1 ;;
  e) opt_echo_only=1 ;;
  v) opt_verbose=1 ;;
  m) opt_mode=$OPTARG ;;
  s) opt_deploy=0 ;;
  S) opt_staging=1 ;;
  :) error "Must supply an argument to -$OPTARG."
     usage 2 >&2 ;;
  ?) error "Invalid option: -${OPTARG}."
     usage 2 >&2 ;;
  esac
done
shift $((OPTIND-1))

case "${opt_mode}" in
  [Cc][Rr][Ee][Aa][Tt][Ee] ) opt_mode=create ;;
  [Rr][Ee][Nn][Ee][Ww]     ) opt_mode=renew ;;
  [Dd][Ee][Pp][Ll][Oo][Yy] ) opt_mode=deploy ;;
  [Aa][Uu][Tt][Oo]         ) opt_mode=auto;;
  * ) error "Invalid mode '${opt_mode}' specified. Must be create, renew, or deploy"
      usage 2 >&2
esac

if [ "${opt_mode}" == "deploy" -a "${opt_deploy}" -eq 0 ]; then
  error "Mode 'deploy' is incompatible with -s"
  exit 2 >&2
fi

if [ $# -gt 0 ]; then
  error "Too many arguments"
  usage 2 >&2
fi

# only matters if we're actually doing things
if [ $EUID -ne 0 -a -z "${opt_echo_only}" ]; then
   error "This script must be run as root"
   exit 1
fi

if [ -z "$SYNO_DESCRIPTION" ]; then
  error "No description of certificate in Synology settings set, please fill -e 'SYNO_DESCRIPTION=cert_example.com'"
  exit 1
fi

if [ -z "$DOMAIN" ]; then
  error "No domains set, please fill -e 'DOMAINS=example.com'"
  exit 1
fi

# only matters when neither dry-run nor staging; otherwise we use
# --register-unsafely-without-email
if [ -z "$EMAIL_ADDRESS" -a -z "${opt_dryrun}${opt_staging}" ]; then
  error "No email set, please fill -e 'EMAIL_ADDRESS=your@email.tld'"
  exit 1
fi

if [ -z "$CERTBOT_DIR_PATH" ]; then
  error "No certbot dir path set, please fill -e 'CERTBOT_DIR_PATH=/etc/letsencrypt'"
  exit 1
fi
if [ -z "$CERTBOT_LIB_PATH" ]; then
  error "No certbot lib path set, please fill -e 'CERTBOT_LIB_PATH=/var/lib/letsencrypt'"
  exit 1
fi

if [ -z $LOG_PATH ]; then
  error "No log path set, please fill -e 'LOG_PATH=/var/log'"
  exit 1
fi

if [ -z "$CHALLENGE_TYPE" ]; then
  error "No domain ownership challenge set, please fille -e 'CHALLENGE_TYPE=HTTP' or -e 'CHALLENGE_TYPE=CLOUDFLARE'"
  exit 1
fi

if [ "${CHALLENGE_TYPE}" = "HTTP" ]
then
  if [ -z "$WEBROOT_PATH" ]; then
    error "No webroot path set, please fill -e 'WEBROOT_PATH=/tmp/letsencrypt'"
    exit 1
  fi
else
  if [ -z "$SECRETS_PATH" ]; then
    error "No secrets path set, please fill -e 'SECRETS_PATH=/.secrets'"
    exit 1
  fi
fi

if [ -z "$EXP_LIMIT" ]; then
  info "No expiration limit set, using default: 30"
  EXP_LIMIT=30
fi

exp_limit="${EXP_LIMIT:-30}"

first_char=$(echo "${DOMAIN}" | cut -c-1)
if [ "${first_char}" = "*" ]; then
  clear_domain=$(echo "$DOMAIN" | cut -c3-)
else
  clear_domain="$DOMAIN"
fi
gen_cert_dir="$CERTBOT_DIR_PATH/live/$clear_domain";

reload_synoservices() {
  info "Reloading service configurations"
  cmd /usr/syno/bin/synosystemctl restart nginx;
}

# Requires $cert_dir
fix_permissions() {
  info "Fixing permissions"
  cmd chown -R ${CHOWN:-root:root} ${cert_dir}
  cmd find ${cert_dir} -type d -exec chmod 755 {} \;
  cmd find ${cert_dir} -type f -exec chmod ${CHMOD:-644} {} \;
}

# Requires $cert_dir, $gen_cert_dir
copy_certificate() {
  info "Installing certificate"

  #check if exist and delete
  if [ $(ls $cert_dir 2>/dev/null | grep -c -e ".pem") -gt 0 ]; then
    if [ ! -d "$cert_dir.bak" ]; then
      cmd mkdir "$cert_dir.bak"
    fi
    cmd cp -r $cert_dir/*.pem "$cert_dir.bak"
  fi

  cmd cp "$gen_cert_dir/fullchain.pem" "$cert_dir/fullchain.pem"
  cmd cp "$gen_cert_dir/chain.pem" "$cert_dir/chain.pem"
  cmd cp "$gen_cert_dir/cert.pem" "$cert_dir/cert.pem"
  cmd cp "$gen_cert_dir/privkey.pem" "$cert_dir/privkey.pem"
}

# If opt_deploy, then requires $cert_dir, $clear_domain, $gen_cert_dir
gen_cert() {
  local force_renew=
  if [ -n "${__status_force_renew}" ]; then
    # Note: add --break-my-certs if using staging, but current cert is real
    #       add --cert-name ${SYNO_DESCRIPTION} if changing key-type
    force_renew="--force-renewal"
  fi
  if [ ${CHALLENGE_TYPE} = "HTTP" ]; then
    do_cert_http --renew-by-default ${force_renew}
  else
    do_cert_cloudflare --renew-by-default ${force_renew}
  fi
  if [ "${opt_deploy}" -gt 0 -a -z "${opt_dryrun}${opt_staging}" ]; then
    copy_certificate
    fix_permissions
    reload_synoservices
  fi
}

# If opt_deploy, then requires $cert_dir, $clear_domain, $gen_cert_dir
renew_cert() {
  if [ ${CHALLENGE_TYPE} = "HTTP" ]; then
    do_cert_http --keep-until-expiring
  else
    do_cert_cloudflare --keep-until-expiring
  fi
  if [ "${opt_deploy}" -gt 0 -a -z "${opt_dryrun}${opt_staging}" ]; then
    copy_certificate
    fix_permissions
    reload_synoservices
  fi
}

do_cert_http() {
  # args expected...pass on to certbot
  local cmdvar="--email ${EMAIL_ADDRESS} --no-eff-email "
  if [ -n "${opt_dryrun}" ]; then
    cmdvar="--dry-run --register-unsafely-without-email"
  elif [ -n "${opt_staging}" ]; then
    cmdvar="--staging --register-unsafely-without-email"
  fi
  cmd docker run --rm --name temp_certbot \
    -v "${CERTBOT_DIR_PATH}:/etc/letsencrypt" \
    -v "${CERTBOT_LIB_PATH}:/var/lib/letsencrypt" \
    -v "${WEBROOT_PATH}:/tmp/letsencrypt" \
    -v "${LOG_PATH}:/var/log" \
    certbot/certbot:latest  \
    certonly \
    --non-interactive \
    --agree-tos --text \
    "${@}" \
    --server https://acme-v02.api.letsencrypt.org/directory \
    --key-type rsa \
    ${cmdvar} \
    --webroot \
    --preferred-challenges http-01 \
    -w /tmp/letsencrypt \
    -d ${DOMAIN}
}

do_cert_cloudflare() {
  # args expected...pass on to certbot
  local cmdvar="--email ${EMAIL_ADDRESS} --no-eff-email "
  if [ -n "${opt_dryrun}" ]; then
    cmdvar="--dry-run --register-unsafely-without-email"
  elif [ -n "${opt_staging}" ]; then
    cmdvar="--staging --register-unsafely-without-email"
  fi

  cmd docker run --rm --name temp_certbot \
    -v "${CERTBOT_DIR_PATH}:/etc/letsencrypt" \
    -v "${CERTBOT_LIB_PATH}:/var/lib/letsencrypt" \
    -v "${LOG_PATH}:/var/log" \
    -v "${SECRETS_PATH}:/.secrets" \
    certbot/dns-cloudflare:latest  \
    certonly \
    --non-interactive \
    --agree-tos --text \
    "${@}" \
    --server https://acme-v02.api.letsencrypt.org/directory \
    --key-type rsa \
    ${cmdvar} \
    --dns-cloudflare \
    --dns-cloudflare-credentials /.secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 60 \
    -d ${DOMAIN}
}

install_new_cert() {
  if [ ! -w "${info_path}" ]; then
    error "Can't write to '${info_path}', required to install new certificates"
	exit 1
  fi
  cmd cp $info_path "$info_path.bak"

  cmd_eval eval "jq --arg desc \"${SYNO_DESCRIPTION}\" --arg id \"${syno_cert_id}\" \
    '. + {(\$id): {desc: \$desc, services: [], user_deletable: true}}' \"$info_path.bak\" \
    > \"$info_path\""
  cmd mkdir -p "$syno_cert_folder/$syno_cert_id"
}

get_syno_cert_id() {
  if [ ! -r "${info_path}" ]; then
    error "Can't read data from '${info_path}'"
	exit 1
  fi
  local id=$(jq -r ". | to_entries[] | select(.value.desc == \"${SYNO_DESCRIPTION}\") | .key" $info_path)
  if [ -z "$id" ]; then
    id=$(openssl rand -hex 3)

    while [ x$(jq --arg k "$id" '.[$k] != null' $info_path) == "xtrue" ]
    do
      id=$(openssl rand -hex 3)
    done

    info "Could not find id for certificate description ${SYNO_DESCRIPTION}. Generate new certificate id ${id}"
  else
    info "Found id ${id} for certificate description"
  fi

  # if we call this method, then we need the id
  if [ -z "$id" ]; then
    error "No id"
    exit 1
  fi

  echo "$id"
}

# Requires $cert_dir, $gen_cert_dir
deploy_mode() {
  local syn_cert_file="$cert_dir/fullchain.pem";
  local le_cert_file="$gen_cert_dir/fullchain.pem";
  if [ ! -e ${le_cert_file} ]; then
    error "No certificate file in '${gen_cert_dir}' to deploy"
    exit 1
  fi

  if [ ! -e ${syn_cert_file} ]; then
    info "Certificate file not found for domain $clear_domain. Installing new certificate."
    install_new_cert
    copy_certificate
    fix_permissions
    reload_synoservices
  else
    if [ ${le_cert_file} -nt "${syn_cert_file}" ]; then
      info "Generated certificate file in '${gen_cert_dir}' is newer. Updating '${cert_dir}'"
      copy_certificate
      fix_permissions
      reload_synoservices
    else
      info "Certificate file in '${cert_dir}' is up to date."
    fi
  fi
}

syno_cert_id=$(get_syno_cert_id)
cert_dir="${syno_cert_folder}/${syno_cert_id}"
info "Folder of certificate: ${cert_dir}"

if [ "${opt_mode}" == "deploy" ]; then
  deploy_mode
  exit 0
fi


cert_check() {
  local cert_file="$cert_dir/fullchain.pem";

  info "START check";
  info "file: $cert_file";

  if [ -e "$cert_file" ]; then
    info "Checking expiration date for $clear_domain..."
    local exp=$(date -d "`openssl x509 -in $cert_file -text -noout|grep "Not After"|cut -c 25-`" +%s)
    info "Expiration date for ${clear_domain}: $(date --iso-8601=seconds --date=@$exp)"
    local datenow=$(date -d "now" +%s)
    local days_exp=$[ ( $exp - $datenow ) / 86400 ]
  else
    info "Certificate file not found for domain $clear_domain. Installing new certificate."
    install_new_cert
    days_exp=-1
  fi

  if [ "$days_exp" -gt "$exp_limit" ] ; then
    info "The certificate is up to date, no need for renewal ($days_exp days left)."
    if [ "${opt_mode}" == "create" ]; then
      info "But mode is 'create' so we will forcibly renew"
      __status_force_renew=1
      gen_cert
    fi
  else
    if [ "$days_exp" -ge 0 ] ; then
      info "The certificate for $clear_domain expires in $days_exp days. Starting renewal script..."
      renew_cert
    else
      info "There's no certificate for $clear_domain (or it has already expired). Starting generate script..."
      # uses --renew-by-default, so if the cert exists but is expired, then
      # it will be renewed; otherwise a new cert will be created.
      gen_cert
    fi
    info "Process finished for domain $clear_domain"
  fi
}

info "--- start. $(date --iso-8601=seconds)"
cert_check
