#!/bin/bash
###############################################################################
# reddit dev environment installer
# --------------------------------
# This script installs a reddit stack suitable for development. DO NOT run this
# on a system that you use for other purposes as it might delete important
# files, truncate your databases, and otherwise do mean things to you.
#
# By default, this script will install the reddit code in the current user's
# home directory and all of its dependencies (including libraries and database
# servers) at the system level. The installed reddit will expect to be visited
# on the domain "reddit.local" unless specified otherwise.  Configuring name
# resolution for the domain is expected to be done outside the installed
# environment (e.g. in your host machine's /etc/hosts file) and is not
# something this script handles.
#
# Several configuration options (listed in the "Configuration" section below)
# are overridable with environment variables. e.g.
#
#    sudo REDDIT_DOMAIN=example.com ./install/reddit.sh
#
###############################################################################

# load configuration
RUNDIR=$(dirname $0)
source $RUNDIR/install.cfg


###############################################################################
# Sanity Checks
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run with root privileges."
    exit 1
fi

if [[ -z "$REDDIT_USER" ]]; then
    # in a production install, you'd want the code to be owned by root and run
    # by a less privileged user. this script is intended to build a development
    # install, so we expect the owner to run the app and not be root.
    cat <<END
ERROR: You have not specified a user. This usually means you're running this
script directly as root. It is not recommended to run reddit as the root user.

Please create a user to run reddit and set the REDDIT_USER variable
appropriately.
END
    exit 1
fi

if [[ "amd64" != $(dpkg --print-architecture) ]]; then
    cat <<END
ERROR: This host is running the $(dpkg --print-architecture) architecture!

Because of the pre-built dependencies in our PPA, and some extra picky things
like ID generation in liveupdate, installing reddit is only supported on amd64
architectures.
END
    exit 1
fi

if [[ -z "$INSTALL_PROFILE" ]]; then
    cat <<END
ERROR: You have not specified an installation profile.
END
    exit 1
fi

# seriously! these checks are here for a reason. the packages from the
# reddit ppa aren't built for anything but trusty (14.04) right now, so
# if you try and use this install script on another release you're gonna
# have a bad time.
source /etc/lsb-release
if [ "$DISTRIB_ID" != "Ubuntu" -o "$DISTRIB_RELEASE" != "14.04" ]; then
    echo "ERROR: Only Ubuntu 14.04 is supported."
    exit 1
fi

if [[ "2000000" -gt $(awk '/MemTotal/{print $2}' /proc/meminfo) ]]; then
    LOW_MEM_PROMPT="reddit requires at least 2GB of memory to work properly, continue anyway? [y/n] "
    read -er -n1 -p "$LOW_MEM_PROMPT" response
    if [[ "$response" != "y" ]]; then
      echo "Quitting."
      exit 1
    fi
fi

REDDIT_AVAILABLE_PLUGINS=""
for plugin in $REDDIT_PLUGINS; do
    if [ -d $REDDIT_SRC/$plugin ]; then
        if [[ -z "$REDDIT_PLUGINS" ]]; then
            REDDIT_AVAILABLE_PLUGINS+="$plugin"
        else
            REDDIT_AVAILABLE_PLUGINS+=" $plugin"
        fi
        echo "plugin $plugin found"
    else
        echo "plugin $plugin not found"
    fi
done

###############################################################################
# Install prerequisites
###############################################################################

# run an aptitude update to make sure python-software-properties
# dependencies are found
if [ "$INSTALL_PROFILE" = "all" ]; then
    apt-get update
    apt-get -y upgrade
fi

# upgrade ubuntu 14 python
$RUNDIR/upgrade_python.sh

# install primary packages
$RUNDIR/install_apt.sh

# install npm packages
$RUNDIR/install_npm.sh

if [ "$INSTALL_PROFILE" = "all" ]; then
    # install cassandra from datastax
    $RUNDIR/install_cassandra.sh

    # install zookeeper
    $RUNDIR/install_zookeeper.sh
fi

# install services (rabbitmq, postgres, memcached, etc.)
$RUNDIR/install_services.sh

# TODO: workaround consumer being broken, cron needs to purge a queue, see issues/44
wget https://raw.githubusercontent.com/rabbitmq/rabbitmq-management/v3.7.8/bin/rabbitmqadmin -O $REDDIT_HOME/rabbitmqadmin
chown $REDDIT_USER:$REDDIT_GROUP $REDDIT_HOME/rabbitmqadmin
chmod +x $REDDIT_HOME/rabbitmqadmin

