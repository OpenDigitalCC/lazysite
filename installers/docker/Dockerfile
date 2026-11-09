# lazysite in one container serving many sites: nginx, and for each site its
# one-rule FastCGI pool and its persistent runtime (lazysited) (SM1233, SM1361;
# rulings 201, 205, 208, 210). Built LOCALLY from the release tarball - there is
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
# THE SPLIT. The engine and its extensions are the image, read-only, and every
# site runs them (install.pl --engine shared: no engine copy in a site). The
# sites are folders in one parent volume (compose.yaml), listed in its
# sites.conf, and install.pl lays each one there at the first start
# (entrypoint.sh). Nothing is installed into the volume at build time, so an
# image upgrade never overwrites a site's data.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# The engine's hard requirements and the modules behind the stock manager
# features are the debian/control Depends and Recommends of lazysite-common;
# libfcgi-perl and libfcgi-procmanager-perl are the pool. curl is the
# healthcheck's and `lazysite-sites status`'s.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libarchive-zip-perl \
        libcryptx-perl \
        libfcgi-perl \
        libfcgi-procmanager-perl \
        libio-socket-ssl-perl \
        libtemplate-perl \
        libtext-multimarkdown-perl \
        liburi-perl \
        libwww-perl \
        nginx \
        perl \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# The release, where the .debs put the engine payload, root-owned: no process in
# the container can change it. install.pl reads its release-manifest.json from
# beside itself.
COPY . /usr/share/lazysite

# The shared engine (SM1361):
#   - the marker that makes it one. Lazysite::Extensions reads it: only the
#     image's own extensions run, and a site's extension file is refused by
#     name (ruling 210); install.pl reads it: a new site holds no engine copy.
#     t/lint/392 holds the name;
#   - the CGIs executable, as install.pl would leave a cgi-bin;
#   - the extension endpoints the front door relays to by name, linked beside
#     the CGIs, as install.pl links them into a cgi-bin (endpoint_links;
#     t/tools/210 holds the list).
RUN printf 'this engine is shared and read-only (SM1361)\n' > /usr/share/lazysite/SHARED-ENGINE \
    && chmod 0755 /usr/share/lazysite/lazysite-*.pl /usr/share/lazysite/extensions/*.pl \
        /usr/share/lazysite/installers/docker/entrypoint.sh /usr/share/lazysite/installers/docker/lazysite-sites \
    && ln -s extensions/form-handler.pl /usr/share/lazysite/form-handler.pl \
    && ln -s extensions/payment-demo.pl /usr/share/lazysite/payment-demo.pl \
    && ln -s /usr/share/lazysite/installers/docker/entrypoint.sh /usr/local/bin/lazysite-entrypoint \
    && ln -s /usr/share/lazysite/installers/docker/lazysite-sites /usr/local/bin/lazysite-sites

COPY installers/docker/nginx.conf /etc/nginx/nginx.conf

# Everything that runs is www-data (ruling 210). The parent volume's mount point
# exists and belongs to www-data HERE, so that a new named volume mounted over
# it takes that ownership; setgid, so every site folder keeps the group.
RUN mkdir -p /srv/sites /run/lazysite /tmp/nginx \
    && chown www-data:www-data /srv/sites /run/lazysite /tmp/nginx \
    && chmod 2775 /srv/sites

USER www-data
WORKDIR /srv/sites

# TLS is the operator's proxy's job (ruling 205): this listens on plain 8080.
EXPOSE 8080

# Healthy while nginx answers; a site that is not serving is named by
# `lazysite-sites status`, never by this (ruling 208).
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/lazysite-health || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/lazysite-entrypoint"]
CMD ["run"]
