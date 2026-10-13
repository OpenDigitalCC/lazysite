#!/usr/bin/perl
# SM1066: ONE LOOKUP FINDS THE PROCESSOR, and on every packaged layout where a
# preview found it before, it finds the same file.
#
# Before SM1066 there were two rules (SM1065):
#   COMMON  Manager::Common::processor_path - LAZYSITE_PROCESSOR's directory,
#           else the docroot's ../cgi-bin; not checked for existence. The
#           manager's previews, MCP preview_public_page and preview_domain.
#   MCP     lazysite-mcp.pl _processor_tool - beside abs_path of the script,
#           else the docroot's ../cgi-bin; the first that is a file. MCP
#           preview_page.
# Both are kept below, verbatim in effect, as the record of what each install
# resolved to. The ruled rule (Lazysite::Paths::find_processor) is LAZYSITE_
# PROCESSOR's directory, then beside the running CGI, then ../cgi-bin.
#
# The layouts are read from what ships, so a template that changes its wiring
# changes this matrix rather than leaving it describing yesterday's install:
#   install.pl        its own usage example: --docroot /var/www/html
#                     --cgibin /usr/lib/cgi-bin (cgi-bin AWAY from ../cgi-bin)
#   provision / deb   lazysite-hestia-domain.pl and the nginx/apache vhost
#                     tools' default: <dom>/public_html + <dom>/cgi-bin
#                     (the deb ships the engine at /usr/share/lazysite and
#                     `lazysite provision` copies it into the site; install.pl
#                     refuses to write through a symlink, so a site's CGIs are
#                     real files)
#   dev server        tools/lazysite-server.pl: docroot <repo>/starter, the
#                     CGIs at the repo root, LAZYSITE_PROCESSOR = the script
# and the wiring - which CGI is handed LAZYSITE_PROCESSOR, and naming what -
# from the nginx examples, the Apache examples and the Hestia templates.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use Cwd            qw(abs_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Paths ();
use Lazysite::Manager::Common ();

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return scalar <$fh>;
}

# --- the shipped facts -------------------------------------------------------

like( slurp("$root/install.pl"), qr{install\.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin},
    'install.pl\'s own example puts the cgi-bin at /usr/lib/cgi-bin, away from the docroot' );
my $hd = slurp("$root/tools/lazysite-hestia-domain.pl");
like( $hd, qr{\$docroot = "\$domdir/public_html"}, 'Hestia provision: the docroot is <dom>/public_html' );
like( $hd, qr{\$cgibin  = "\$domdir/cgi-bin"},     'and the cgi-bin <dom>/cgi-bin' );
like( slurp("$root/tools/$_"), qr{dirname\(\$docroot\) \. '/cgi-bin'},
    "$_: the cgi-bin defaults to the docroot's sibling" )
    for qw(lazysite-nginx-vhost.pl lazysite-apache-vhost.pl);

# Which CGIs a template hands LAZYSITE_PROCESSOR to, as { script => what it names
# (a basename in the cgi-bin) }. A script absent from the map gets none.
sub nginx_wiring {
    my ($t) = @_;
    my %w;
    while ( $t =~ m{location = /cgi-bin/(lazysite-[a-z-]+\.pl) \{(.*?)\n    \}}sg ) {
        my ( $loc, $body ) = ( $1, $2 );
        $w{$loc} = $1 if $body =~ m{fastcgi_param LAZYSITE_PROCESSOR __CGIBIN__/(\S+);};
    }
    my ($generic) = $t =~ m{location ~ \^/cgi-bin/\(\?<lazysite_script>\[\^/\]\+\)\$ \{(.*?)\n    \}}s;
    die "no generic /cgi-bin/ location\n" unless defined $generic;
    $w{'lazysite-mcp.pl'} = $1 if $generic =~ m{LAZYSITE_PROCESSOR\s+__CGIBIN__/(\S+);};
    return \%w;
}

