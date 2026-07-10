#=========================================================================#
# lazysite-fcgi Web Domain Template (FastCGI pool pattern)                #
# Shipped by the lazysite-hestia package (SM139 increment 4); copy to     #
# /usr/local/hestia/data/templates/web/apache2/php-fpm/ to use.           #
# Visitor pages proxy to the per-domain lazysite@ pool socket; the auth   #
# wrapper and manager stay on the CGI path (they are not pooled).         #
# Needs: a2enmod headers rewrite proxy proxy_fcgi (+ include for SSI),    #
# /etc/lazysite/pools/%domain%.conf + `systemctl enable --now             #
# lazysite@%domain%` (lazysite-hestia-domain add --fcgi does both).       #
# https://lazysite.io                                                     #
# DO NOT MODIFY THIS FILE! CHANGES WILL BE LOST WHEN REBUILDING DOMAINS   #
#=========================================================================#
<VirtualHost %ip%:%web_port%>
    ServerName %domain_idn%
    %alias_string%
    ServerAdmin %email%
    DocumentRoot %docroot%
    # Strip client-supplied trust headers before any trusted component
    # sets them (security.md "Apache config requirement"). Needs mod_headers.
    RequestHeader unset X-Remote-User
    RequestHeader unset X-Remote-Groups
    RequestHeader unset X-Remote-Name
    RequestHeader unset X-Remote-Email
    RequestHeader unset X-Payment-Verified
    RequestHeader unset X-Payment-Payer
    ScriptAlias /cgi-bin/ %home%/%user%/web/%domain%/cgi-bin/
    # SM070: WebDAV publishing endpoint - its own Basic auth, bypasses
    # the cookie auth wrapper. Stays CGI: DAV traffic is authenticated
    # per request, exactly what the pool does not do.
    ScriptAlias /dav %home%/%user%/web/%domain%/cgi-bin/lazysite-dav.pl
    # Front the cgi-bin scripts with the auth wrapper so the session
    # cookie becomes X-Remote-User before the target CGI runs (security.md:
    # "every /cgi-bin/*.pl passes through the auth wrapper"). auth.pl execs
    # LAZYSITE_PROCESSOR. Excludes auth.pl (recursion); /dav does its own
    # Basic auth. Needs mod_rewrite.
    RewriteEngine On
    RewriteRule ^/cgi-bin/(lazysite-(?:processor|manager-api)\.pl)$ /cgi-bin/lazysite-auth.pl [E=LAZYSITE_PROCESSOR:%home%/%user%/web/%domain%/cgi-bin/$1,PT]
    Alias /vstats/ %home%/%user%/web/%domain%/stats/
    Alias /error/ %home%/%user%/web/%domain%/document_errors/
    #SuexecUserGroup %user% %group%
    CustomLog /var/log/%web_system%/domains/%domain%.bytes bytes
    CustomLog /var/log/%web_system%/domains/%domain%.log combined
    ErrorLog /var/log/%web_system%/domains/%domain%.error.log
    IncludeOptional %home%/%user%/conf/web/%domain%/apache2.forcessl.conf*
    # index.html is deliberately NOT a DirectoryIndex: it is lazysite's own page
    # cache for the homepage, and serving it directly would bypass the processor,
    # so the per-request manager admin bar would never appear on "/". With it
    # removed, a lazysite markdown home (index.md) falls through to the pool (or,
    # with a session cookie, the auth wrapper) - which serves the cache AND
    # injects the bar. A purely static index.html home (no index.md) is still
    # served directly by the rewrite below.
    DirectoryIndex index.htm index.shtml
    RewriteCond %{DOCUMENT_ROOT}/index.md   !-f
    RewriteCond %{DOCUMENT_ROOT}/index.html -f
    RewriteRule ^/$ /index.html [L]
    # SM133: migration fallback for clean URLs. A path with no Markdown source but
    # a static sibling is served directly - .shtml preferred so Apache expands SSI
    # includes (mod_include), else .html - keeping a legacy pre-lazysite page intact
    # until it is converted to Markdown. Self-limiting: it fires only when the
    # static sibling exists and no .md does, so system paths (which have neither)
    # are untouched, and a .md source shadows it the moment it lands.
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md    !-f
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.shtml -f
    RewriteRule ^/([^.]+)$ /$1.shtml [L]
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md   !-f
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.html -f
    RewriteRule ^/([^.]+)$ /$1.html [L]
    # Session-bearing requests stay on the CGI path: the pooled worker is
    # anonymous BY DESIGN (the auth wrapper's exec-per-request trust-header
    # model is not pooled - docs/architecture/performance.md), so a request
    # carrying the lazysite_auth session cookie must go through the CGI auth
    # wrapper, which turns the cookie into X-Remote-User before the processor
    # runs. This is what makes /manager/ and the logged-in admin bar work;
    # only cookie-less visitor traffic - the hot path - reaches the pool.
    RewriteCond %{HTTP_COOKIE} lazysite_auth=
    # Existing files (assets, static pages) keep being served directly,
    # session or not - mirrors what FallbackResource does for the pool path.
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI} !-f
    # /cgi-bin and /dav are handled by their ScriptAlias lines above; keep
    # them out of this rewrite (also breaks the rewrite-again loop after PT).
    RewriteCond %{REQUEST_URI} !^/(?:cgi-bin|dav)(?:/|$)
    RewriteRule ^ /cgi-bin/lazysite-auth.pl [PT,L]
    # FastCGI pool (SM142/SM139): every remaining URL that maps to no file
    # falls through to this virtual path, and the <Location> below hands it
    # to the persistent per-domain pool - lazysite@%domain%, identity in
    # /etc/lazysite/pools/%domain%.conf. The pooled processor recovers the
    # original URL from REDIRECT_URL/REQUEST_URI (both survive the internal
    # redirect), so no path information is lost.
    FallbackResource /lazysite-pool
    <Location "/lazysite-pool">
        # Socket path = the lazysite@.service convention:
        # /run/lazysite/<instance>.sock with instance = the domain (see the
        # unit file and tools/lazysite-pool.pl). Needs mod_proxy +
        # mod_proxy_fcgi. A direct client request for /lazysite-pool just
        # reaches the processor as an unknown page (404) - harmless.
        SetHandler "proxy:unix:/run/lazysite/%domain%.sock|fcgi://localhost/"
    </Location>
    <Location /lazysite/>
        Require all denied
    </Location>
    # SM073: .brief sidecars document authoring intent and are never public.
    # FallbackResource only routes non-existent paths through, so an existing
    # .brief is otherwise served raw - deny it here at the origin.
    <FilesMatch "\.brief$">
        Require all denied
    </FilesMatch>
    <Directory %home%/%user%/web/%domain%/stats>
        AllowOverride All
    </Directory>
    <Directory %docroot%>
        AllowOverride All
        Options -Indexes +ExecCGI +Includes
        # Server-Side Includes for an overlaid static (.shtml) site - mod_include.
        # Harmless for markdown-only sites (no .shtml present); an existing
        # index.shtml is served via DirectoryIndex so lazysite's markdown
        # fallback never shadows the original homepage.
        AddType text/html .shtml
        AddOutputFilter INCLUDES .shtml
    </Directory>
    SetEnvIf Authorization .+ HTTP_AUTHORIZATION=$0
    IncludeOptional %home%/%user%/conf/web/%domain%/%web_system%.conf_*
    IncludeOptional /etc/apache2/conf.d/*.inc
</VirtualHost>
