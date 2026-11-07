#!/usr/bin/perl
# SM1369 X7, part one (ruling 135): A SITE USING ODOO KEEPS IT ACROSS THE MOVE.
#
# The proposal's upgrade journey test, as far as it runs without a real Odoo. Odoo's
# modules left core's lib/ for the extension's payload lib (extensions/odoo/lib),
# and the release still ships them in the same package and install. A site as the
# last release left it - provisioned by the real install.pl, then turned into the
# old layout: Odoo's modules under {DOCROOT}/../lib/Lazysite, the install state
# recording them there, no payload directory - with Odoo enabled, the site sign-in
# on, a public page binding, a page reading it, a protected page, and a person
# signed in through Odoo, is upgraded IN PLACE by the real install.pl. Then, with
# the INSTALLED code only (the site's lib, cgi-bin and extensions; OOM's test
# double for Odoo, injected - nothing reaches a real Odoo):
#
#   - the old copies are gone from core's lib and the payload is laid out beside
#     the descriptor, recorded in the install state, the hook index step clean;
#   - the person is still signed in: the protected page is served through the
#     installed wrapper and processor, on the cookie minted before the upgrade;
#   - the binding answers: through the installed Odoo endpoint (the visitor token,
#     then the call), and on the page that reads it through the processor;
#   - the installed core reaches Odoo's modules in the site's payload lib;
#   - a second upgrade changes none of it.
#
# Not run here (they need more than a fixture can stand up): oomd and the pooled
# warm endpoint, and a scheduled binding's timer. Their names, socket and paths
# are unchanged by the move (t/lint/321, t/unit/daemon).
#
# Sabotage: take the extensions/<id>/lib rule out of classification.json and the
# payload is never installed - the binding and the page fail, and so does the
# layout check.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use File::Copy qw(move);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper    qw(repo_manifest_guard repo_root grant_caps run_child env_passthrough);
use PreRenameSite qw(new_site install slurp spit);
use OdooTest      qw(oom_or_skip bind write_conf set_key oom_lib oom_test_lib);

BEGIN { oom_or_skip() }
use Lazysite::Auth::Session ();

my $MF_GUARD = repo_manifest_guard();
my $REPO     = repo_root();

