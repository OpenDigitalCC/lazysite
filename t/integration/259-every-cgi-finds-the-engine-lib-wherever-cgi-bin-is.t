#!/usr/bin/perl
# SM1078: EVERY CGI FINDS THE ENGINE'S LIB, wherever the cgi-bin is.
#
# install.pl's own usage example is --docroot /var/www/html --cgibin
# /usr/lib/cgi-bin. It puts the CGIs in the cgi-bin and the Lazysite:: tree at
# {DOCROOT}/../lib (/var/www/lib); the CGIs looked for it only beside
# themselves (/usr/lib/cgi-bin/lib, /usr/lib/lib, /usr/lib), so every one of
# them but the plugins install.pl links died "Can't locate Lazysite/Util.pm" -
# and the health check at the end of the install did not notice. t/integration/
# 227 met it and put the modules on PERL5LIB.
#
# This is that install, made by install.pl itself into a temporary prefix
# (<tmp>/var/www/html, <tmp>/usr/lib/cgi-bin), and the provision layout
# (<dom>/public_html + <dom>/cgi-bin) beside it as the control. Each CGI runs
# once, as its file (0755, its own #! line), with PERL5LIB empty and the
# environment the nginx example gives it: the processor and the manager API
# through the auth wrapper with LAZYSITE_PROCESSOR naming them, the rest bare.
# A probe module (PERL5OPT) records where each loaded Lazysite:: from, whether
# the processor's lazy lookup finds a module, which processor Lazysite::Paths
# finds and whether lazysite.conf is where it looks.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use Cwd            qw(abs_path);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard site_tempdir);

my $root    = repo_root();
my $INSTALL = "$root/install.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;
my $MF_GUARD = repo_manifest_guard();
my $GROUP    = getgrgid( $) + 0 ) // ( $) + 0 );

my $t = abs_path( dirname( site_tempdir( leaf => 'x' ) ) );

