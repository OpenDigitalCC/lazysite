#!/usr/bin/perl
# SM389: every nginx template capped the request body and no Apache template
# did.
#
# WHY THE ASYMMETRY MATTERS. SM389 bounded the body inside the engine, which
# protects the engine. It cannot protect Apache: with CGI or FastCGI, Apache
# buffers what a client sends BEFORE the engine is handed the request, so an
# uncapped Apache absorbs a body the engine would have refused. nginx has
# carried client_max_body_size 64m in every template all along; the Apache
# templates simply never gained the equivalent.
#
# THE TENSION, RECORDED RATHER THAN GLOSSED. SM286 says the front end makes no
# decisions and these files shrink. A byte ceiling is a resource guard and not a
# routing decision, and it is parity with what nginx already has - but it is
# still a line in a file that principle wants shorter, so it is asserted here
# with its reason attached rather than left to be rediscovered as clutter.
#
# The Apache templates are also PARSED by real Apache, because a directive that
# is present and misspelled is worse than one that is absent: it looks like
# protection and refuses to start the server.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @nginx  = glob "$root/installers/nginx/*.conf.example";
my @apache = glob "$root/installers/apache/*.conf.example";
ok( @nginx,  'nginx templates are shipped' );
ok( @apache, 'apache templates are shipped' );

for my $f (@nginx) {
    my $s = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    my ($n) = $f =~ m{([^/]+)\z};
    like( $s, qr/^\s*client_max_body_size\s+\d+[kmg]?;/mi,
        "nginx $n caps the request body" );
}

for my $f (@apache) {
    my $s = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    my ($n) = $f =~ m{([^/]+)\z};
    like( $s, qr/^\s*LimitRequestBody\s+\d+/m, "apache $n caps the request body" );
}

# The two must agree. A front end that caps at 1m while its sibling caps at 64m
# is a deployment whose behaviour depends on which web server the operator
# happened to pick, which is the class of surprise SM286 exists to remove.
my %cap;
for my $f ( @nginx, @apache ) {
    my $s = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    if    ( $s =~ /^\s*client_max_body_size\s+(\d+)m;/mi ) { $cap{ $1 * 1024 * 1024 }++ }
    elsif ( $s =~ /^\s*LimitRequestBody\s+(\d+)/m )        { $cap{$1}++ }
}
is( scalar keys %cap, 1, 'every shipped template caps at the same size' )
    or diag( 'caps seen: ' . join ', ', sort keys %cap );

# --- and Apache must actually accept it -------------------------------
SKIP: {
    my $bin = ( grep { -x $_ } qw(/usr/sbin/apache2 /usr/sbin/httpd) )[0];
    skip 'no apache binary', 1 unless $bin;
    my $mods = ( grep { -d $_ } qw(/usr/lib/apache2/modules /usr/libexec/apache2) )[0];
    skip 'no apache module dir', 1 unless $mods;

    my $d   = tempdir( 'lazysite-apachecap-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $doc = "$d/doc";
    my $cgi = "$d/cgi";
    mkdir $_ for $doc, $cgi;

    my $tpl = "$root/installers/apache/vhost-one-rule.conf.example";
    my $s   = do { open my $fh, '<', $tpl or die $!; local $/; <$fh> };
    $s =~ s/__DOMAIN__/127.0.0.1/g;
    $s =~ s/__DOCROOT__/$doc/g;
    $s =~ s/__CGIBIN__/$cgi/g;
    $s =~ s/__PORT__/8099/g;

    # A minimal server around the rendered vhost - enough for a syntax check.
    my $conf = "ServerRoot /etc/apache2\nServerName 127.0.0.1\n"
        . "Define APACHE_LOG_DIR $d\n"
        . "PidFile $d/httpd.pid\nErrorLog $d/error.log\n"
        . "LoadModule mpm_prefork_module $mods/mod_mpm_prefork.so\n"
        . "LoadModule authz_core_module $mods/mod_authz_core.so\n"
        . "LoadModule alias_module $mods/mod_alias.so\n"
        . "LoadModule dir_module $mods/mod_dir.so\n"
        . "LoadModule cgi_module $mods/mod_cgi.so\n"
        . "LoadModule env_module $mods/mod_env.so\n"
        . "LoadModule headers_module $mods/mod_headers.so\n"
        . "LoadModule rewrite_module $mods/mod_rewrite.so\n"
        . "LoadModule proxy_module $mods/mod_proxy.so\n"
        . "LoadModule proxy_fcgi_module $mods/mod_proxy_fcgi.so\n"
        . "Listen 8099\n$s\n";
    open my $ch, '>', "$d/httpd.conf" or die $!;
    print {$ch} $conf;
    close $ch;

    my $out = `\Q$bin\E -t -f \Q$d/httpd.conf\E 2>&1`;
    like( $out, qr/Syntax OK/,
        'real Apache parses the capped one-rule template' )
        or diag($out);
}

done_testing();
