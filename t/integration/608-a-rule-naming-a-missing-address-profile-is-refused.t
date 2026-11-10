#!/usr/bin/perl
# n812 (O-2 of the 0.16.10 edge run): A RULE THAT NAMES AN ADDRESS PROFILE THE
# STORE DOES NOT HOLD IS REFUSED ON SAVE, naming the profile, and nothing is
# written. `set_permissions` with addresses: ["zz92-allow"] answered ok: true while
# no such profile existed, and the rule then refused every write to the path (a
# missing profile allowed admits nobody). Every door that writes a rule funnels
# through Files::action_acl_set: the manager API (here, a path and a list of
# paths), the CLI `lazysite acl set` (here), and MCP set_permissions
# (t/unit/mcp/309). A profile deleted after a rule names it is the check's to
# report (t/unit/tools/82) and the users tool refuses the delete while a rule
# names it; this file holds the save.
#
# Sabotage: restore the warning in place of _address_profile_refusal's call in
# Files::action_acl_set and the refusals below fail.
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
spit( "$d/lazysite/auth/address-profiles.json", encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) );
spit( "$d/a/p.md", "---\ntitle: A\n---\nA.\n" );
spit( "$d/b/p.md", "---\ntitle: B\n---\nB.\n" );

sub boss { my ( $action, $body, $q ) = @_; return $s->call( 'boss', $action, body => $body, query => $q, groups => 1 ) }
sub acls { return decode_json( slurp("$d/lazysite/auth/acls.json") // '{}' ) }

subtest 'the manager API refuses a profile the store lacks, in either slot, naming it' => sub {
    for my $f (qw(addresses addresses_deny)) {
        my $r = boss( 'acl-set', { owner => 'boss', $f => ['zz92-allow'] }, 'action=acl-set&path=a/' );
        ok( !$r->{ok}, "$f: refused" ) or diag explain $r;
        like( $r->{error} // '', qr/zz92-allow/, "$f: naming the missing profile" );
        is( $r->{field}, $f, "$f: and the field" );
        ok( !exists acls()->{'a'}, "$f: nothing written" );
    }
    my $two = boss( 'acl-set', { owner => 'boss', addresses => [ 'office', 'gone-1' ], addresses_deny => ['gone-2'] }, 'action=acl-set&path=a/' );
    ok( !$two->{ok}, 'one held and two missing: refused' );
    like( $two->{error} // '', qr/gone-1, gone-2/, 'naming every missing one and not the held one' );
    unlike( $two->{error} // '', qr/office/, 'not the profile that exists' );
    ok( !exists acls()->{'a'}, 'nothing written' );
};

subtest 'a profile the store holds is still accepted' => sub {
    my $r = boss( 'acl-set', { owner => 'boss', addresses => ['office'] }, 'action=acl-set&path=a/' );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    is_deeply( acls()->{'a'}{addresses}, ['office'], 'and stored' );
};

subtest 'a list of paths is refused whole, and nothing is written' => sub {
    my $r = boss( 'acl-set', { owner => 'boss', paths => [ 'b/', 'a/' ], addresses => ['zz92-allow'] }, 'action=acl-set' );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    like( encode_json($r), qr/zz92-allow/, 'naming the profile' );
    ok( !exists acls()->{'b'}, 'b/ has no rule' );
    is_deeply( acls()->{'a'}{addresses}, ['office'], 'and a/ keeps its rule' );
};

subtest 'the CLI refuses it, naming it, and writes nothing' => sub {
    my $cmd = join ' ', map { quotemeta } $^X, "$root/tools/lazysite-acl.pl", 'set', 'b/', '--owner', 'boss',
        '--addresses', 'zz92-allow', '--docroot', $d, '--actor', 'boss';
    my $out = qx($cmd 2>&1);
    isnt( $? >> 8, 0, 'a non-zero exit' );
    like( $out, qr/zz92-allow/, 'naming the profile' );
    ok( !exists acls()->{'b'}, 'nothing written' );
};

done_testing;