###############################################################################
# Install the reddit source repositories
###############################################################################
if [ ! -d $REDDIT_SRC ]; then
    mkdir -p $REDDIT_SRC
    chown $REDDIT_USER $REDDIT_SRC
fi

function copy_upstart {
    if [ -d ${1}/upstart ]; then
        cp ${1}/upstart/* /etc/init/
    fi
}

function clone_reddit_repo {
    local destination=$REDDIT_SRC/${1}
    local repository_url=https://github.com/${2}.git

    if [ ! -d $destination ]; then
        sudo -u $REDDIT_USER -H git clone $repository_url $destination
    fi

    copy_upstart $destination
}

function clone_reddit_service_repo {
    clone_reddit_repo $1 reddit-archive/reddit-service-$1
}

clone_reddit_repo reddit adhesivecheese/OS-reddit
clone_reddit_repo i18n reddit/reddit-i18n
clone_reddit_service_repo websockets
clone_reddit_service_repo activity

###############################################################################
# Configure Services
###############################################################################
if [ "$INSTALL_PROFILE" = "all" ]; then
    $RUNDIR/setup_cassandra.sh
    $RUNDIR/setup_postgres.sh
    $RUNDIR/setup_mcrouter.sh
    $RUNDIR/setup_rabbitmq.sh
fi

###############################################################################
# Install and configure the reddit code
###############################################################################
function install_reddit_repo {
    pushd $REDDIT_SRC/$1
    sudo -u $REDDIT_USER python setup.py build
    python setup.py develop
    popd
}

install_reddit_repo reddit/r2
install_reddit_repo i18n
for plugin in $REDDIT_AVAILABLE_PLUGINS; do
    copy_upstart $REDDIT_SRC/$plugin
    install_reddit_repo $plugin
done
install_reddit_repo websockets
install_reddit_repo activity

# generate binary translation files from source
sudo -u $REDDIT_USER make -C $REDDIT_SRC/i18n clean all

# this builds static files and should be run *after* languages are installed
# so that the proper language-specific static files can be generated and after
# plugins are installed so all the static files are available.
pushd $REDDIT_SRC/reddit/r2
sudo -u $REDDIT_USER make clean pyx

plugin_str=$(echo -n "$REDDIT_AVAILABLE_PLUGINS" | tr " " ,)
if [ ! -f development.update ]; then
    cat > development.update <<DEVELOPMENT
# after editing this file, run "make ini" to
# generate a new development.ini
[secrets]
# the tokens in this section are base64 encoded
# SECRET = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# FEEDSECRET = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# ADMINSECRET = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# websocket = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# media_embed = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# action_name = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# email_notifications = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# cache_poisoning = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# adserver_click_url_secret = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# modmail_email_secret = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5
# request_signature_secret = YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5

[DEFAULT]
# global debug flag -- displays pylons stacktrace rather than 500 page on error when true
# WARNING: a pylons stacktrace allows remote code execution. Make sure this is false
# if your server is publicly accessible.
debug = true
uncompressedJS = true
sqlprinting = false
profile_directory =
disable_geoip_service = true

db_user = reddit
db_pass = password
system_user = reddit
admin_message_acct = reddit
# the default subreddit for submissions and wiki. created by inject_test_data.py
default_sr = frontpage
automoderator_account = automoderator

brander_site = [DEV] reddit open source
short_description = open source is awesome

disable_ads = true
disable_captcha = true
disable_ratelimit = true
disable_require_admin_otp = true

domain = $REDDIT_DOMAIN
oauth_domain = $REDDIT_DOMAIN
https_endpoint = https://%(domain)s
share_reply = noreply@$REDDIT_DOMAIN
feedback_email = noreply@$REDDIT_DOMAIN
notification_email = noreply@$REDDIT_DOMAIN
ads_email = noreply@$REDDIT_DOMAIN
login_cookie = redditopensource_session
admin_cookie = redditopensource_admin
otp_cookie = redditopensource_otp

plugins = $plugin_str

media_provider = filesystem
media_fs_root = /srv/www/media
media_fs_base_url_http = https://%(domain)s/media/

min_membership_create_community = 0

# small site tuning
solr_min_batch = 20

# docker compatibility
amqp_host = localhost:5672
cassandra_seeds = 127.0.0.1:9160
hardcache_memcaches = 127.0.0.1:11211
lockcaches = 127.0.0.1:11211
main_db = reddit, 127.0.0.1, *, *, *, *, *
mcrouter_addr = 127.0.0.1:5050
permacache_memcaches = 127.0.0.1:11211
solr_search_host = 127.0.0.1
solr_doc_host = 127.0.0.1
solr_subreddit_search_host = 127.0.0.1
solr_subreddit_doc_host = 127.0.0.1
zookeeper_connection_string = localhost:2181

[server:main]
port = 8001
# production gunicorn_paster settings, enable in supervisord.conf or /etc/init/reddit-paster.conf
# set workers (and haproxy's maxconn) to num CPU cores or less for max single server performance
# workers = 2
# max_requests = 500
# timeout = 10

[live_config]
# Specify global admins and permissions, each user should have one of admin, sponsor, or employee as their permission level
employees = reddit:admin
feature_force_https = on

create_sr_account_age_days = 0
create_sr_link_karma = 0
create_sr_comment_karma = 0
create_sr_ratelimit_once_per_days = 0
DEVELOPMENT
    chown $REDDIT_USER development.update
else
    sed -i "s/^plugins = .*$/plugins = $plugin_str/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^domain = .*$/domain = $REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^oauth_domain = .*$/oauth_domain = $REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^share_reply = .*$/share_reply = noreply@$REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^feedback_email = .*$/feedback_email = noreply@$REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^notification_email = .*$/notification_email = noreply@$REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^ads_email = .*$/ads_email = noreply@$REDDIT_DOMAIN/" $REDDIT_SRC/reddit/r2/development.update
fi

if [ "$INSTALL_PROFILE" = "docker" ]; then
    sed -i "s/^amqp_host = .*$/amqp_host = rabbitmq:5672/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^cassandra_seeds = .*$/cassandra_seeds = cassandra:9160/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^hardcache_memcaches = .*$/hardcache_memcaches = memcached:11211/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^lockcaches = .*$/lockcaches = memcached:11211/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^main_db = .*$/main_db = reddit, postgres, *, *, *, *, */" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^mcrouter_addr = .*$/mcrouter_addr = mcrouter:5050/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^permacache_memcaches = .*$/permacache_memcaches = memcached:11211/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^zookeeper_connection_string = .*$/zookeeper_connection_string = zookeeper:2181/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^solr_search_host = .*$/solr_search_host = solr/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^solr_doc_host = .*$/solr_doc_host = solr/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^solr_subreddit_search_host = .*$/solr_subreddit_search_host = solr/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^solr_subreddit_doc_host = .*$/solr_subreddit_doc_host = solr/" $REDDIT_SRC/reddit/r2/development.update

    # docker version uses production settings by default, like supervisord.conf
    sed -i "s/^debug = .*$/debug = false/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^uncompressedJS = .*$/uncompressedJS = false/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^# workers = .*$/workers = 2/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^# max_requests = .*$/max_requests = 500/" $REDDIT_SRC/reddit/r2/development.update
    sed -i "s/^# timeout = .*$/timeout = 10/" $REDDIT_SRC/reddit/r2/development.update
fi

sudo -u $REDDIT_USER make ini

# generate CSS if uncompressedJS = false
sudo -u $REDDIT_USER make

if [ ! -L run.ini ]; then
    sudo -u $REDDIT_USER ln -nsf development.ini run.ini
fi

popd

###############################################################################
# some useful helper scripts
###############################################################################
function helper-script() {
    cat > $1
    chmod 755 $1
}

helper-script /usr/local/bin/reddit-run <<REDDITRUN
#!/bin/bash
exec paster --plugin=r2 run $REDDIT_SRC/reddit/r2/run.ini "\$@"
REDDITRUN

helper-script /usr/local/bin/reddit-shell <<REDDITSHELL
#!/bin/bash
exec paster --plugin=r2 shell $REDDIT_SRC/reddit/r2/run.ini
REDDITSHELL

helper-script /usr/local/bin/reddit-start <<REDDITSTART
#!/bin/bash
initctl emit reddit-start
REDDITSTART

helper-script /usr/local/bin/reddit-stop <<REDDITSTOP
#!/bin/bash
initctl emit reddit-stop
REDDITSTOP

helper-script /usr/local/bin/reddit-restart <<REDDITRESTART
#!/bin/bash
initctl emit reddit-restart TARGET=${1:-all}
REDDITRESTART

helper-script /usr/local/bin/reddit-flush <<REDDITFLUSH
#!/bin/bash
echo flush_all | nc localhost 11211
REDDITFLUSH

helper-script /usr/local/bin/reddit-serve <<REDDITSERVE
#!/bin/bash
exec paster serve --reload $REDDIT_SRC/reddit/r2/run.ini
REDDITSERVE

###############################################################################
# pixel and click server
###############################################################################
mkdir -p /var/opt/reddit/
chown $REDDIT_USER:$REDDIT_GROUP /var/opt/reddit/

mkdir -p /srv/www/pixel
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/pixel
cp $REDDIT_SRC/reddit/r2/r2/public/static/pixel.png /srv/www/pixel

if [ ! -f /etc/gunicorn.d/click.conf ]; then
    cat > /etc/gunicorn.d/click.conf <<CLICK
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_SRC/reddit/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=unix:/var/opt/reddit/click.sock",
        "--workers=1",
        "tracker:application",
    ),
}
CLICK
fi

