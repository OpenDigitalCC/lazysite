# lazysite in one container: nginx, the one-rule FastCGI pool and the persistent
# runtime (lazysited) (SM1233). Built LOCALLY from the release tarball - there is
# no registry image and nothing is pushed:
#
#   tar xzf lazysite-X.Y.Z.tar.gz
#   cd lazysite-X.Y.Z/installers/docker
#   docker compose build
#
# The build context is the unpacked tarball (compose.yaml sets it to ../..), so
# what is built is exactly the release: the engine payload, install.pl and the
# release-manifest.json install.pl reads. Debian trixie is the base because it is
# what the .debs target (debian/control Depends).
#
# THE SPLIT. The engine code stays in the image. The site does not: it lives in
# three volumes (compose.yaml) that outlive the container,
#
#   /srv/lazysite/html                       the docroot
#   /srv/lazysite/html/lazysite              settings, accounts, logs
#   /srv/lazysite/html-lazysite-private      the private store
#
# and install.pl puts the site there at the first start (entrypoint.sh), the way
# `lazysite provision` does on a host. Nothing is installed into the volumes at
# build time, so an image upgrade never overwrites a site's data.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# The engine's hard requirements and the modules behind the stock manager
# features are the debian/control Depends and Recommends of lazysite-common;
# libfcgi-perl and libfcgi-procmanager-perl are the pool. curl is the
# healthcheck's. No Odoo, no OOM: this image does not carry them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libarchive-zip-perl \
        libfcgi-perl \
        libfcgi-procmanager-perl \
        libio-socket-ssl-perl \
        libtemplate-perl \
        libtext-multimarkdown-perl \
        liburi-perl \
        libwww-perl \
        nginx \
        perl \
    && rm -rf /var/lib/apt/lists/*

# The release, where the .debs put the engine payload. install.pl reads its
# release-manifest.json from beside itself.
COPY . /usr/share/lazysite
RUN chmod 0755 /usr/share/lazysite/installers/docker/entrypoint.sh \
    && ln -s /usr/share/lazysite/installers/docker/entrypoint.sh /usr/local/bin/lazysite-entrypoint

# The vhost is the one-rule pool template, not a copy of it: the placeholders
# are filled in and the logs go to the container's streams. The template is the
# one place the rule is written, so an image always carries the rule of its
# own release.
COPY installers/docker/nginx.conf /etc/nginx/nginx.conf
RUN mkdir -p /etc/nginx/conf.d \
    && sed \
        -e 's#/var/log/nginx/__DOMAIN__\.access\.log#/dev/stdout#' \
        -e 's#/var/log/nginx/__DOMAIN__\.error\.log#stderr#' \
        -e 's#__DOMAIN__#lazysite#g' \
        -e 's#__DOCROOT__#/srv/lazysite/html#g' \
        -e 's#__PORT__#8080#g' \
        /usr/share/lazysite/installers/nginx/vhost-one-rule-pool.conf.example \
        > /etc/nginx/conf.d/lazysite.conf \
    && ! grep -q '__[A-Z]*__' /etc/nginx/conf.d/lazysite.conf

# Everything that runs is www-data (the pool's USER and the socket's group, as
# the templates have it). The directories exist and belong to www-data HERE so
# that a new named volume mounted over one takes that ownership and mode. The
# docroot and lazysite/ are group-writable and setgid (2775) because the health
# check install.pl ends with requires it, and install.pl does not change a
# directory that already exists.
RUN mkdir -p /srv/lazysite/html/lazysite /srv/lazysite/html-lazysite-private \
        /srv/lazysite/cgi-bin /run/lazysite /tmp/nginx \
    && chown -R www-data:www-data /srv/lazysite /run/lazysite /tmp/nginx \
    && chmod 2775 /srv/lazysite/html /srv/lazysite/html/lazysite

USER www-data
WORKDIR /srv/lazysite

# TLS is the front end's job: this listens on plain 8080.
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/ || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/lazysite-entrypoint"]
CMD ["run"]
