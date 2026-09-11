#=========================================================================#
# lazysite Web Domain Template                                            #
# Markdown-driven pages with Template Toolkit rendering                   #
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
    Alias /vstats/ %home%/%user%/web/%domain%/stats/
    Alias /error/ %home%/%user%/web/%domain%/document_errors/
    #SuexecUserGroup %user% %group%
    CustomLog /var/log/%web_system%/domains/%domain%.bytes bytes
    CustomLog /var/log/%web_system%/domains/%domain%.log combined
    ErrorLog /var/log/%web_system%/domains/%domain%.error.log
    IncludeOptional %home%/%user%/conf/web/%domain%/apache2.forcessl.conf*
    DirectoryIndex index.html index.htm
    FallbackResource /cgi-bin/lazysite-processor.pl
    <Location /lazysite/>
        Require all denied
    </Location>
    # SM797: what is SOURCE rather than asset is the engine's to answer, never
    # this server's. The engine refuses to hand these types out and renders a
    # page asked for by its source name (/about.md is /about) - but only for a
    # request that reaches it, and a file that EXISTS is served from disk before
    # lazysite is consulted. So these go to the engine whether or not the file
    # exists and whether or not the site has an ACL store, and every front end
    # gives the engine's answer. The list is the engine's (%STATIC_DENY in
    # lazysite-processor.pl) less .shtml/.shtm, a legacy SSI page (SM133) being
    # this server's to expand; t/lint/131 pins it here and in every other
    # shipped front end. .brief sidecars (SM073) are on it.
    #
    # Before every rule that ends in [L]. /cgi-bin/ and /dav are the script
    # surfaces; /lazysite/ keeps its own deny.
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/(?:cgi-bin|dav|lazysite)(?:/|$)
    RewriteRule \.(?:md|url|brief|bak|swp|swo|orig|old|tmp|conf|ini|env|pem|key|pl|pm|cgi|fcgi|phtml|php|php3|php4|php5|phps|phar|htaccess|htpasswd)$ /cgi-bin/lazysite-processor.pl [NC,PT,L]
    <Directory %home%/%user%/web/%domain%/stats>
        AllowOverride None
    </Directory>
    <Directory %docroot%>
        AllowOverride None
        Options -Indexes +ExecCGI
    </Directory>
    SetEnvIf Authorization .+ HTTP_AUTHORIZATION=$0
    IncludeOptional %home%/%user%/conf/web/%domain%/%web_system%.conf_*
    IncludeOptional /etc/apache2/conf.d/*.inc
</VirtualHost>
