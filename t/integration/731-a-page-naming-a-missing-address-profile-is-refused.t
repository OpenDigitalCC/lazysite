#!/usr/bin/perl
# n812 (ruling 234): A PAGE'S `addresses:` IS A RULE, SO A SAVE THAT NAMES AN ADDRESS
# PROFILE THE STORE DOES NOT HOLD IS REFUSED, naming it, and nothing is written.
# One function (Manager::Common::page_address_profile_refusal) is asked at the
# choke point, which the manager's save, the control API and MCP write_file and
# create_page run (MCP: t/unit/mcp/490), and by WebDAV before its rename (here).
# `lazysite check` keeps its warning for a page already on disk (t/unit/tools/82).
#
# Sabotage: drop the page_address_profile_refusal call from _content_write_refusal
# and from lazysite-dav.pl, and the refusals below fail.
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
sub spit  { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $PROFILES = encode_json( { office => { entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } );
sub page { my ($fm) = @_; return "---\ntitle: P\n$fm---\nbody\n" }

my @ALL = qw(ui manage_users manage_content api);
my $s   = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d   = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'sysops', [qw(ui manage_users manage_content)], \@ALL );
spit( "$d/lazysite/auth/address-profiles.json", $PROFILES );

sub save { my ( $path, $content ) = @_; return $s->call( 'boss', 'save', query => "action=save&path=$path", body => { content => $content }, groups => 1 ) }

subtest 'the manager save refuses a missing profile, in either key, naming it' => sub {
    for my $c ( [ addresses => "addresses: [zz92-allow]\n" ], [ addresses_deny => "addresses_deny:\n  - zz92-allow\n  - office\n" ] ) {
        my ( $k, $fm ) = @$c;
        my $r = save( "$k.md", page($fm) );
        ok( !$r->{ok}, "$k: refused" ) or diag explain $r;
        is( $r->{kind}, 'address-profile-refused', "$k: the kind" );
        like( $r->{error} // '', qr/zz92-allow/, "$k: naming the missing profile" );
        unlike( $r->{error} // '', qr/\boffice\b/, "$k: and not the one that exists" );
        ok( !-e "$d/$k.md", "$k: nothing was written" );
    }
};

subtest 'a profile the store holds, or no profile, is saved' => sub {
    my $r = save( 'held.md', page("addresses: [office]\n") );
    ok( $r->{ok}, 'a page naming office is saved' ) or diag explain $r;
    $r = save( 'plain.md', page('') );
    ok( $r->{ok}, 'and a page naming none' ) or diag explain $r;
};

my $dav = setup_dav_site( conf => "webdav_enabled: true\n" );
my $dd  = $dav->{docroot};
spit( "$dd/lazysite/auth/address-profiles.json", $PROFILES );

subtest 'WebDAV refuses it before the rename, and accepts a held profile' => sub {
    my %auth = ( HTTP_AUTHORIZATION => $dav->{auth}, REMOTE_ADDR => '127.0.0.1' );
    my $bad = run_dav( $dd, 'PUT', '/missing.md', %auth, body => page("addresses: [zz92-allow]\n") );
    is( $bad->{code}, 415, 'a PUT naming a missing profile is refused' ) or diag( $bad->{raw} );
    like( $bad->{body} // $bad->{raw} // '', qr/zz92-allow/, 'naming it' );
    ok( !-e "$dd/missing.md", 'and nothing landed' );
    my $ok = run_dav( $dd, 'PUT', '/held.md', %auth, body => page("addresses: [office]\n") );
    ok( $ok->{code} >= 200 && $ok->{code} < 300, 'a held profile is accepted' ) or diag( $ok->{raw} );
};

done_testing;
