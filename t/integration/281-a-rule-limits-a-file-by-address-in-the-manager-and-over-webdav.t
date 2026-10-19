#!/usr/bin/perl
# SM1139 (slice B of SM1134): the per-file access rule carries `addresses` and
# `addresses_deny`, acl-set writes and validates them, acl-get and the listing
# return them, and the doors that are not the page - the manager API's file reads
# and WebDAV - refuse a file under such a rule to an address it does not admit.
#
# The site trusts 127.0.0.1 as its front end, so the visitor's address is the
# X-Forwarded-For the test sends. Lists: `office` (allow, 203.0.113.0/24),
# `blocked` (deny, 203.0.113.9).
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root setup_dav_site run_dav);
use ManagerSession qw(new_site);

my $root = repo_root();
my $SENTENCE = 'This page is not available from your address.';

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $LISTS = encode_json( {
    office  => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => 'HQ' } ] },
    blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',    note => 'scanner' } ] },
} );

my $OFFICE  = '203.0.113.5';
my $SCANNER = '203.0.113.9';
my $OUTSIDE = '192.0.2.77';

# ---------------------------------------------------------------- the manager
my @ALL = qw(ui manage_users manage_content api);
my $s   = new_site( root => $root, conf => "control_api_enabled: true\ntrusted_proxies: 127.0.0.1\n" );
my $d   = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'sysops', [qw(ui manage_users manage_content)], \@ALL );
spit( "$d/lazysite/auth/address-lists.json", $LISTS );
spit( "$d/internal/a.md", "---\ntitle: A\n---\nSecret A.\n" );