service gunicorn start

###############################################################################
# nginx
###############################################################################

mkdir -p /srv/www/media
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/media

cat > /etc/nginx/conf.d/reddit.conf <<NGINX
log_format directlog '\$remote_addr - \$remote_user [\$time_local] '
                      '"\$request_method \$request_uri \$server_protocol" \$status \$body_bytes_sent '
                      '"\$http_referer" "\$http_user_agent"';
NGINX

cat > /etc/nginx/sites-available/reddit-media <<MEDIA
server {
    listen 9000;

    expires max;

    location /media/ {
        alias /srv/www/media/;
    }
}
MEDIA

cat > /etc/nginx/sites-available/reddit-pixel <<PIXEL
upstream click_server {
  server unix:/var/opt/reddit/click.sock fail_timeout=0;
}

server {
  listen 8082;
  access_log      /var/log/nginx/traffic/traffic.log directlog;

  location / {

    rewrite ^/pixel/of_ /pixel.png;

    add_header Last-Modified "";
    add_header Pragma "no-cache";

    expires -1;
    root /srv/www/pixel/;
  }

  location /click {
    proxy_pass http://click_server;
  }
}
PIXEL

if [ "$INSTALL_PROFILE" = "all" ]; then
    cat > /etc/nginx/sites-available/reddit-ssl <<SSL
  map \$http_upgrade \$connection_upgrade {
default upgrade;
  ''      close;
}

