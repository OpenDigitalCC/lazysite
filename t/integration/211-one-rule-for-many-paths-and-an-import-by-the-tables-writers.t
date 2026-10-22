#!/usr/bin/perl
# SM1052 (inbox 2026-10-12, P-6, P-7), ruled 2026-10-12: "acl-set with a path
# list, Import respects writable_by, Owner bypass on import".
#
# (a) acl-set takes `paths`, a list, with one rule: each path is scope-checked
#     (SM1047's resolution covers the list), one audit row per path, and all or
#     nothing - every path validated first, none written if any is refused.
# (b) data-import is a row write: an account the table's writable_by names
#     imports; one it does not name is refused, manage_data or not.
# (c) the table's owner - the owner of its access rule (data-table-acl-set) -
#     imports past writable_by.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
plan skip_all => 'DBI / DBD::SQLite / YAML::PP not available'
    unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api manage_users manage_domains manage_content manage_data);
my %CAPS = (
    op  => [qw(ui manage_users manage_domains manage_content manage_data)],
    tks => [qw(api manage_content)],
    ed  => [qw(ui manage_data)],
    wr  => [qw(ui manage_data)],
    own => [qw(ui manage_data manage_content)],
);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nextensions:\n  - plugins/data.pl\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other", "$d/lazysite/db/tables" );
spit( "$d/sites/mine/$_.md", "# $_\n" ) for qw(a b c d);
spit( "$d/sites/other/x.md", "# x\n" );
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
$s->users( 'group-add', 'wr', 'writers' );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $TOKEN = uapi( { action => 'token', username => 'tks' } )->{token} // '';

