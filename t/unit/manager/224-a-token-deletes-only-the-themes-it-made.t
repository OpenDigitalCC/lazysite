#!/usr/bin/perl
# SM262, pinned by SM944 S33 (held branch (3), approved 2026-10-11): a token
# client may delete only a theme it created; a cookie session - a human at the
# manager - keeps the unrestricted delete, unless it is domain-confined (SM976
# R1, t/integration/114).
#
# theme-delete told the two apart by a flag, $RESTRICT_THEME_DELETE, set at the
# end of the token branch's gates; it now reads $token_auth, Manager::Common's
# request fact, proven equal to the flag at that point (tmp/sm944-n348-equiv.sh,
# .out). Nothing pinned either answer: a token treated as a human, or a human
# as a token, passed every test (tmp/sm944-n348-sab.out). This test drives both
# through real requests.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui manage_users manage_themes manage_layouts);
my $s = new_site( root => $root, conf => "control_api_enabled: true\nlayout: base\ntheme: one\n" );
my $d = $s->docroot;
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
make_path("$d/lazysite/layouts/base/themes");
spit( "$d/lazysite/layouts/base/layout.tt", "<html>[% content %]</html>\n" );
for my $t (qw(one first second)) {
    make_path("$d/lazysite/layouts/base/themes/$t");
    spit( "$d/lazysite/layouts/base/themes/$t/theme.json",
        qq({"name":"$t","version":"1.0.0","layouts":["base"],"config":{}}) );
}
$s->add_user( 'tok', 'pw-tok-0123456789' );
$s->grant( 'tok', 'g-tok', [qw(api manage_themes)], \@ALL );
$s->add_user('human');
$s->grant( 'human', 'g-human', [qw(ui manage_themes)], \@ALL );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $tok = uapi( { action => 'token', username => 'tok' } )->{token} // '';
ok( length $tok, 'setup: the token client has a credential' );

sub token_call {
    my ($query) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "tok:$tok", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = 2;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => '{}' )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $t = token_call('action=theme-delete&path=first');
ok( !$t->{ok}, 'a token client may not delete a theme it did not create' ) or diag explain $t;
is( $t->{kind} // '', 'not-yours', '...for that reason' );
ok( -d "$d/lazysite/layouts/base/themes/first", '...and the theme is still there' );

my $h = $s->call( 'human', 'theme-delete', body => {}, query => 'action=theme-delete&path=second' );
ok( $h->{ok}, 'a cookie manager bound to no domain deletes it' ) or diag explain $h;
ok( !-d "$d/lazysite/layouts/base/themes/second", '...and it is gone' );

done_testing();
