#!/usr/bin/perl
# SM071 Phase 3: per-object authorisation for lazysite/layouts/** over DAV.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_dav setup_dav_site dav_users_tool grant_caps revoke_caps);

my $s    = setup_dav_site(
    conf => "webdav_enabled: true\nlayout: base\ntheme: live\n" );
my $doc  = $s->{docroot};
my $auth = $s->{auth};

make_path("$doc/lazysite/layouts/base/themes/live");
make_path("$doc/lazysite/layouts/base/themes/candidate");
make_path("$doc/lazysite/layouts/alt");
for my $L (qw(base alt)) {
    open my $f, '>', "$doc/lazysite/layouts/$L/layout.tt" or die $!;
    print $f "x"; close $f;
}
for my $T (qw(live candidate)) {
    open my $f, '>', "$doc/lazysite/layouts/base/themes/$T/theme.json" or die $!;
    print $f '{}'; close $f;
}

grant_caps( $doc, 'deploy', 'manage_themes' );
grant_caps( $doc, 'deploy', 'manage_layouts' );

sub req {
    my ( $m, $p, %opt ) = @_;
    return run_dav( $doc, $m, $p, HTTP_AUTHORIZATION => $auth, %opt );
}
sub put_ok { my $c = shift; $c == 201 || $c == 204 }

# --- themes: active read-only, inactive writable ----------------------
is( req('PROPFIND', '/lazysite/layouts/base/themes/live', HTTP_DEPTH => '0')->{code},
    207, 'read active theme allowed' );
is( req('PUT', '/lazysite/layouts/base/themes/live/s.css', body => 'x')->{code},
    403, 'write active theme denied' );
ok( put_ok( req('PUT', '/lazysite/layouts/base/themes/candidate/s.css', body => 'x')->{code} ),
    'write inactive theme allowed' );

# --- layouts: active read-only, inactive writable ---------------------
is( req('PUT', '/lazysite/layouts/base/layout.tt', body => 'x')->{code},
    403, 'write active layout denied' );
ok( put_ok( req('PUT', '/lazysite/layouts/alt/layout.tt', body => 'x')->{code} ),
    'write inactive layout allowed' );

# --- rest of lazysite/ stays denied -----------------------------------
is( req('PROPFIND', '/lazysite/auth', HTTP_DEPTH => '0')->{code},
    403, 'rest of lazysite/ still denied' );

# --- capability gating -------------------------------------------------
revoke_caps( $doc, 'deploy', 'manage_themes' );
is( req('PROPFIND', '/lazysite/layouts/base/themes/candidate', HTTP_DEPTH => '0')->{code},
    403, 'no manage_themes -> theme access denied' );
is( req('PROPFIND', '/lazysite/layouts/alt', HTTP_DEPTH => '0')->{code},
    207, 'manage_layouts still allows layout read' );
grant_caps( $doc, 'deploy', 'manage_themes' );

# --- dav_scope is orthogonal to theme/layout access -------------------
dav_users_tool( $doc, 'set', 'deploy', 'dav_scope', '/content' );
is( req('PROPFIND', '/lazysite/layouts/base/themes/live', HTTP_DEPTH => '0')->{code},
    207, 'dav_scope (content) does not gate theme access' );

done_testing();