server {
    listen 443;

    ssl on;
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    ssl_dhparam /etc/nginx/dhparam.pem;

    # Support TLSv1 for Android 4.3 (Samsung Galaxy S3) https://www.ssllabs.com/ssltest/viewClient.html?name=Android&version=4.3&key=61
    # ciphers from https://cipherli.st legacy / old list
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:ECDHE-RSA-AES128-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA128:DHE-RSA-AES128-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES128-GCM-SHA128:ECDHE-RSA-AES128-SHA384:ECDHE-RSA-AES128-SHA128:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA128:DHE-RSA-AES128-SHA128:DHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA384:AES128-GCM-SHA128:AES128-SHA128:AES128-SHA128:AES128-SHA:AES128-SHA:DES-CBC3-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4";
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:1m;
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
    # reddit code manages these headers
    # add_header X-Frame-Options DENY;
    # add_header X-Content-Type-Options nosniff;
    # add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        # if CloudFlare instead set
        # proxy_set_header X-Forwarded-For \$http_cf_connecting_ip;
        proxy_pass_header Server;

        # allow websockets through if desired
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
SSL

    # SSL upgrades
    if [ ! -f /etc/nginx/dhparam.pem ]; then
        openssl dhparam -out /etc/nginx/dhparam.pem 2048
    fi
fi

# remove the default nginx site that may conflict with haproxy
rm -rf /etc/nginx/sites-enabled/default
# put our config in place
ln -nsf /etc/nginx/sites-available/reddit-media /etc/nginx/sites-enabled/
ln -nsf /etc/nginx/sites-available/reddit-pixel /etc/nginx/sites-enabled/

if [ "$INSTALL_PROFILE" = "all" ]; then
    ln -nsf /etc/nginx/sites-available/reddit-ssl /etc/nginx/sites-enabled/
fi

# make the pixel log directory
mkdir -p /var/log/nginx/traffic

# link the ini file for the Flask click tracker
ln -nsf $REDDIT_SRC/reddit/r2/development.ini $REDDIT_SRC/reddit/scripts/production.ini

service nginx restart

###############################################################################
# haproxy
###############################################################################
if [ "$INSTALL_PROFILE" = "all" ]; then
    if [ -e /etc/haproxy/haproxy.cfg ]; then
        BACKUP_HAPROXY=$(mktemp /etc/haproxy/haproxy.cfg.XXX)
        echo "Backing up /etc/haproxy/haproxy.cfg to $BACKUP_HAPROXY"
        cat /etc/haproxy/haproxy.cfg > $BACKUP_HAPROXY
    fi

    # make sure haproxy is enabled
    cat > /etc/default/haproxy <<DEFAULT
ENABLED=1
DEFAULT

    # configure haproxy
    cat > /etc/haproxy/haproxy.cfg <<HAPROXY
global
    maxconn 350

frontend frontend
    mode http

    bind 0.0.0.0:80
    bind 127.0.0.1:8080

    timeout client 24h
    option forwardfor except 127.0.0.1
    option httpclose

    # make sure that requests have x-forwarded-proto: https iff tls
    reqidel ^X-Forwarded-Proto:.*
    acl is-ssl dst_port 8080
    reqadd X-Forwarded-Proto:\ https if is-ssl

    # send websockets to the websocket service
    acl is-websocket hdr(Upgrade) -i WebSocket
    use_backend websockets if is-websocket

    # send media stuff to the local nginx
    acl is-media path_beg /media/
    use_backend media if is-media

    # send pixel stuff to local nginx
    acl is-pixel path_beg /pixel/
    acl is-click path_beg /click
    use_backend pixel if is-pixel || is-click

    default_backend reddit

backend reddit
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server app01-8001 localhost:8001 maxconn 30

backend websockets
    mode http
    timeout connect 4s
    timeout server 24h
    balance roundrobin

    server websockets localhost:9001 maxconn 250

backend media
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server nginx localhost:9000 maxconn 20

backend pixel
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server nginx localhost:8082 maxconn 20
HAPROXY

    # this will start it even if currently stopped
    service haproxy restart
fi

###############################################################################
# websocket service
###############################################################################
if [ "$INSTALL_PROFILE" = "all" ]; then
    if [ ! -f /etc/init/reddit-websockets.conf ]; then
        cat > /etc/init/reddit-websockets.conf << UPSTART_WEBSOCKETS
description "websockets service"

stop on runlevel [!2345] or reddit-restart all or reddit-restart websockets
start on runlevel [2345] or reddit-restart all or reddit-restart websockets

respawn
respawn limit 10 5
kill timeout 15

limit nofile 65535 65535

exec baseplate-serve2 --bind localhost:9001 $REDDIT_SRC/websockets/example.ini
UPSTART_WEBSOCKETS
    fi
    service reddit-websockets restart
fi

###############################################################################
# activity service
###############################################################################
if [ "$INSTALL_PROFILE" = "all" ]; then
    if [ ! -f /etc/init/reddit-activity.conf ]; then
        cat > /etc/init/reddit-activity.conf << UPSTART_ACTIVITY
description "activity service"

stop on runlevel [!2345] or reddit-restart all or reddit-restart activity
start on runlevel [2345] or reddit-restart all or reddit-restart activity

respawn
respawn limit 10 5
kill timeout 15

exec baseplate-serve2 --bind localhost:9002 $REDDIT_SRC/activity/example.ini
UPSTART_ACTIVITY
    fi
    service reddit-activity restart
fi

###############################################################################
# geoip service
###############################################################################
if [ ! -f /etc/gunicorn.d/geoip.conf ]; then
    cat > /etc/gunicorn.d/geoip.conf <<GEOIP
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_SRC/reddit/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=127.0.0.1:5000",
        "--workers=1",
         "--limit-request-line=8190",
         "geoip_service:application",
    ),
}
GEOIP
fi
service gunicorn restart

