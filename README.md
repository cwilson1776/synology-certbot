# synology-certbot

Script to automate the installation and renewal of certbot certificates.
It uses docker image. Note that `syno-certbot.sh` is intended to be sourced
by the parameters file -- and you actually execute that parameters file,
not `syno-certbot.sh`.  Thus, the help menu displays the paramfile as the
script name; here, that is `launch_template.sh`

## Usage
```
Usage: launch_template.sh [-hnevs] [-m MODE]
Manage a Let's Encrypt certificate for a given domain: create,
renew, and deploy as synology's default certificate.

Options:
  -h         Show this help
  -n         Dry-run; do not actually create/renew the certificate.
             Implies -s, but does communicate with LE and Cloudflare.
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
```

To generate the certificate, first create the necessary docker volume 
directories. See the following variables defined in the launch\_template.sh
example:
   ```
   CERTBOT_DIR_PATH    e.g. "/volume1/docker/certbot/etc-letsencrypt"
   CERTBOT_LIB_PATH    e.g. "/volume1/docker/certbot/var-lib-letsencrypt"
   LOG_PATH            e.g. "/volume1/docker/certbot/var-log"
   # only if using CLOUDFLARE challenge type:
   SECRETS_PATH        e.g. "/volume1/docker/certbot/credentials"
```

Then, run the script (with parameters suitably modified):
```
sudo ./launch_template.sh -v
```

Finally, set up a daily task to verify/renew if necessary. The task should
run as root, and the command for the task should be:
```
/full/path/to/launch_template.sh
```

## Other preparations

I believe the main use for this script is to generate a wildcard certificate
for an internal network; however, it can be used to generate a host-specific
certificate for your synology or even a wildcard certificate for an exposed
domain. These last two cases would be useful if you employ port forwarding,
a reverse-proxy, or even cloudflare tunnels, to enable remote access to your
synology's services.

In my case, I use tailscale mesh VPN, and use my internal LAN's pi-hole for
DNS. This allows access to the internal names, even when remoting thru the
VPN, without exposing any ports to the open internet at all.

### Steps:

* Get a domain name (e.g. example.com)
* Create a cloudflare DNS account (free!)
* Using your registrar's web console, set the DNS servers for your domain
to whatever Cloudflare instructs.
    * Create CNAME records for www.example.com -> example.com, and
internal.example.com -> example.com. You don't need any A or AAAA records.
    * Create an API Token for the example.com zone
* Make sure your internal network's DNS domain is set to internal.example.com
* Install docker on your synology
* Customize the syno-cloudflare launch script
* Create the certbot volume directories (see above)
* Create cloudflare.ini with your Zone API token (see above)
* Run your launch script in dryrun mode: `sudo /path/to/my-domain.sh -d -v`
* If successful, run it for real: `sudo /path/to/my-domain.sh -v`
* Check in synology's Control Panel:Security:Certificate panel. You should
see your new certificate.
* Select it, and choose Settings. Make it the default, and assign it to
the various services.
* In synology's Control Panel:Task Scheduler, create a new task called
'Certificate Update'. It should run every night as root, and the task
command should be `/path/to/my-domain.sh`

### Tailscale setup:

* Create a gmail account specifically for tailscale authentication. The
tailscale free plan only allows a single user, so you will share this
user's email and password with everyone and every device you want to
include in your tailscale mesh VPN.
* Create a tailscale account using that gmail 
* Install tailscale on your DNS server (pi-hole?)
    * Make sure the pi-hole listens on all interfaces
* Install tailscale on a mobile client
* Install tailscale on the synology using the App Center.
    * Make the synology expose your internal network subnet [https://tailscale.com/kb/1019/subnets/]
    * Also make the synology act as an optional exit node. [https://tailscale.com/kb/1103/exit-nodes/]
    * This lets your roaming clients use your home network as their egress for all internet
traffic if they choose.
    * ssh in to your synology, and do `sudo tailscale up --advertise-routes=10.0.0.0/24,10.0.1.0/24 
--advertise-exit-node`
* In the tailscale web console, you may have to approve these settings.
    * Also, disable key expiration for both your DNS server (pi-hole) and the synology.
    * Finally, under DNS, set a global DNS nameserver to the tailscale IP of your DNS server,
and enable 'override local DNS'

## Other resources

[https://github.com/paolopasqua/synology-certbot] upstream for this repo

[https://github.com/TheNytangel/Synology-LetsEncrypt-Remote-Update]

[https://github.com/JessThrysoee/synology-letsencrypt]

[https://eff-certbot.readthedocs.io/en/stable/using.html#managing-certificates]

[https://coderevolve.com/certbot-in-docker/]

[https://medium.com/@saurabh6790/generate-wildcard-ssl-certificate-using-lets-encrypt-certbot-273e432794d7]

[https://github.com/tailscale/tailscale/issues/4674]

[https://community.letsencrypt.org/t/synology-docker-radarr-sabnzbd-plex/145557]

[https://admcpr.com/generate-wildcard-ssl-cert-behind-a-firewall-with-synology-cloudflare-docker/]

[https://mytechiethoughts.com/linux/free-ssl-certificates-using-cloudflare-dns-validation-and-certbot/]

[https://kb.synology.com/en-nz/DSM/help/DSM/AdminCenter/connection_certificate?version=7]

[https://community.letsencrypt.org/t/wild-card-san-certificate-is-available/61982]

[https://www.wundertech.net/how-to-set-up-tailscale-on-a-synology-nas/]

[https://linuxhint.com/run-docker-containers-synology-nas/]

[https://mariushosting.com/category/synology-lets-encrypt/]

[https://login.tailscale.com/admin/machines]


