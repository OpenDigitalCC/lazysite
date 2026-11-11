#!/usr/bin/perl
# SM1343 (0.16.5; the release manager's request of 24 October 2026, A-2): a profile
# has no kind, so ONE profile is allowed by one rule and denied by another, and the
# places a rule is SAVED accept it in either slot: a file or folder rule (acl-set,
# manager API and MCP) and a group's limit (group-set). Before, `office` was an allow
# list or a deny list for life; SM1189 refused it in the other slot at every save,
# and the office range had to be kept twice to be allowed here and denied there.
# The rules saved then mean what their slot says (t/integration/280 and 285 serve
# them; this file holds the saves). The manager's and sign-in's lazysite.conf keys
# are t/unit/auth/67; a page's front matter is t/unit/lib/205.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
sub spit  { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my @ALL = qw(ui manage_users manage_content api);
my $s   = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d   = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'sysops', [qw(ui manage_users manage_content)], \@ALL );
spit( "$d/lazysite/auth/address-profiles.json", encode_json( {
    office  => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { entries => [ { cidr => '203.0.113.9',    note => '' } ] },
} ) );
spit( "$d/internal/a.md", "---\ntitle: A\n---\nA.\n" );
spit( "$d/public/b.md",   "---\ntitle: B\n---\nB.\n" );

sub boss { my ( $action, $body, $q ) = @_; return $s->call( 'boss', $action, body => $body, query => $q, groups => 1 ) }
sub acls { return decode_json( slurp("$d/lazysite/auth/acls.json") // '{}' ) }

subtest 'acl-set: office allowed on one folder and denied on another' => sub {
    my $a = boss( 'acl-set', { owner => 'boss', addresses => ['office'] }, 'action=acl-set&path=internal/' );
    ok( $a->{ok}, 'office allowed on internal/' ) or diag explain $a;
    my $b = boss( 'acl-set', { owner => 'boss', addresses_deny => ['office'] }, 'action=acl-set&path=public/' );
    ok( $b->{ok}, 'the same profile denied on public/' ) or diag explain $b;
    is_deeply( acls()->{internal}{addresses}, ['office'], 'internal/ allows it' );
    is_deeply( acls()->{'public'}{addresses_deny}, ['office'], 'public/ denies it' );
    my $c = boss( 'acl-set', { owner => 'boss', addresses => ['blocked'], addresses_deny => ['office'] },
        'action=acl-set&path=mixed/' );
    ok( $c->{ok}, 'a profile used to deny elsewhere may be allowed beside one denied' ) or diag explain $c;
    unlike( encode_json($c), qr/kind/i, 'and nothing is said about a kind' );
    my $later = boss( 'acl-set', { owner => 'boss', addresses_deny => ['later'] }, 'action=acl-set&path=other/' );
    ok( !$later->{ok}, 'a profile the store does not hold is refused (n812)' ) or diag explain $later;
};

subtest 'group-set: either key takes any profile' => sub {
    $s->users( 'group-add', 'boss', 'g-x' );    # n818: a group exists once it has a member (group-create is no CLI verb)
    $s->users( 'group-add', 'boss', 'g-y' );
    my $o1 = $s->users( 'group-set', 'g-x', 'addresses',      'office' );
    my $o2 = $s->users( 'group-set', 'g-y', 'addresses_deny', 'office' );
    unlike( "$o1$o2", qr/kind|takes (?:allow|deny)/, 'neither is refused' );
    my $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") // '{}' );
    is_deeply( $gs->{'g-x'}{addresses},      ['office'], 'g-x counts only from office' );
    is_deeply( $gs->{'g-y'}{addresses_deny}, ['office'], 'g-y never counts from office' );
};

done_testing();
