#=========================================================================#
# lazysite-app Web Domain Template                                        #
# Markdown-driven pages with Template Toolkit rendering                   #
# Built-in cookie auth + manager UI + WebDAV wired through lazysite-auth  #
# https://github.com/OpenDigitalCC/lazysite                              #
# DO NOT MODIFY THIS FILE! CHANGES WILL BE LOST WHEN REBUILDING DOMAINS  #
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
    # the cookie auth wrapper.
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
    # cache for the homepage, and serving it directly would bypass the processor
    # (and the auth wrapper), so the per-request manager admin bar would never
    # appear on "/". With it removed, a lazysite markdown home (index.md) falls
    # through to FallbackResource -> the processor, which serves the cache AND
    # injects the bar. A purely static index.html home (no index.md) is still
    # served directly by the rewrite below.
    DirectoryIndex index.htm index.shtml
    # SM223: static files under access control. A file the web server serves
    # directly is reachable by anyone who knows its path, and no auth decision
    # lazysite makes can reach it - the [L] on every rule below is exactly the
    # point. So when the site has an ACL store, a request that would otherwise be
    # served directly goes through the auth wrapper instead: it validates the
    # cookie, sets X-Remote-*, and execs the processor, which consults
    # lazysite/auth/acls.json and then serves, refuses with 403, or bounces to
    # login.
    #
    # The first condition is a file-existence test of the same kind the rules
    # below already perform, so a site with NO ACLs pays nothing and keeps direct
    # static serving at full speed. That is what makes protecting a path a pure
    # content action - no vhost regeneration and no reload, ever. The cost, stated
    # plainly: on a site with any ACL entry, every static request goes through the
    # engine.
    #
    # These must come FIRST. Every rule below terminates with [L], so anything
    # placed after them would serve an ACL'd file before the ACL was consulted.
    # /cgi-bin/ is excluded so the rewrite target cannot match itself.
    RewriteCond %{DOCUMENT_ROOT}/lazysite/auth/acls.json -f
    RewriteCond %{REQUEST_URI} !^/cgi-bin/
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI} -f
    RewriteRule ^/(.*)$ /cgi-bin/lazysite-auth.pl [L]
    RewriteCond %{DOCUMENT_ROOT}/lazysite/auth/acls.json -f
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md !-f
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.html -f [OR]
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.shtml -f
    RewriteRule ^/([^.]+)$ /cgi-bin/lazysite-auth.pl [L]
    RewriteCond %{DOCUMENT_ROOT}/lazysite/auth/acls.json -f
    RewriteCond %{DOCUMENT_ROOT}/index.md !-f
    RewriteCond %{DOCUMENT_ROOT}/index.html -f
    RewriteRule ^/$ /cgi-bin/lazysite-auth.pl [L]
    RewriteCond %{DOCUMENT_ROOT}/index.md   !-f
    RewriteCond %{DOCUMENT_ROOT}/index.html -f
    RewriteRule ^/$ /index.html [L]
    # SM133: migration fallback for clean URLs. A path with no Markdown source but
    # a static sibling is served directly - .shtml preferred so Apache expands SSI
    # includes (mod_include), else .html - keeping a legacy pre-lazysite page intact
    # until it is converted to Markdown. Generalises the homepage rule above and is
    # self-limiting: it fires only when the static sibling exists and no .md does,
    # so system paths (which have neither) are untouched, and a .md source shadows
    # it the moment it lands. The processor has an equivalent verbatim fallback for
    # non-Apache fronts; this rule is what preserves SSI on a live site.
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md    !-f
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.shtml -f
    RewriteRule ^/([^.]+)$ /$1.shtml [L]
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md   !-f
    RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.html -f
    RewriteRule ^/([^.]+)$ /$1.html [L]
    # Cookie auth: route unmatched URLs through the auth wrapper, which
    # validates the cookie, sets X-Remote-*, then execs the processor.
    FallbackResource /cgi-bin/lazysite-auth.pl
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
        AllowOverride None
    </Directory>
    <Directory %docroot%>
        AllowOverride None
        Options -Indexes +ExecCGI +IncludesNOEXEC
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