# A request: a token by Basic auth, a cookie caller as ManagerSession does;
# $o{raw}/$o{ctype} send a body other than JSON (the CSV upload).
sub api {
    my ( $who, $action, $body, $query, %o ) = @_;
    my $raw = $o{raw} // ( defined $body ? encode_json($body) : undef );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL CONTENT_TYPE)};
    if ( $who eq 'tks' ) { $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "tks:$TOKEN", '' ) }
    else {
        $ENV{HTTP_X_REMOTE_USER}    = $who;
        $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
        $ENV{LAZYSITE_USERS_TOOL}   = $s->{users};
        $ENV{HTTP_COOKIE}           = $s->cookie_for($who);
        $ENV{HTTP_X_CSRF_TOKEN}     = $s->csrf_for($who);
    }
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{QUERY_STRING}   = $query // "action=$action";
    $ENV{REQUEST_METHOD} = defined $raw ? 'POST'      : 'GET';
    $ENV{CONTENT_LENGTH} = defined $raw ? length $raw : 0;
    $ENV{CONTENT_TYPE}   = $o{ctype} if $o{ctype};
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => ( $raw // '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-tks' } ],
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
sub audit_rows {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    return grep { /\tacl-set\t|"acl-set"|acl-set/ } <$fh>;
}

subtest '(a) one rule for a list of paths' => sub {
    my $before = () = audit_rows();
    my $r = api( 'tks', 'acl-set', { paths => [ 'sites/mine/a.md', 'sites/mine/b.md' ], write => ['tks'] } );
    ok( $r->{ok}, 'two paths in its scope: served' ) or diag( $r->{error} // $r->{_raw} // '' );
    is( $r->{paths}, 2, '...both' );
    ok( acls()->{'sites/mine/a.md'} && acls()->{'sites/mine/b.md'}, '...each has the rule' );
    my @rows = audit_rows();
    my @new  = @rows[ $before .. $#rows ];
    is( scalar( grep { /sites\/mine\/a\.md/ } @new ), 1, 'one audit row for the first path' );
    is( scalar( grep { /sites\/mine\/b\.md/ } @new ), 1, '...and one for the second' );

    $r = api( 'tks', 'acl-set', { paths => [ 'sites/mine/c.md', 'sites/other/x.md' ], write => ['tks'] } );
    ok( !$r->{ok}, 'one path outside the scope: refused' );
    like( $r->{error} // '', qr{sites/other/x\.md' is outside your assigned scope}, '...naming it' );
    ok( !acls()->{'sites/mine/c.md'}, '...and the path inside it was not written either' );

    ok( api( 'op', 'acl-set', { write => ['op'] }, 'action=acl-set&path=sites/mine/c.md' )->{ok},
        'set up: the operator owns a rule on c.md' );
    $r = api( 'tks', 'acl-set', { paths => [ 'sites/mine/d.md', 'sites/mine/c.md' ], write => ['tks'] } );
    ok( !$r->{ok}, 'a path whose rule another account owns: refused' );
    is( $r->{kind}, 'refused', '...as refused' );
    is_deeply( [ map { $_->{path} } @{ $r->{refused} || [] } ], ['sites/mine/c.md'], '...naming that path' );
    ok( !acls()->{'sites/mine/d.md'}, '...and nothing was written (all or nothing)' );
    is( acls()->{'sites/mine/c.md'}{owner}, 'op', "...the other account's rule unchanged" );

    $r = api( 'tks', 'acl-set', { paths => ['sites/mine/d.md'], path => 'sites/mine/d.md', write => ['tks'] } );
    is( $r->{kind} // '', 'conflict', 'a path and a list: conflict' );
    $r = api( 'tks', 'acl-set', { paths => 'sites/mine/d.md', write => ['tks'] } );
    is( $r->{kind} // '', 'invalid', 'a list that is not a list: invalid' );
    $r = api( 'tks', 'acl-set', { paths => [], write => ['tks'] } );
    is( $r->{kind} // '', 'invalid', 'an empty list: invalid' );
    ok( !acls()->{'sites/mine/d.md'}, 'none of them wrote anything' );
};

# --- (b), (c): the import ------------------------------------------------------
spit( "$d/lazysite/db/tables/posts.yaml",
    "title: Posts\nkey: slug\nwritable_by: [writers]\nfields:\n  slug:\n    type: text\n  title:\n    type: text\n" );
ok( api( 'op', 'data-migrate', {}, 'action=data-migrate&table=posts' )->{ok}, 'set up: the posts table' );
my $desc_before = do { open my $fh, '<', "$d/lazysite/db/tables/posts.yaml" or die $!; local $/; <$fh> };

sub import_csv {
    my ( $who, $csv ) = @_;
    my $b = 'XyZ' . int( rand 1e9 );
    my $raw = "--$b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"p.csv\"\r\n"
        . "Content-Type: text/csv\r\n\r\n$csv\r\n--$b--\r\n";
    return api( $who, 'data-import', undef, 'action=data-import&table=posts&apply=1',
        raw => $raw, ctype => "multipart/form-data; boundary=$b" );
}
sub rows {
    my $r = api( 'op', 'data-rows', undef, 'action=data-rows&table=posts' );
    return join ',', sort map { $_->{slug} } @{ $r->{rows} || [] };
}

subtest '(b) an import is made by the accounts writable_by names' => sub {
    my $r = import_csv( 'ed', "slug,title\ned1,One\n" );
    ok( !$r->{ok}, 'manage_data, not in writable_by: refused' );
    is( $r->{kind}    // '', 'forbidden', '...forbidden' );
    like( $r->{error} // '', qr/writable_by/, '...saying what would let it' );
    is( rows(), '', '...and nothing was loaded' );

    $r = import_csv( 'wr', "slug,title\nwr1,One\nwr2,Two\n" );
    ok( $r->{ok}, 'an account in writable_by: imported' ) or diag( $r->{error} // $r->{_raw} // '' );
    is( rows(), 'wr1,wr2', '...the rows' );
};

subtest "(c) the table's owner imports past writable_by" => sub {
    my $r = api( 'own', 'data-table-acl-set', { table => 'posts', write => ['@writers'] } );
    ok( $r->{ok}, "set up: own sets the table's access rule, and so owns it" ) or diag( $r->{error} // '' );
    $r = import_csv( 'own', "slug,title\nown1,One\n" );
    ok( $r->{ok}, 'the owner, not in writable_by: imported' ) or diag( $r->{error} // '' );
    is( rows(), 'own1,wr1,wr2', '...the row' );
    $r = import_csv( 'ed', "slug,title\ned2,Two\n" );
    ok( !$r->{ok}, 'another account not in writable_by: still refused' );
    my $desc_after = do { open my $fh, '<', "$d/lazysite/db/tables/posts.yaml" or die $!; local $/; <$fh> };
    is( $desc_after, $desc_before, 'and the descriptor was never weakened' );
};

done_testing;