sub apache_wiring {
    my ( $t, $cgibin_re ) = @_;
    my %w;
    if ( $t =~ m{SetEnvIf Request_URI "\." LAZYSITE_PROCESSOR=$cgibin_re/(\S+)} ) {
        my $all = $1;
        $w{$_} = $all for qw(lazysite-manager-api.pl lazysite-mcp.pl);
    }
    # The auth-wrapper rewrite names the requested script itself.
    if ( $t =~ m{RewriteRule \^/cgi-bin/\(lazysite-\(\?:([a-z|-]+)\)\\\.pl\)\$ \S+ \[E=LAZYSITE_PROCESSOR:$cgibin_re/\$1} ) {
        $w{"lazysite-$_.pl"} = "lazysite-$_.pl" for split /\|/, $1;
    }
    return \%w;
}

my %wiring;
for my $f (qw(vhost-cgi vhost-fcgi)) {
    $wiring{"nginx $f"}  = nginx_wiring( slurp("$root/installers/nginx/$f.conf.example") );
    $wiring{"apache $f"} = apache_wiring( slurp("$root/installers/apache/$f.conf.example"), '__CGIBIN__' );
}
for my $f (qw(lazysite-cgi lazysite-fcgi lazysite-app)) {
    $wiring{"hestia $f.tpl"} = apache_wiring( slurp("$root/installers/hestia/$f.tpl"),
        '%home%/%user%/web/%domain%/cgi-bin' );
}
# The one-rule front door (vhost-one-rule*.conf.example, LAZYSITE_CGIBIN =
# __CGIBIN__) wraps the scripts its decision names, LAZYSITE_PROCESSOR = the
# script; the rest it execs bare.
{
    my $fd = slurp("$root/lazysite-processor/front-door.pm");
    my ($wrapped) = $fd =~ m{\$script =~ /\\A lazysite-\(\?:([a-z|-]+)\)\[\.\]pl \\z/x};
    die "front-door.pm: no wrap rule found\n" unless defined $wrapped;
    $wiring{'front door (one-rule)'} = { map { ( "lazysite-$_.pl" => "lazysite-$_.pl" ) } split /\|/, $wrapped };
    like( slurp("$root/installers/nginx/vhost-one-rule.conf.example"), qr{LAZYSITE_CGIBIN __CGIBIN__},
        'the one-rule vhost tells the front door where the cgi-bin is' );
}
# The dev server hands every CGI its own path (LAZYSITE_PROCESSOR => $target).
like( slurp("$root/tools/lazysite-server.pl"), qr{LAZYSITE_PROCESSOR => \$target,},
    'the dev server names the requested CGI in LAZYSITE_PROCESSOR' );
$wiring{'dev server'} = { map { $_ => $_ } qw(lazysite-manager-api.pl lazysite-mcp.pl) };

is( $wiring{'nginx vhost-cgi'}{'lazysite-manager-api.pl'}, 'lazysite-manager-api.pl',
    'nginx: the manager API is handed LAZYSITE_PROCESSOR (read from the template)' );
ok( !exists $wiring{'nginx vhost-cgi'}{'lazysite-mcp.pl'},
    'nginx: lazysite-mcp.pl is not - the SM1065 gap' );
is( $wiring{'apache vhost-cgi'}{'lazysite-mcp.pl'}, 'lazysite-processor.pl',
    'apache: every request is handed the processor' );
ok( !exists $wiring{'hestia lazysite-cgi.tpl'}{'lazysite-mcp.pl'},
    'hestia: lazysite-mcp.pl is not handed LAZYSITE_PROCESSOR' );

# --- the rules before SM1066 -------------------------------------------------

sub common_before {
    my ($docroot) = @_;
    my $lp  = $ENV{LAZYSITE_PROCESSOR};
    my $dir = ( defined $lp && length $lp ) ? dirname($lp) : "$docroot/../cgi-bin";
    return "$dir/lazysite-processor.pl";
}

sub mcp_before {
    my ( $docroot, $script ) = @_;
    my $bin = dirname( abs_path($script) );
    for my $c ( "$bin/lazysite-processor.pl", "$docroot/../cgi-bin/lazysite-processor.pl" ) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

# --- the layouts -------------------------------------------------------------

# The same FILE, which is what a shelled processor is: before, processor_path
# spelled the sibling cgi-bin <docroot>/../cgi-bin and preview_page spelled it
# <cgi-bin>; both are one file, and now both callers spell it the second way.
sub real { my ($p) = @_; return defined $p ? ( abs_path($p) // $p ) : undef }

my $t = TestHelper::site_tempdir( leaf => 'x' ) . '/..';
$t = abs_path($t);

sub touch {
    my ($p) = @_;
    make_path( dirname($p) );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} "#!/usr/bin/perl\n";
    close $fh;
    chmod 0644, $p;    # as git checks the tree out: readable, not executable
    return;
}

sub cgi_bin {
    my ($dir) = @_;
    touch("$dir/$_") for qw(lazysite-processor.pl lazysite-manager-api.pl lazysite-mcp.pl);
    return;
}

my %layout = (
    'provision (Hestia, deb, vhost default)' => [ "$t/dom/public_html",  "$t/dom/cgi-bin" ],
    'install.pl --cgibin /usr/lib/cgi-bin'    => [ "$t/var/www/html",     "$t/usr/lib/cgi-bin" ],
    'dev server (repo root)'                  => [ "$t/repo/starter",     "$t/repo" ],
);
for my $l ( values %layout ) {
    make_path( $l->[0] );
    cgi_bin( $l->[1] );
}

# Which wirings ship for which layout: every vhost template renders either
# placement (--cgibin), Hestia is always the sibling, the dev server is its own.
my %wirings_for = (
    'provision (Hestia, deb, vhost default)' => [ grep { !/dev server/ } sort keys %wiring ],
    'install.pl --cgibin /usr/lib/cgi-bin'    => [ grep { /nginx|apache|front door/ } sort keys %wiring ],
    'dev server (repo root)'                  => ['dev server'],
);

my ( $unchanged, $fixed ) = ( 0, 0 );
for my $name ( sort keys %layout ) {
    my ( $docroot, $cgibin ) = @{ $layout{$name} };
    local $Lazysite::Manager::Common::DOCROOT = $docroot;
    for my $wn ( @{ $wirings_for{$name} } ) {
        for my $script (qw(lazysite-manager-api.pl lazysite-mcp.pl)) {
            my $named = $wiring{$wn}{$script};
            local $ENV{LAZYSITE_PROCESSOR};
            if ( defined $named ) { $ENV{LAZYSITE_PROCESSOR} = "$cgibin/$named" }
            else                  { delete $ENV{LAZYSITE_PROCESSOR} }
            local $0 = "$cgibin/$script";
            my $case = "$name, $wn, $script";

            my $new      = Lazysite::Paths::find_processor( $docroot, "$cgibin/$script" );
            my $via_proc = Lazysite::Manager::Common::processor_path();
            is( $via_proc, $new, "$case: processor_path and find_processor agree" );
            ok( defined $new && -f $new, "$case: a processor is found" );

            my $c = common_before($docroot);
            if ( -f $c ) {
                is( real($new), real($c), "$case: where processor_path found it, the same file" );
                $unchanged++;
            }
            else {
                $fixed++;
                like( $case, qr{\Ainstall\.pl --cgibin .*, lazysite-mcp\.pl\z},
                    "$case: only MCP on a cgi-bin away from ../cgi-bin found nothing before" );
                note "$case: processor_path shelled the missing $c; now $new";
            }
            next unless $script eq 'lazysite-mcp.pl';
            my $m = mcp_before( $docroot, "$cgibin/$script" );
            ok( defined $m, "$case: MCP preview_page found one before" );
            is( real($new), real($m), "$case: preview_page finds the same file" );
            is( real($c), real($m), "$case: and the two rules agreed" ) if -f $c;
        }
    }
}
ok( $unchanged > 0, "$unchanged layout/wiring/CGI cases kept their path" );
ok( $fixed > 0,     "$fixed cases found nothing before (MCP, no LAZYSITE_PROCESSOR, cgi-bin away)" );

# --- a symlinked cgi-bin entry, resolved as MCP resolved it ------------------

subtest 'a cgi-bin entry that is a symlink resolves to its target\'s directory, as MCP did' => sub {
    my $share = "$t/usr/share/lazysite";
    cgi_bin($share);
    my ( $docroot, $cgibin ) = ( "$t/sym/public_html", "$t/sym/cgi-bin" );
    make_path( $docroot, $cgibin );
    symlink( "$share/lazysite-mcp.pl", "$cgibin/lazysite-mcp.pl" ) or die $!;
    delete local $ENV{LAZYSITE_PROCESSOR};
    my $m = mcp_before( $docroot, "$cgibin/lazysite-mcp.pl" );
    is( $m, "$share/lazysite-processor.pl", 'MCP resolved through the link' );
    is( Lazysite::Paths::find_processor( $docroot, "$cgibin/lazysite-mcp.pl" ), $m, 'and so does the one lookup' );
    local $0 = "$cgibin/lazysite-mcp.pl";
    local $Lazysite::Manager::Common::DOCROOT = $docroot;
    is( Lazysite::Manager::Common::processor_path(), $m,
        'processor_path, from the same CGI, now finds it too (it shelled the missing ../cgi-bin)' );
};

# --- nothing there -------------------------------------------------------------

subtest 'no processor anywhere: MCP says so, processor_path names the docroot\'s ../cgi-bin' => sub {
    my $docroot = "$t/empty/public_html";
    make_path($docroot);
    delete local $ENV{LAZYSITE_PROCESSOR};
    local $0 = "$t/empty/nowhere.pl";
    is( Lazysite::Paths::find_processor($docroot), undef, 'find_processor: undef' );
    local $Lazysite::Manager::Common::DOCROOT = $docroot;
    is( Lazysite::Manager::Common::processor_path(), "$docroot/../cgi-bin/lazysite-processor.pl",
        'processor_path: the path it tried, so the render fails naming it, as before' );
};

subtest 'the order: LAZYSITE_PROCESSOR\'s directory, then beside the CGI, then ../cgi-bin' => sub {
    my $docroot = "$t/order/public_html";
    make_path($docroot);
    cgi_bin($_) for "$t/order/cgi-bin", "$t/order/named", "$t/order/beside";
    local $0 = "$t/order/beside/lazysite-manager-api.pl";
    local $ENV{LAZYSITE_PROCESSOR} = "$t/order/named/lazysite-manager-api.pl";
    is( Lazysite::Paths::find_processor($docroot), "$t/order/named/lazysite-processor.pl",
        'LAZYSITE_PROCESSOR\'s directory first' );
    delete $ENV{LAZYSITE_PROCESSOR};
    is( Lazysite::Paths::find_processor($docroot), "$t/order/beside/lazysite-processor.pl",
        'then beside the running CGI' );
    local $0 = "$t/order/lazysite-manager-api.pl";
    is( Lazysite::Paths::find_processor($docroot), "$docroot/../cgi-bin/lazysite-processor.pl",
        'then the docroot\'s ../cgi-bin' );
    is_deeply( [ Lazysite::Paths::processor_candidates( $docroot, "$t/order/beside/x.pl" ) ],
        [ "$t/order/beside/lazysite-processor.pl", "$docroot/../cgi-bin/lazysite-processor.pl" ],
        'a script named outright is used in place of $0' );
};

subtest 'readable is enough: the source tree carries the CGIs at 0644' => sub {
    my ( $docroot, $cgibin ) = ( "$t/plain/public_html", "$t/plain/cgi-bin" );
    make_path($docroot);
    cgi_bin($cgibin);
    ok( !-x "$cgibin/lazysite-processor.pl", 'the processor is not executable' );
    delete local $ENV{LAZYSITE_PROCESSOR};
    is( Lazysite::Paths::find_processor( $docroot, "$cgibin/lazysite-mcp.pl" ), "$cgibin/lazysite-processor.pl",
        'and is found: every caller runs it through $^X' );
};

subtest 'LAZYSITE_PROCESSOR naming a script that is not the processor gives its directory' => sub {
    my ( $docroot, $cgibin ) = @{ $layout{'install.pl --cgibin /usr/lib/cgi-bin'} };
    local $ENV{LAZYSITE_PROCESSOR} = "$cgibin/lazysite-manager-api.pl";
    local $0 = "$t/elsewhere/x.pl";
    is( Lazysite::Paths::find_processor($docroot), "$cgibin/lazysite-processor.pl",
        'the processor in that directory, never the manager API itself' );
};

done_testing();