###############################################################################
# Job Environment
###############################################################################
CONSUMER_CONFIG_ROOT=$REDDIT_HOME/consumer-count.d

if [ ! -f /etc/default/reddit ]; then
    cat > /etc/default/reddit <<DEFAULT
export REDDIT_ROOT=$REDDIT_SRC/reddit/r2
export REDDIT_INI=$REDDIT_SRC/reddit/r2/run.ini
export REDDIT_USER=$REDDIT_USER
export REDDIT_GROUP=$REDDIT_GROUP
export REDDIT_CONSUMER_CONFIG=$CONSUMER_CONFIG_ROOT
export REDDIT_SRC=$REDDIT_SRC
export PGUSER=$PGUSER
export PGHOST=$PGHOST
alias wrap-job=$REDDIT_SRC/reddit/scripts/wrap-job
alias manage-consumers=$REDDIT_SRC/reddit/scripts/manage-consumers
DEFAULT
fi

###############################################################################
# Queue Processors
###############################################################################
mkdir -p $CONSUMER_CONFIG_ROOT

function set_consumer_count {
    if [ ! -f $CONSUMER_CONFIG_ROOT/$1 ]; then
        echo $2 > $CONSUMER_CONFIG_ROOT/$1
    fi
}

set_consumer_count search_q 1
set_consumer_count del_account_q 1
set_consumer_count scraper_q 1
set_consumer_count markread_q 1
set_consumer_count commentstree_q 1
set_consumer_count newcomments_q 1
set_consumer_count vote_link_q 1
set_consumer_count vote_comment_q 1
set_consumer_count automoderator_q 0 #Maybe set to 1?
set_consumer_count butler_q 1
set_consumer_count author_query_q 1
set_consumer_count subreddit_query_q 1
set_consumer_count domain_query_q 1
set_consumer_count modmail_email_q 0
set_consumer_count sitemaps_q 0
# TODO: workaround consumer being broken, see issues/44
set_consumer_count event_collector_q 0

