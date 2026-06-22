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
    DirectoryIndex index.html index.htm
    # Cookie auth: route unmatched URLs through the auth wrapper, which
    # validates the cookie, sets X-Remote-*, then execs the processor.
    FallbackResource /cgi-bin/lazysite-auth.pl
    <Location /lazysite/>
        Require all denied
    </Location>
    <Directory %home%/%user%/web/%domain%/stats>
        AllowOverride All
    </Directory>
    <Directory %docroot%>
        AllowOverride All
        Options -Indexes +ExecCGI
    </Directory>
    SetEnvIf Authorization .+ HTTP_AUTHORIZATION=$0
    IncludeOptional %home%/%user%/conf/web/%domain%/%web_system%.conf_*
    IncludeOptional /etc/apache2/conf.d/*.inc
</VirtualHost>