# The probe, written where nothing else is on @INC.
my $probe = "$t/probe";
make_path($probe);
{
    open my $fh, '>', "$probe/LzsLibProbe.pm" or die $!;
    print {$fh} <<'PROBE';
package LzsLibProbe;
END {
    my $st = $?;
    my %r = ( script => $0 );
    if ( defined &main::_lazy_lib ) {
        $r{lazy} = eval { main::_lazy_lib('Lazysite::I18n'); 1 } ? 'ok' : 'FAIL';
    }
    my ($k) = sort grep { m{\ALazysite/} } keys %INC;
    ( $r{lib} = $INC{$k} ) =~ s{/Lazysite/.*\z}{} if $k;
    my $doc = $ENV{DOCUMENT_ROOT} // '';
    if ( $INC{'Lazysite/Paths.pm'} ) {
        $r{proc} = Lazysite::Paths::find_processor($doc) // '';
        my $d = Lazysite::Paths::lazysite_dir($doc);
        $r{conf} = -f "$d/lazysite.conf" ? 'ok' : 'missing';
    }
    if ( open my $fh, '>>', $ENV{LZS_LIB_PROBE} ) {
        print {$fh} join( "\t", map { "$_=" . ( $r{$_} // '' ) } sort keys %r ), "\n";
    }
    $? = $st;
}
1;
PROBE
    close $fh;
}

sub provision {
    my ( $docroot, $cgibin ) = @_;
    make_path( $docroot, $cgibin );
    my $out = `$^X \Q$INSTALL\E --mode provision --docroot \Q$docroot\E --cgibin \Q$cgibin\E --serving-group \Q$GROUP\E 2>&1`;
    my $rc = $? >> 8;
    # 4 = installed, and the health check named a fault: here, ownership the
    # test user cannot give (the same on both layouts).
    ok( $rc == 0 || $rc == 4, "install.pl provisioned $cgibin (rc $rc)" ) or diag $out;
    ok( -d "$docroot/../lib/Lazysite", 'and put the modules at {DOCROOT}/../lib' );
    return;
}

my %layout = (
    'install.pl --cgibin /usr/lib/cgi-bin' => [ "$t/var/www/html", "$t/usr/lib/cgi-bin" ],
    'provision (<dom>/cgi-bin)' => [ "$t/web/example.com/public_html", "$t/web/example.com/cgi-bin" ],
);
provision( @{$_} ) for values %layout;

# name, the file the web server runs, what it is handed, method, body
my @CGI = (
    [ 'processor', 'lazysite-processor.pl', uri => '/' ],
    [ 'processor via the auth wrapper', 'lazysite-auth.pl', proc => 'lazysite-processor.pl', uri => '/' ],
    [ 'manager API via the auth wrapper', 'lazysite-auth.pl', proc => 'lazysite-manager-api.pl',
        uri => '/cgi-bin/lazysite-manager-api.pl', qs => 'action=list' ],
    [ 'auth', 'lazysite-auth.pl', uri => '/cgi-bin/lazysite-auth.pl', qs => 'action=logout' ],
    [ 'MCP', 'lazysite-mcp.pl', uri => '/cgi-bin/lazysite-mcp.pl', method => 'POST',
        body => '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' ],
    [ 'DAV', 'lazysite-dav.pl', uri => '/dav/', method => 'PROPFIND', pi => '/' ],
    [ 'data',         'lazysite-data.pl',  uri => '/cgi-bin/lazysite-data.pl' ],
    [ 'form handler', 'form-handler.pl',   uri => '/cgi-bin/form-handler.pl' ],
    [ 'OAuth',        'lazysite-oauth.pl', uri => '/cgi-bin/lazysite-oauth.pl' ],
    [ 'Odoo',         'lazysite-odoo.pl',  uri => '/cgi-bin/lazysite-odoo.pl' ],
    [ 'one-rule front door', 'lazysite-front.pl', uri => '/cgi-bin/lazysite-mcp.pl', front => 1 ],
);

sub run_cgi {
    my ( $file, $env, $body ) = @_;
    my $rec = "$t/rec-" . int( rand 1e9 );
    local %ENV = (
        PATH     => '/usr/bin:/bin',          %$env,
        PERL5OPT => "-I$probe -MLzsLibProbe", LZS_LIB_PROBE => $rec,
    );
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, $file );
    print {$in} $body if defined $body;
    close $in;
    local $/;
    my $so = <$out> // '';
    my $se = <$err> // '';
    waitpid $pid, 0;
    my @recs;
    if ( open my $fh, '<', $rec ) {
        @recs = map { chomp; +{ map { split /=/, $_, 2 } split /\t/ } } <$fh>;
        close $fh;
    }
    return ( $so, $se, \@recs );
}

for my $name ( sort keys %layout ) {
    my ( $docroot, $cgibin ) = @{ $layout{$name} };
    my $lib = abs_path("$docroot/../lib");
    for my $c (@CGI) {
        my ( $what, $file, %o ) = @$c;
        my %env = (
            GATEWAY_INTERFACE => 'CGI/1.1', SERVER_PROTOCOL => 'HTTP/1.1', SERVER_NAME => 'example.com',
            HTTP_HOST     => 'example.com', SERVER_PORT => 80, REMOTE_ADDR => '127.0.0.1',
            DOCUMENT_ROOT => $docroot, REQUEST_METHOD => $o{method} // 'GET',
            REDIRECT_URL => $o{uri}, REQUEST_URI => $o{uri}, QUERY_STRING => $o{qs} // '',
            SCRIPT_FILENAME => "$cgibin/$file",
            ( $o{proc}  ? ( LAZYSITE_PROCESSOR => "$cgibin/$o{proc}" )            : () ),
            ( $o{pi}    ? ( PATH_INFO          => $o{pi}, SCRIPT_NAME => '/dav' ) : () ),
            ( $o{front} ? ( LAZYSITE_CGIBIN    => $cgibin )                       : () ),
            ( defined $o{body} ? ( CONTENT_LENGTH => length $o{body}, CONTENT_TYPE => 'application/json' ) : () ),
        );
        my $case = "$name, $what";
        ok( -x "$cgibin/$file", "$case: $file is installed and executable" );
        my ( $so, $se, $recs ) = run_cgi( "$cgibin/$file", \%env, $o{body} );
        unlike( $se, qr/Can't locate Lazysite/, "$case: the engine's modules load" )
            or diag( ( split /\n/, $se )[0] );
        like( $so, qr/\A(?:Status: \d{3}|Content-Type:)/mi, "$case: it answers with CGI headers" );
        my ($r) = grep { ( $_->{script} // '' ) =~ m{/\Q@{[ $o{proc} || $file ]}\E\z} } @$recs;
        $r //= $recs->[-1] // {};
        is( abs_path( $r->{lib} // '' ) // '', $lib, "$case: from {DOCROOT}/../lib" );
        is( $r->{lazy}, 'ok', "$case: the processor's lazy lookup finds a module" ) if exists $r->{lazy};
        is( $r->{conf}, 'ok', "$case: lazysite.conf is found" ) if exists $r->{conf};
        is( abs_path( $r->{proc} // '' ) // '', abs_path("$cgibin/lazysite-processor.pl"),
            "$case: the processor is the cgi-bin's" ) if exists $r->{proc} && $what =~ /manager|MCP/;
    }
}

done_testing();
