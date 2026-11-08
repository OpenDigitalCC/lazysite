#!/usr/bin/perl
# SM1369 X6, H-8 (ruling 188): AN EXTENSION'S PANEL IS A MANAGER PAGE IT SHIPS.
#
# `hooks.panels` - { page, label, cap } - names a page in the extension's
# payload (manager/<name>.md). Through a real index and the real processor, as
# a child, with the identity a trusted proxy gives:
#
#   * the page is served at /manager/<id>-<name>, from the payload, in the
#     manager's frame, to a manager who holds its capability;
#   * a manager who does not hold it is refused 403; a visitor is sent to sign
#     in, as for any manager page;
#   * with the extension off in the conf, or a name it does not declare, there
#     is no such page (G-1);
#   * a panel's capability must be one the extension owns, and its page a file in
#     the payload, or the declaration is refused at the build.
#
# Sabotage: make _extension_page_refused answer 0 and the manager without the
# capability is served the page - this fails.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir index_extensions run_processor);
use Lazysite::Extensions::Hooks ();
use Lazysite::Extensions::Owns  ();

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

my $CONF = "site_name: T\nlayout: default\nmanager: enabled\nauth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n";

my $d    = site_tempdir();
my $base = dirname($d);
make_path( "$d/lazysite/layouts/default", "$d/lazysite/auth", "$base/extensions/probe/manager" );
spit( "$d/lazysite/layouts/default/layout.tt", '<html><body>[% content %]</body></html>' );
spit( "$d/lazysite/auth/groups-settings.json",
    '{"admins":{"label":"Admins","ui":1,"probe_cap":1,"directory_grants":1},"clerks":{"label":"Clerks","ui":1,"directory_grants":1}}' );
write_extension( "$base/extensions/probe.pl", {
        id => 'probe', name => 'Probe', contract => 1,
        owns => { capabilities => ['probe_cap'],
            hooks => {
                capability_info => { probe_cap => { section => 'Site', label => 'Probe board', title => 'Read the probe board.',
                        grants => 'Read the probe board.', unlocks => { ui => ['the Probe board page'] } } },
                panels => [ { page => 'board.md', label => 'Probe board', cap => 'probe_cap' } ] } } } );
spit( "$base/extensions/probe/manager/board.md",
    "---\ntitle: Probe board\nauth: manager\nsearch: false\n---\n\n<div id=\"probe-board\">PROBE-BOARD-BODY</div>\n" );
spit( "$d/lazysite/lazysite.conf", $CONF . "extensions:\n  - extensions/probe.pl\n" );
my $r = index_extensions($d);
ok( $r->{ok} && grep( { $_ eq 'probe' } @{ $r->{indexed} } ), 'the panel is indexed' ) or diag explain $r;
is( Lazysite::Extensions::Hooks::read_index("$d/lazysite")->{extensions}{probe}{payload}, "$base/extensions/probe",
    'with its payload' );

my %alice = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
my %bob   = ( HTTP_X_REMOTE_USER => 'bob',   HTTP_X_REMOTE_GROUPS => 'clerks' );
sub status_of { my ($o) = @_; my ($s) = $o =~ /Status:\s*(\d+)/; return $s // 200 }

subtest 'a manager who holds its capability is served the page' => sub {
    my $out = run_processor( $d, '/manager/probe-board', %alice );
    is( status_of($out), 200, 'answered 200' ) or diag( substr( $out, 0, 400 ) );
    like( $out, qr/PROBE-BOARD-BODY/, 'the payload\'s page' );
    like( $out, qr/<title>[^<]*Probe board/, 'with its title' ) if $out =~ /<title>/;
};

subtest 'a manager who does not, and a visitor, are not' => sub {
    is( status_of( run_processor( $d, '/manager/probe-board', %bob ) ), 403, 'without the capability: 403' );
    unlike( run_processor( $d, '/manager/probe-board', %bob ), qr/PROBE-BOARD-BODY/, '...and nothing of it' );
    my $out = run_processor( $d, '/manager/probe-board' );
    like( status_of($out), qr/\A30[23]\z/, 'a visitor is sent to sign in' );
    unlike( $out, qr/PROBE-BOARD-BODY/, '...and shown nothing of it' );
};

subtest 'off, or not declared: no such page' => sub {
    is( status_of( run_processor( $d, '/manager/probe-other', %alice ) ), 404, 'a name it does not declare: 404' );
    spit( "$d/lazysite/lazysite.conf", $CONF );
    my $out = run_processor( $d, '/manager/probe-board', %alice );
    is( status_of($out), 404, 'the extension off in the conf: 404, whatever the index says' );
    unlike( $out, qr/PROBE-BOARD-BODY/, '...and nothing of it' );
    spit( "$d/lazysite/lazysite.conf", $CONF . "extensions:\n  - extensions/probe.pl\n" );
};

subtest 'the declaration is checked' => sub {
    my @bad = map { $_->{error} } Lazysite::Extensions::Owns::validate_owns( 'probe',
        { capabilities => ['probe_cap'], hooks => { panels => [ { page => 'b.md', label => 'B', cap => 'manage_users' } ] } } );
    ok( ( grep {/'manage_users' is not one of this extension's capabilities/} @bad ), 'a capability it does not own' )
        or diag explain \@bad;
    @bad = map { $_->{error} } Lazysite::Extensions::Hooks::validate_hooks( 'probe',
        { panels => [ { page => '../x.md', label => 'B', cap => 'probe_cap' } ] } );
    ok( ( grep {/page must be a page's file name/} @bad ), 'a path is not a page' ) or diag explain \@bad;
    my ( undef, @why ) = Lazysite::Extensions::Hooks::check_payload_files( 'probe', "$base/extensions/probe.pl",
        { panels => [ { page => 'absent.md', label => 'A', cap => 'probe_cap' } ] } );
    like( ( $why[0] || {} )->{error} // '', qr/manager page manager\/absent\.md is not a file/, 'a page not in the payload' );
};

done_testing;
