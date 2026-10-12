#!/usr/bin/perl
# csrf-audit (ruled 2026-10-11, "Audit refusals", with SM944 S34): A CSRF
# REFUSAL IS RECORDED IN THE AUDIT TRAIL as a denied request - one row per
# refused write, naming the action and the account, NEVER the token or any part
# of it.
#
# Before, a refused cross-site write against a signed-in manager left no audit
# line and, at the default log level, no log line either (SM944 § S34, "Found,
# not changed"): the operator could not see it had been tried. The other gates
# already recorded their refusals through the manager API's _refuse; the CSRF
# gate ended the request through _bail, which records nothing.
#
# Every way a write can fail the gate is sent - no token, a wrong token in the
# header, in the JSON body and in the query string, another account's valid
# token, last-but-one hour's token - each must write exactly one row, and the
# token sent must appear in neither the audit log nor the engine log, at the
# default level or at DEBUG. A write that passes the gate writes no denied row.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open3  qw(open3);
use File::Path  qw(make_path);
use File::Temp  ();
use TestHelper  qw(repo_root site_tempdir grant_caps);

my $root = repo_root();
my $mapi = "$root/lazysite-manager-api.pl";
plan skip_all => 'manager api missing' unless -f $mapi;
my $secret = 'e' x 64;
my $ERR    = File::Temp::tempdir( CLEANUP => 1 ) . '/stderr';

my $d = site_tempdir();
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; return scalar <$fh> }
make_path("$d/lazysite/auth");
spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\nmanager_groups: managers\n" );
spit( "$d/lazysite/auth/.secret", $secret );
{
    my $pid = open3( my $w, my $r, undef, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$w} encode_json( { action => 'add', username => 'admin', password => 'pw-admin-0123456789' } );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
}
grant_caps( $d, 'admin', 'manage_users', 'ui', 'manage_content' ); # SM1057: writes content in the manager
spit( "$d/page.md", "---\ntitle: Page\n---\nx\n" );

sub token_for { my ( $user, $hours_ago ) = @_; hmac_sha256_hex( "csrf:$user:" . ( int( time() / 3600 ) - ( $hours_ago // 0 ) ), $secret ) }

# A cookie session's POST of save, as the auth wrapper vouches for it.
sub post {
    my (%o) = @_;
    my $body = encode_json( { content => "---\ntitle: Page\n---\nchanged\n", %{ $o{body} || {} } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION HTTP_X_CSRF_TOKEN HTTP_COOKIE LAZYSITE_LOG_LEVEL)};
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = 'POST';
    $ENV{QUERY_STRING}          = 'action=save&path=page.md' . ( $o{query} // '' );
    $ENV{CONTENT_LENGTH}        = length $body;
    $ENV{HTTP_X_REMOTE_USER}    = 'admin';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{HTTP_X_CSRF_TOKEN}     = $o{header} if defined $o{header};
    $ENV{LAZYSITE_LOG_LEVEL}    = $o{level}  if defined $o{level};
    open my $err, '>', $ERR or die $!;
    my $pid = open3( my $w, my $r, '>&' . fileno($err), $^X, $mapi );
    print {$w} $body;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    close $err;
    my ($status) = $out =~ /^Status:\s*(\d+)/m;
    my ($jb)     = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $status // 200, eval { decode_json( $jb // '' ) } // {}, slurp($ERR) );
}

sub audit_rows { return grep { /\S/ } split /\n/, slurp("$d/lazysite/logs/audit.log") }

my $wrong = 'ab' x 32;    # a well-formed token that is nobody's
my @cases = (
    [ 'no token',                          {} ],
    [ 'a wrong token in the header',       { header => $wrong } ],
    [ 'a wrong token in the JSON body',    { body   => { csrf_token => $wrong } } ],
    [ 'a wrong token in the query string', { query  => "&csrf_token=$wrong" } ],
    [ "another account's valid token",     { header => token_for('someone') } ],
    [ 'a token two hours old',             { header => token_for( 'admin', 2 ) } ],
);

for my $level ( undef, 'DEBUG' ) {
    my $at = defined $level ? "at $level" : 'at the default level';
    for my $c (@cases) {
        my ( $label, $o ) = @$c;
        my $sent = $o->{header} // ( $o->{body} || {} )->{csrf_token} // ( ( $o->{query} // '' ) =~ /csrf_token=(\w+)/ )[0];
        my @before = audit_rows();
        my ( $st, $res, $stderr ) = post( %$o, level => $level );
        is( $st,                 403, "$label ($at): refused 403" );
        is( $res->{error} // '', 'Invalid or missing CSRF token', '...as a CSRF refusal' );
        my @after = audit_rows();
        my @new   = @after[ scalar(@before) .. $#after ];
        is( scalar @new, 1, '...and exactly one audit row is written' ) or diag join "\n", @new;
        my @f = map { s/^\s+|\s+$//gr } split /\|/, ( $new[0] // '' );
        is( $f[1] // '', 'admin',        '...naming the account' );
        is( $f[2] // '', 'save',         '...and the action' );
        is( $f[5] // '', 'fail',         '...as a failure' );
        is( $f[6] // '', 'ui',           '...from the manager' );
        is( $f[7] // '', 'denied: csrf', '...denied by the CSRF gate' );
        next unless defined $sent;
        my $part = substr( $sent, 0, 12 );
        unlike( slurp("$d/lazysite/logs/audit.log"), qr/\Q$part\E/, '...and no part of the token is in the audit log' );
        unlike( $stderr, qr/\Q$part\E/, '...or in the engine log' );
    }
}
like( slurp("$d/page.md"), qr/^x$/m, 'no refused write landed' );

# A write that passes the gate writes its own row, and no denied one.
my @before = audit_rows();
my ( $st, $res ) = post( header => token_for('admin') );
is( $st, 200, 'a write with a valid token is answered' ) or diag explain $res;
my @after = audit_rows();
my @new   = @after[ scalar(@before) .. $#after ];
is( scalar( grep { /denied: csrf/ } @new ), 0, '...and writes no denied row' );
ok( scalar( grep { /\| admin \| edit \| page\.md \|.*\| ok \|/ } @new ), '...but its own ok row (a save is audited as an edit)' ) or diag join "\n", @new;

done_testing();
