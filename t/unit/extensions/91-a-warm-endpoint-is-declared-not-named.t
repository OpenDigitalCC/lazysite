#!/usr/bin/perl
# SM1369 X5, H-5 (ruling 55): A WARM ENDPOINT IS ONE AN EXTENSION DECLARES.
#
# The pool's front door handed the Odoo endpoint to its warm-fork parent by
# comparing the script's name. Now an endpoint is warm when an enabled
# extension declares it so (`hooks.endpoints`, `warm: 1`), read from the hook
# index:
#
#   * the processor's module-free reader (_warm_endpoint) answers true for a
#     declared warm endpoint of an extension that is on, and false for one not
#     warm, one not declared, and one whose extension the conf has switched off;
#   * Lazysite::Extensions::Hooks::warm_endpoint answers the same, with the
#     declared preload list, which the warm-fork program compiles when it is
#     handed it (Lazysite::WarmFork::preload, a module that does not load is
#     skipped, a name that is not one is never required);
#   * the parent's socket is named for its endpoint: run/<name>-endpoint.sock,
#     so the Odoo endpoint keeps odoo-endpoint.sock;
#   * the Odoo extension declares its endpoint warm, with its preload list.
#
# Sabotage: make _warm_endpoint ignore `warm` and the endpoint that is not warm
# reads as warm - this fails.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir index_extensions load_processor silence_stdout repo_root);
use Lazysite::Extensions::Hooks ();
use Lazysite::WarmFork::Wire    ();
use Lazysite::WarmFork          ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

my $d    = site_tempdir();
my $base = dirname($d);
make_path( "$d/lazysite", "$base/extensions" );
write_extension( "$base/extensions/probe.pl", {
        id => 'probe', name => 'Probe', contract => 1,
        owns => { endpoints => [ 'lazysite-probe.pl', 'lazysite-probe-cold.pl' ],
            hooks => { endpoints => [
                    { script => 'lazysite-probe.pl', warm => 1, preload => [qw(List::Util No::Such::Module)] },
                    { script => 'lazysite-probe-cold.pl' } ] } } } );
spit( "$d/lazysite/lazysite.conf", "site_name: t\nextensions:\n  - extensions/probe.pl\n" );
my $r = index_extensions($d);
ok( $r->{ok} && grep( { $_ eq 'probe' } @{ $r->{indexed} } ), 'an extension that declares only endpoints is indexed' )
    or diag explain $r;

subtest 'the index says which endpoint is warm' => sub {
    my $ep = Lazysite::Extensions::Hooks::warm_endpoint( "$d/lazysite", 'lazysite-probe.pl' );
    is( $ep && $ep->{extension}, 'probe', 'the declared warm endpoint, with its extension' );
    is_deeply( $ep && $ep->{preload}, [qw(List::Util No::Such::Module)], '...and its preload list' );
    is( Lazysite::Extensions::Hooks::warm_endpoint( "$d/lazysite", '/srv/x/cgi-bin/lazysite-probe.pl' )->{script},
        'lazysite-probe.pl', 'a path names it as well' );
    ok( !Lazysite::Extensions::Hooks::warm_endpoint( "$d/lazysite", 'lazysite-probe-cold.pl' ), 'one not warm: no' );
    ok( !Lazysite::Extensions::Hooks::warm_endpoint( "$d/lazysite", 'lazysite-other.pl' ), 'one not declared: no' );

    silence_stdout { load_processor($d) };
    ok( main::_warm_endpoint('lazysite-probe.pl'), 'the processor\'s reader: warm' );
    ok( !main::_warm_endpoint('lazysite-probe-cold.pl'), '...not warm' );
    ok( !main::_warm_endpoint('lazysite-other.pl'), '...not declared' );
    ok( !main::_warm_endpoint('../lazysite-probe.pl'), '...not a script name' );

    spit( "$d/lazysite/lazysite.conf", "site_name: t\n" );
    ok( !main::_warm_endpoint('lazysite-probe.pl'), 'the extension off in the conf: not warm, whatever the index says' );
    ok( !Lazysite::Extensions::Hooks::warm_endpoint( "$d/lazysite", 'lazysite-probe.pl' ), '...for Hooks too' );
    spit( "$d/lazysite/lazysite.conf", "site_name: t\nextensions:\n  - extensions/probe.pl\n" );
};

subtest 'the parent is handed the declared list, and its socket is named for its endpoint' => sub {
    is( ( Lazysite::WarmFork::Wire::socket_for( '/s/lazysite', 'lazysite-odoo.pl' ) )[0], '/s/lazysite/run/odoo-endpoint.sock',
        'the Odoo endpoint keeps its socket' );
    is( ( Lazysite::WarmFork::Wire::socket_for( '/s/lazysite', '/srv/cgi-bin/lazysite-probe.pl' ) )[0],
        '/s/lazysite/run/probe-endpoint.sock', 'another is named for its own' );
    my ( $none, $why ) = Lazysite::WarmFork::Wire::socket_for( '/s/lazysite', 'evil.pl' );
    ok( !defined $none, 'a script that is not an endpoint names no socket' );
    like( $why, qr/no endpoint script/, '...saying so' );

    my $script = "$base/lazysite-probe.pl";
    spit( $script, "#!/usr/bin/perl\nsub main { return 0 }\n1;\n" );
    my $code = 'require Lazysite::WarmFork; my ( $l, $s, $e ) = Lazysite::WarmFork::preload( @ARGV ); '
        . 'die "preload: $e" if defined $e; print join( ",", ( grep { !/^Lazysite/ } @$l ), "|", @$s, "|", '
        . '( $INC{"List/Util.pm"} ? "loaded" : "not" ), ( $INC{"Bad/Name.pm"} ? "BAD" : "clean" ) )';
    my $root = repo_root();
    my $out  = qx{$^X -I$root/lib -e '$code' '$script' List::Util No::Such::Module 'Bad::Name; system(1)' 2>/dev/null};
    like( $out, qr/\AList::Util,\|/, 'a declared module is compiled' );
    like( $out, qr/\|.*No::Such::Module.*\|/, 'one that does not load is skipped' );
    like( $out, qr/loaded,clean\z/, '...the loaded one is in %INC, and a name that is not one is never required' );
};

subtest 'the Odoo extension declares its endpoint warm' => sub {
    my $root = repo_root();
    my $desc = JSON::PP::decode_json( scalar qx{$^X -I$root/lib $root/extensions/odoo.pl --describe} );
    my ($ep) = grep { $_->{script} eq 'lazysite-odoo.pl' } @{ $desc->{owns}{hooks}{endpoints} };
    is( $ep && $ep->{warm}, 1, 'warm' );
    ok( $ep && grep( { $_ eq 'Odoo::Ops::Client::Daemon' } @{ $ep->{preload} } ), 'with the OOM client in its preload' );
    is_deeply( [ sort map { $_->{name} } @{ $desc->{owns}{hooks}{services} } ], [qw(odoo-endpoint oomd)],
        'and its two services' );
};

done_testing;
