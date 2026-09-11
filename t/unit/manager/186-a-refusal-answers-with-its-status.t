#!/usr/bin/perl
# SM670: a control-API refusal says so in its HTTP status as well as its body.
#
# Every refusal answered 200 with ok:false. A client that checks the status line
# before parsing - the idiomatic shape in every language - saw success, parsed a
# body it did not expect, and reported something else. Ruled 2026-09-11: the
# status follows the refusal's kind, a refusal with no kind is 400, `partial`
# (part of the write happened) is 207, and ok:false stays in every body, so the
# two registers agree. Pre-stable, without a deprecation step.
#
# Reproduced before the fix: every refusal below answered 200.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                qw(repo_root grant_caps site_tempdir);
use Lazysite::Manager::Common ();

my $root = repo_root();

# --- the writer, for every class of kind --------------------------------------
sub status_of {
    my ($data) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    Lazysite::Manager::Common::respond($data);
    select $old;
    close $fh;
    my ($s) = $out =~ /\AStatus: (\d{3})/;
    my ($b) = $out =~ /\r\n\r\n(.*)\z/s;
    return ( $s, decode_json($b) );
}

for my $case (
    [ { ok => 1 }, 200, 'a success' ],
    [ { ok => 0, kind => 'forbidden', error => 'x' }, 403, 'a capability refusal' ],
    [ { ok => 0, kind => 'not-found', error => 'x' }, 404, 'something that is not there' ],
    [ { ok => 0, kind => 'exists', error => 'x' }, 409, 'a conflict with what exists' ],
    [ { ok => 0, kind => 'too-large',     error => 'x' }, 413, 'too large' ],
    [ { ok => 0, kind => 'rate',          error => 'x' }, 429, 'rate-limited' ],
    [ { ok => 0, kind => 'partial',       error => 'x' }, 207, 'half a write (SM650)' ],
    [ { ok => 0, kind => 'render-failed', error => 'x' }, 500, 'a failure on the server' ],
    [ { ok => 0, kind => 'invalid',       error => 'x' }, 400, 'an invalid request' ],
    [ { ok => 0, kind => 'no-such-kind',  error => 'x' }, 400, 'a kind nobody mapped' ],
    [ { ok => 0, error => 'x' }, 400, 'a refusal with no kind' ],
    )
{
    my ( $data, $want, $what ) = @$case;
    my ( $got, $body ) = status_of( {%$data} );
    is( $got, $want, "$what answers $want" );
    is( ( $body->{ok} ? 1 : 0 ), ( $data->{ok} ? 1 : 0 ), '  and the body still says ok' . ( $data->{ok} ? ':true' : ':false' ) );
}

# --- the real CGI ---------------------------------------------------------------
my $secret = 'sekret' x 6;
my $d      = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
for ( [ "$d/lazysite/lazysite.conf", "site_name: T\n" ], [ "$d/lazysite/auth/.secret", $secret ] ) {
    open my $fh, '>', $_->[0] or die $!;
    print {$fh} $_->[1];
    close $fh;
}
{
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json( { action => 'add', username => 'op', password => 'x' } );
    close $i;
    local $/;
    <$o>;
    close $o;
    waitpid $pid, 0;
}
grant_caps( $d, 'op', 'manage_nav' );

sub api {
    my ($qs) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_GROUPS CONTENT_LENGTH)};
    @ENV{qw(DOCUMENT_ROOT REQUEST_METHOD QUERY_STRING HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)}
        = ( $d, 'GET', $qs, 'op', 'role-op', 1 );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($s) = $out =~ /\AStatus: (\d{3})/;
    my ($b) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $s, eval { decode_json( $b // '' ) } || {} );
}

my ( $s1, $b1 ) = api('action=nav-read');
is( $s1, 200, 'through the CGI: an allowed read answers 200' ) or diag explain $b1;
my ( $s2, $b2 ) = api('action=audit');
is( $s2, 403, 'an action this grant does not hold answers 403' ) or diag explain $b2;
ok( !$b2->{ok}, 'with ok:false in the body, as before' );
my ( $s3, $b3 ) = api('action=no-such-action');
is( $s3, 404, 'an action that does not exist answers 404' ) or diag explain $b3;

done_testing();
