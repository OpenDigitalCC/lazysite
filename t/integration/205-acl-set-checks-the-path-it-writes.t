#!/usr/bin/perl
# SM1047 (P-9): acl-set's scope check is made against the path it writes.
#
# The path could arrive in the query string or in the JSON body, and the action
# reference said so (`query_or_body`). The scope check read only the query, where
# the path defaults to '/', and the handler refused a body path outright - so a
# confined partner that sent its path in the body, as the reference told it to,
# was told "Path '/' is outside your assigned scope" about a path it never sent.
#
# The dangerous direction is a query path inside the scope and a body path
# outside it: whichever one the check reads, the handler must write THAT one.
# This file is the probe as assertions, for a domain-confined token and a
# domain-confined cookie manager:
#
#   body path only, inside the scope      -> served, the rule is on that path
#   body path only, outside the scope     -> refused for scope, naming that path
#   query in scope, body out of scope     -> refused, nothing written anywhere
#   query out of scope, body in scope     -> refused, nothing written anywhere
#   query and body agree                  -> served
#   body path that is not one string      -> refused as invalid
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(api ui webdav manage_domains manage_users manage_content);
my %CAPS = (
    op  => [qw(ui manage_domains manage_users manage_content)],
    cks => [qw(ui manage_content)],
    tks => [qw(api manage_content)],
);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other" );
spit( "$d/sites/$_/page.md", "# $_\n" ) for qw(mine other);
spit( "$d/index.md",         "# primary\n" );
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my $TOKEN = uapi( { action => 'token', username => 'tks' } )->{token} // '';
ok( length $TOKEN, 'set up: a token for the confined partner' );

# A token request, or a cookie request through the harness.
sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    if ( $who ne 'tks' ) {
        return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query );
    }
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "tks:$TOKEN", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-cks, g-tks' } ],
    )
{
    my $r = api( 'op', @$set );
    ok( $r->{ok}, "set up: $set->[0] $set->[1]{host}" ) or diag( $r->{error} // '' );
}

sub acls {
    open my $fh, '<', "$d/lazysite/auth/acls.json" or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) };
    return ref $j eq 'HASH' ? $j : {};
}
sub reset_acls { unlink "$d/lazysite/auth/acls.json"; return }

my $IN  = 'sites/mine/page.md';
my $OUT = 'sites/other/page.md';
sub q_for { return 'action=acl-set&path=' . $_[0] }

for my $who (qw(tks cks)) {
    subtest "acl-set as $who, confined to sites/mine" => sub {
        reset_acls();
        my $r = api( $who, 'acl-set', { path => $IN, write => [$who] } );
        ok( $r->{ok}, 'a body path inside the scope is served' ) or diag( $r->{error} // $r->{_raw} // '' );
        ok( acls()->{$IN}, '...and the rule is on that path' );
        unlike( $r->{error} // '', qr{Path '/' is outside}, '...and the scope check never sees a path nobody sent' );

        reset_acls();
        $r = api( $who, 'acl-set', { path => $OUT, write => [$who] } );
        ok( !$r->{ok}, 'a body path outside the scope is refused' );
        like( $r->{error} // '', qr{Path '\Q$OUT\E' is outside your assigned scope}, '...for scope, naming the path it was sent' );
        is_deeply( acls(), {}, '...and nothing is written' );

        reset_acls();
        $r = api( $who, 'acl-set', { path => $OUT, write => [$who] }, q_for($IN) );
        ok( !$r->{ok}, 'query in scope, body out of scope: refused' );
        is( $r->{kind} // '', 'conflict', '...as two paths that disagree' );
        is_deeply( acls(), {}, '...and nothing is written at either path' );

        reset_acls();
        $r = api( $who, 'acl-set', { path => $IN, write => [$who] }, q_for($OUT) );
        ok( !$r->{ok}, 'query out of scope, body in scope: refused' );
        is_deeply( acls(), {}, '...and nothing is written at either path' );

        reset_acls();
        $r = api( $who, 'acl-set', { path => $IN, write => [$who] }, q_for($IN) );
        ok( $r->{ok},      'query and body agree: served' ) or diag( $r->{error} // '' );
        ok( acls()->{$IN}, '...on that path' );

        reset_acls();
        $r = api( $who, 'acl-set', { path => [ $IN, $OUT ], write => [$who] } );
        ok( !$r->{ok}, 'a body path that is not one string is refused' );
        is_deeply( acls(), {}, '...and nothing is written' );
    };
}

done_testing;