my ( $docroot, $cgibin, $root ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;
my $LZ = "$docroot/lazysite";
ok( -f "$root/extensions/odoo/lib/Lazysite/Odoo.pm", 'this release installs Odoo\'s modules in its payload lib' );
ok( !-e "$root/lib/Lazysite/Odoo.pm", '...and none in core\'s lib' );

# ---- the site uses Odoo ----
{
    my $conf = slurp("$LZ/lazysite.conf");
    $conf =~ s/^extensions:\s*\n/extensions:\n  - extensions\/odoo.pl\n/m or $conf .= "extensions:\n  - extensions/odoo.pl\n";
    $conf =~ s/^update_channel:.*\n//mg;
    spit( "$LZ/lazysite.conf", $conf . "update_channel: all\nauth_redirect: /login\n" );
}
write_conf( $docroot, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
    odoo_allow_writes => 'true', odoo_packs => OdooTest::shop_namespace(), odoo_site_signin => 'on',
    odoo_group_map => 'base.group_user = staff' );
make_path("$LZ/auth");
spit( "$LZ/auth/.secret", ( 'b' x 64 ) . "\n" ) unless -s "$LZ/auth/.secret";
grant_caps( $docroot, 'boss', 'ui' );    # a secured site: Odoo makes nobody on an unsecured one
set_key($docroot);
# SM1369 X3: the binding's type is a hook the extension declares, so the site is
# indexed before a binding is saved - here from the checkout's descriptor (the
# dev server's directory rule, as every in-process test does), and by the real
# upgrade below from the installed one, which is what the installed code reads.
OdooTest::build_hook_index($docroot);
bind( $docroot, id => 'list', operation => 'shop.products', modes => 'public' );
spit( "$docroot/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS-AREA\n" );
spit( "$docroot/shop.md", "---\ntitle: Shop\ntt_page_var:\n  shop: odoo:list\n---\nSHOP-ROWS=[% shop.rows.size %]\n" );

my $cookie;
{
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    ($cookie) = Lazysite::Auth::Session::mint_odoo_session( login => 'jane@example.com', name => 'Jane', groups => ['staff'] );
}
ok( $cookie, 'a person is signed in through Odoo' );

# ---- the last release's layout ----
# From here the installed tree is the only one: the children below find the
# installed descriptor beside the docroot, as a deployed site does.
delete $ENV{LAZYSITE_DEV_SERVER};
delete $ENV{LAZYSITE_EXTENSION_DIRS};
my @MOVED = qw(Lazysite/Odoo.pm Lazysite/Odoo Lazysite/Daemon/Service/Oomd.pm Lazysite/Daemon/Service/OdooEndpoint.pm);
for my $m (@MOVED) {
    move( "$root/extensions/odoo/lib/$m", "$root/lib/$m" ) or die "move $m: $!";
}
remove_tree("$root/extensions/odoo");
{
    my $sp    = "$LZ/.install-state.json";
    my $state = decode_json( slurp($sp) );
    my %files;
    for my $k ( keys %{ $state->{files} } ) {
        ( my $o = $k ) =~ s{/extensions/odoo/lib/}{/lib/};
        $files{$o} = $state->{files}{$k};
    }
    $state->{files}   = \%files;
    $state->{version} = '0.16.2';    # below every VERSION this branch can carry, so it is an upgrade
    spit( $sp, JSON::PP->new->canonical->pretty->encode($state) );
}
ok( -f "$root/lib/Lazysite/Odoo.pm" && !-e "$root/extensions/odoo", 'the site is in the old layout' );

# ---- the upgrade, in place ----
( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
is( $rc, 0, 'the upgrade succeeds' ) or diag $out;
unlike( $out, qr/HOOKS:/, 'the hook index step ran clean' );
my @left = grep { -e "$root/lib/$_" } @MOVED;
is_deeply( \@left, [], 'Odoo\'s modules are gone from core\'s lib' );
ok( -f "$root/extensions/odoo/lib/Lazysite/$_", "$_ is in the payload lib" )
    for qw(Odoo.pm Odoo/SiteSignin.pm Odoo/Session.pm Daemon/Service/Oomd.pm Daemon/Service/OdooEndpoint.pm);
is( sprintf( '%04o', ( stat "$root/extensions/odoo/lib" )[2] & 07777 ), '0755', 'the payload lib is code, 0755' );
my $state = decode_json( slurp("$LZ/.install-state.json") );
ok( $state->{files}{"$root/extensions/odoo/lib/Lazysite/Odoo.pm"}, 'the install state records the new place' );
ok( !$state->{files}{"$root/lib/Lazysite/Odoo.pm"},                 '...and not the old one' );

# ---- the installed code, and nothing else ----
my %CHILD = (
    PERL5LIB  => "$REPO/t/lib",    # OdooInject, OOM's test double; never the engine's lib
    PERL5OPT  => '-MOdooInject',
    ODOO_OOM_PACK_DIRS => $ENV{ODOO_OOM_PACK_DIRS}, ODOO_OOM_SHARE => $ENV{ODOO_OOM_SHARE} // '',
);

sub page {
    my ( $uri, $c ) = @_;
    local %ENV = (
        env_passthrough(), %CHILD, DOCUMENT_ROOT => $docroot, REDIRECT_URL => $uri, REQUEST_METHOD => 'GET',
        QUERY_STRING => '', REMOTE_ADDR => '198.51.100.20', HTTPS => '', HTTP_HOST => 'localhost',
        LAZYSITE_PROCESSOR => "$cgibin/lazysite-processor.pl", ( defined $c ? ( HTTP_COOKIE => $c ) : () ),
    );
    my $r = run_child( [ $^X, "$cgibin/lazysite-auth.pl" ] );
    return ( $r->{out} // '' ) . ( $r->{err} // '' );
}

sub endpoint {
    my ( $method, $query, $body, $c ) = @_;
    my $json = defined $body ? encode_json($body) : '';
    local %ENV = (
        env_passthrough(), %CHILD, DOCUMENT_ROOT => $docroot, REQUEST_METHOD => $method, QUERY_STRING => $query,
        SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', REMOTE_ADDR => '198.51.100.21', HTTP_HOST => 'localhost',
        CONTENT_LENGTH => length $json, CONTENT_TYPE => 'application/json', ( defined $c ? ( HTTP_COOKIE => $c ) : () ),
    );
    my $r = run_child( [ $^X, "$cgibin/lazysite-odoo.pl" ], stdin => $json );
    my ( $head, $payload ) = split /\r?\n\r?\n/, $r->{out} // '', 2;
    return ( $head // '', ( eval { decode_json( $payload // '' ) } || {} ), ( $r->{out} // '' ) . ( $r->{err} // '' ) );
}

sub journey {
    my ($when) = @_;
    like( page( '/members', "lazysite_auth=$cookie; lzs_session=1" ), qr/MEMBERS-AREA/,
        "$when: the person signed in before the upgrade is still signed in" );
    unlike( page('/members'), qr/MEMBERS-AREA/, "$when: ...and the page is refused to nobody else" );

    my ( $h1, $t, $raw1 ) = endpoint( 'GET', 'csrf=1', undef );
    ok( $t->{visitor_token}, "$when: the installed Odoo endpoint answers ?csrf=1" ) or diag $raw1;
    my ($visitor) = $h1 =~ /^Set-Cookie:\s*(lzs_odoo_visitor=[^;]+)/mi;
    my ( undef, $call, $raw2 ) = endpoint( 'POST', 'binding=list',
        { binding => 'list', visitor_token => $t->{visitor_token} }, $visitor );
    ok( $call->{ok} && ref $call->{report} eq 'HASH' && @{ $call->{report}{rows} || [] },
        "$when: the binding answers, with rows" ) or diag $raw2;

    like( page('/shop'), qr/SHOP-ROWS=[1-9]/, "$when: the page reading the binding renders its rows" );

    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $r = run_child( [ $^X, "-I$root/lib", '-e',
            'use Lazysite::Extensions; Lazysite::Extensions::require_payload("Lazysite::Odoo"); print $INC{"Lazysite/Odoo.pm"}' ] );
    is( $r->{out}, "$root/extensions/odoo/lib/Lazysite/Odoo.pm", "$when: the installed core reaches Odoo in the site's payload lib" )
        or diag $r->{err};
}

journey('after the upgrade');

( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'a second run succeeds' ) or diag $out;
ok( !-e "$root/lib/Lazysite/Odoo.pm" && -f "$root/extensions/odoo/lib/Lazysite/Odoo.pm", '...and changes the layout no further' );
journey('after a second run');

done_testing();