sub boss {
    my ( $action, $body, $q ) = @_;
    return $s->call( 'boss', $action, ( defined $body ? ( body => $body ) : () ),
        ( defined $q ? ( query => $q ) : () ), groups => 1 );
}
sub acls { return decode_json( slurp("$d/lazysite/auth/acls.json") // '{}' ) }

subtest 'acl-set writes the two fields, and acl-get returns them' => sub {
    my $r = boss( 'acl-set', { owner => 'boss', addresses => ['office'], addresses_deny => ['blocked'] }, 'action=acl-set&path=internal/' );
    ok( $r->{ok}, 'accepted' ) or diag( explain $r );
    is_deeply( acls()->{internal}{addresses},      ['office'],  'addresses stored' );
    is_deeply( acls()->{internal}{addresses_deny}, ['blocked'], 'addresses_deny stored' );
    ok( !grep( {/does not hold/} @{ $r->{warnings} || [] } ), 'known lists: no warning' );
    my $g = boss( 'acl-get', undef, 'action=acl-get&path=internal/' );
    is_deeply( $g->{acl}{addresses}, ['office'], 'acl-get returns addresses' );
    is_deeply( $g->{acl}{addresses_deny}, ['blocked'], 'and addresses_deny' );
    is_deeply( $g->{address_lists}, [ { name => 'blocked', kind => 'deny' }, { name => 'office', kind => 'allow' } ],
        'and the lists the rule may name: names and kinds, never entries' );
    my $l = boss( 'list', undef, 'action=list&path=/' );
    ok( ref $l->{address_lists} eq 'ARRAY' && @{ $l->{address_lists} } == 2, 'the listing offers the lists for the permissions editor' );
};

subtest 'a rule changed for another reason keeps its address lists; an empty list clears' => sub {
    my $r = boss( 'acl-set', { owner => 'boss', read => [] }, 'action=acl-set&path=internal/' );
    ok( $r->{ok}, 'an unrelated change is accepted' ) or diag( explain $r );
    is_deeply( acls()->{internal}{addresses}, ['office'], 'addresses survive it' );
    $r = boss( 'acl-set', { owner => 'boss', addresses => [] }, 'action=acl-set&path=internal/' );
    ok( $r->{ok}, 'clearing is accepted' );
    ok( !exists acls()->{internal}{addresses}, 'an empty list clears addresses' );
    is_deeply( acls()->{internal}{addresses_deny}, ['blocked'], 'and leaves addresses_deny alone' );
    boss( 'acl-set', { owner => 'boss', addresses => ['office'] }, 'action=acl-set&path=internal/' );
};

subtest 'a name is validated; an unknown list is accepted with a warning that says why' => sub {
    my $bad = boss( 'acl-set', { owner => 'boss', addresses => ['Not A Name'] }, 'action=acl-set&path=other/' );
    ok( !$bad->{ok}, 'a name that cannot be a list name is refused' );
    like( $bad->{error}, qr/not an address list name/, 'saying so' );
    ok( !exists acls()->{other}, 'and nothing was written' );
    my $r = boss( 'acl-set', { owner => 'boss', addresses => ['later'] }, 'action=acl-set&path=other/' );
    ok( $r->{ok}, 'a list the store does not hold yet is accepted' ) or diag( explain $r );
    is_deeply( acls()->{other}{addresses}, ['later'], 'and stored as written' );
    my ($w) = grep { /does not hold yet: later/ } @{ $r->{warnings} || [] };
    ok( $w, 'with a warning' ) or diag( explain $r->{warnings} );
    like( $w // '', qr/may be created later/, 'that says a list may be created later' );
    like( $w // '', qr/admits NO address/,    'and what the rule does until it is' );
    my $wrong = boss( 'acl-set', { owner => 'boss', addresses => ['blocked'] }, 'action=acl-set&path=wrong/' );
    # SM1189: it was accepted with a warning; a rule the engine now refuses is not saved.
    ok( !$wrong->{ok}, 'a deny list under addresses is refused' );
    like( $wrong->{error} // '', qr/'blocked' is a deny list and is named in addresses/, 'saying which list is the wrong kind' );
    ok( !exists acls()->{wrong}, 'and nothing was written' );
};

subtest 'the manager API refuses a file under the rule to an address outside it' => sub {
    my $ok = do {
        local $ENV{REMOTE_ADDR} = '127.0.0.1';
        local $ENV{HTTP_X_FORWARDED_FOR} = $OFFICE;
        boss( 'read', undef, 'action=read&path=internal/a.md' );
    };
    ok( $ok->{ok}, 'the office address reads it' ) or diag( explain $ok );
    my $no = do {
        local $ENV{REMOTE_ADDR} = '127.0.0.1';
        local $ENV{HTTP_X_FORWARDED_FOR} = $OUTSIDE;
        boss( 'read', undef, 'action=read&path=internal/a.md' );
    };
    ok( !$no->{ok}, 'an outside address is refused' );
    is( $no->{error}, $SENTENCE, 'with the ruled sentence' );
    my $bad = do {
        local $ENV{REMOTE_ADDR} = '127.0.0.1';
        local $ENV{HTTP_X_FORWARDED_FOR} = $SCANNER;
        boss( 'read', undef, 'action=read&path=internal/a.md' );
    };
    ok( !$bad->{ok}, 'an address in the allow list and the deny list is refused: deny wins' );
    my $w = do {
        local $ENV{REMOTE_ADDR} = '127.0.0.1';
        local $ENV{HTTP_X_FORWARDED_FOR} = $OUTSIDE;
        boss( 'save', { content => "---\ntitle: A\n---\nTampered.\n" }, 'action=save&path=internal/a.md' );
    };
    ok( !$w->{ok}, 'a write from outside is refused too' );
    unlike( slurp("$d/internal/a.md"), qr/Tampered/, 'and the file is unchanged' );
    my $log = slurp("$d/lazysite/logs/audit.log") // '';
    my @rows = grep { /\| address-refused \| \/internal\/a\.md \|/ } split /\n/, $log;
    ok( scalar(@rows) >= 1 && scalar(@rows) <= 3, 'refusals are audited, once per address per hour' ) or diag($log);
    my %by = map { ( /\| (\d[\d.]+) \| fail/ ? $1 : '?' ) => 1 } @rows;
    is( scalar( keys %by ), scalar(@rows), 'one row per address, not one per request' );
};

# ------------------------------------------------------------------- WebDAV
my $dav = setup_dav_site( conf => "webdav_enabled: true\ntrusted_proxies: 127.0.0.1\n" );
my $dd  = $dav->{docroot};
spit( "$dd/lazysite/auth/address-lists.json", $LISTS );
spit( "$dd/internal/a.md", "dav secret\n" );
spit( "$dd/open.md",       "dav open\n" );
spit( "$dd/lazysite/auth/acls.json", encode_json( { internal => { owner => 'deploy', addresses => ['office'], addresses_deny => ['blocked'] } } ) );

subtest 'WebDAV refuses a file under the rule to an address outside it' => sub {
    my %auth = ( HTTP_AUTHORIZATION => $dav->{auth}, REMOTE_ADDR => '127.0.0.1' );
    my $ok = run_dav( $dd, 'GET', '/internal/a.md', %auth, HTTP_X_FORWARDED_FOR => $OFFICE );
    is( $ok->{code}, 200, 'GET from the office address is served' ) or diag( $ok->{raw} );
    like( $ok->{body}, qr/dav secret/, 'with the bytes' );
    my $no = run_dav( $dd, 'GET', '/internal/a.md', %auth, HTTP_X_FORWARDED_FOR => $OUTSIDE );
    is( $no->{code}, 403, 'GET from an outside address is refused' );
    unlike( $no->{body}, qr/dav secret/, 'and no bytes are sent' );
    like( ( $no->{headers}{'x-lazysite-deny-reason'} // '' ) . $no->{body}, qr/\Q$SENTENCE\E/, 'saying the ruled sentence' );
    my $bad = run_dav( $dd, 'GET', '/internal/a.md', %auth, HTTP_X_FORWARDED_FOR => $SCANNER );
    is( $bad->{code}, 403, 'an address on the deny list is refused though the allow list has it' );
    my $put = run_dav( $dd, 'PUT', '/internal/a.md', %auth, HTTP_X_FORWARDED_FOR => $OUTSIDE, body => "overwritten\n" );
    is( $put->{code}, 403, 'PUT from outside is refused' );
    is( slurp("$dd/internal/a.md"), "dav secret\n", 'and the file is unchanged' );
    my $del = run_dav( $dd, 'DELETE', '/internal/a.md', %auth, HTTP_X_FORWARDED_FOR => $OUTSIDE );
    is( $del->{code}, 403, 'DELETE from outside is refused' );
    ok( -e "$dd/internal/a.md", 'and the file is still there' );
    my $put_ok = run_dav( $dd, 'PUT', '/internal/b.md', %auth, HTTP_X_FORWARDED_FOR => $OFFICE, body => "new\n" );
    ok( $put_ok->{code} >= 200 && $put_ok->{code} < 300, 'PUT from the office address is allowed' ) or diag( $put_ok->{raw} );
    my $free = run_dav( $dd, 'GET', '/open.md', %auth, HTTP_X_FORWARDED_FOR => $OUTSIDE );
    is( $free->{code}, 200, 'a file under no rule is unaffected' );
    my $log = slurp("$dd/lazysite/logs/audit.log") // '';
    my @rows = grep { /\| address-refused \| \/internal\/a\.md \| \Q$OUTSIDE\E / } split /\n/, $log;
    is( scalar @rows, 1, 'GET, PUT and DELETE from one address for one file: one audit row' ) or diag($log);
};

done_testing;
