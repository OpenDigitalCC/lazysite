#!/usr/bin/perl
# SM1189 (0.15.10 walk, F-3): `addresses_deny: [zz60-mine]`, zz60-mine being an
# allow list, was ignored in silence. The places a rule is SAVED refuse a list of
# the wrong kind and write nothing: a file or folder rule (acl-set, manager API and
# MCP) and a group's limit (group-set). The manager's and sign-in's lazysite.conf
# keys already refused it (Config, SM1140); a page's front matter is not saved
# through a gate that runs the validator, so the validator and `lazysite check` name
# that one (t/unit/lib/205, t/unit/tools/85).
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
spit( "$d/lazysite/auth/address-lists.json", encode_json( {
    mine    => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
    blocked => { kind => 'deny',  entries => [ { cidr => '203.0.113.9',    note => '' } ] },
} ) );
spit( "$d/internal/a.md", "---\ntitle: A\n---\nA.\n" );

sub boss { my ( $action, $body, $q ) = @_; return $s->call( 'boss', $action, body => $body, query => $q, groups => 1 ) }
sub acls { return decode_json( slurp("$d/lazysite/auth/acls.json") // '{}' ) }

subtest 'acl-set refuses a list of the wrong kind in either slot and writes nothing' => sub {
    for my $case ( [ addresses_deny => 'mine', 'an allow list' ], [ addresses => 'blocked', 'a deny list' ] ) {
        my ( $f, $name, $kind ) = @$case;
        my $r = boss( 'acl-set', { owner => 'boss', $f => [$name] }, 'action=acl-set&path=internal/' );
        ok( !$r->{ok}, "$name under $f is refused" ) or diag explain $r;
        like( $r->{error} // '', qr/'\Q$name\E' is \Q$kind\E/, '  naming the list and its kind' );
        like( $r->{error} // '', qr/Nothing was changed/, '  and saying nothing was written' );
        ok( !exists acls()->{internal}, '  and the rule is not in the store' );
    }
    my $ok = boss( 'acl-set', { owner => 'boss', addresses => ['mine'], addresses_deny => ['blocked'] }, 'action=acl-set&path=internal/' );
    ok( $ok->{ok}, 'the right kinds are accepted' ) or diag explain $ok;
    my $later = boss( 'acl-set', { owner => 'boss', addresses_deny => ['later'] }, 'action=acl-set&path=other/' );
    ok( $later->{ok}, 'a list the store does not hold yet is still accepted' ) or diag explain $later;
};

subtest 'group-set refuses a list of the wrong kind and writes nothing' => sub {
    $s->users( 'group-create', 'g-x' );
    for my $case ( [ addresses_deny => 'mine' ], [ addresses => 'blocked' ] ) {
        my ( $key, $name ) = @$case;
        my $out = $s->users( 'group-set', 'g-x', $key, $name );
        like( $out, qr/'\Q$name\E' is (?:an allow|a deny) list, and \Q$key\E takes/, "$name under $key: refused, naming it" ) or diag $out;
    }
    my $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") // '{}' );
    ok( !$gs->{'g-x'}{addresses} && !$gs->{'g-x'}{addresses_deny}, 'and nothing was written' );
    $s->users( 'group-set', 'g-x', 'addresses', 'mine' );
    $gs = decode_json( slurp("$d/lazysite/auth/groups-settings.json") );
    is_deeply( $gs->{'g-x'}{addresses}, ['mine'], 'the right kind is written' );
};

done_testing();
