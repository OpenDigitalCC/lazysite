#=========================================================================#
# md-pages Web Domain Template                                            #
# Markdown-driven pages with Template Toolkit rendering                   #
# https://github.com/OpenDigitalCC/md-pages                              #
# DO NOT MODIFY THIS FILE! CHANGES WILL BE LOST WHEN REBUILDING DOMAINS  #
#=========================================================================#
<VirtualHost %ip%:%web_port%>
    ServerName %domain_idn%
    %alias_string%
    ServerAdmin %email%
    DocumentRoot %docroot%
    ScriptAlias /cgi-bin/ %home%/%user%/web/%domain%/cgi-bin/
    Alias /vstats/ %home%/%user%/web/%domain%/stats/
    Alias /error/ %home%/%user%/web/%domain%/document_errors/
    #SuexecUserGroup %user% %group%
    CustomLog /var/log/%web_system%/domains/%domain%.bytes bytes
    CustomLog /var/log/%web_system%/domains/%domain%.log combined
    ErrorLog /var/log/%web_system%/domains/%domain%.error.log
    IncludeOptional %home%/%user%/conf/web/%domain%/apache2.forcessl.conf*
    DirectoryIndex index.html index.htm
    AddOutputFilter INCLUDES .shtml
    ErrorDocument 403 /cgi-bin/md-processor.pl
    ErrorDocument 404 /cgi-bin/md-processor.pl
    <Directory %home%/%user%/web/%domain%/stats>
        AllowOverride All
    </Directory>
    <Directory %docroot%>
        AllowOverride All
        Options +Includes -Indexes +ExecCGI
    </Directory>
    SetEnvIf Authorization .+ HTTP_AUTHORIZATION=$0
    IncludeOptional %home%/%user%/conf/web/%domain%/%web_system%.conf_*
    IncludeOptional /etc/apache2/conf.d/*.inc
</VirtualHost>