chown -R $REDDIT_USER:$REDDIT_GROUP $CONSUMER_CONFIG_ROOT/

###############################################################################
# Complete plugin setup, if setup.sh exists
###############################################################################
for plugin in $REDDIT_AVAILABLE_PLUGINS; do
    if [ -x $REDDIT_SRC/$plugin/setup.sh ]; then
        echo "Found setup.sh for $plugin; running setup script"
        $REDDIT_SRC/$plugin/setup.sh $REDDIT_SRC $REDDIT_USER
    fi
done

###############################################################################
# Start everything up
###############################################################################

# the initial database setup should be done by one process rather than a bunch
# vying with eachother to get there first
if [ "$INSTALL_PROFILE" = "all" ]; then
    reddit-run -c 'print "ok done"'

    # ok, now start everything else up
    initctl emit reddit-stop
    initctl emit reddit-start
fi

###############################################################################
# Cron Jobs
###############################################################################
if [ "$INSTALL_PROFILE" = "all" ]; then
    if [ ! -f /etc/cron.d/reddit ]; then
        cat > /etc/cron.d/reddit <<CRON
0    3 * * * root /sbin/start --quiet reddit-job-update_sr_names
30  16 * * * root /sbin/start --quiet reddit-job-update_reddits
0    * * * * root /sbin/start --quiet reddit-job-update_promos
*/5  * * * * root /sbin/start --quiet reddit-job-clean_up_hardcache
*/2  * * * * root /sbin/start --quiet reddit-job-broken_things
*/2  * * * * root /sbin/start --quiet reddit-job-rising
0    * * * * root /sbin/start --quiet reddit-job-trylater
*/15 * * * * root /sbin/start --quiet reddit-job-update_popular_subreddits
0    * * * * root /sbin/start --quiet reddit-job-hourly_traffic
0    * * * * root /sbin/start --quiet reddit-job-subscribers

# liveupdate plugin
#*    * * * * root /sbin/start --quiet reddit-job-liveupdate_activity

# gold plugin
#0    0 * * * root /sbin/start --quiet reddit-job-update_gold_users

# jobs that recalculate time-limited listings (e.g. top this year)
# password must match 'db_pass' in development.update
PGPASSWORD=password
*/15 * * * * $REDDIT_USER $REDDIT_SRC/reddit/scripts/compute_time_listings link year "['hour', 'day', 'week', 'month', 'year']"
*/15 * * * * $REDDIT_USER $REDDIT_SRC/reddit/scripts/compute_time_listings comment year "['hour', 'day', 'week', 'month', 'year']"

# disabled by default, uncomment if you need these jobs
#*    * * * * root /sbin/start --quiet reddit-job-email
#*/15  * * * * root /sbin/start reddit-job-update_trending_subreddits

# solr search
0 * * * * root /sbin/start --quiet reddit-job-solr_subreddits
*/15 * * * * root /sbin/start --quiet reddit-job-solr_links

# TODO: workaround consumer being broken, see issues/44
*/5 * * * * $REDDIT_USER $REDDIT_HOME/rabbitmqadmin purge queue name=event_collector
CRON
    fi
fi

###############################################################################
# Finished with install script
###############################################################################
# print this out here. if vagrant's involved, it's gonna do more steps
# afterwards and then re-run this script but that's ok.
$RUNDIR/done.sh

