#!/usr/bin/perl
# SM1141 (slice D of SM1134), checked when the slices were stacked: EVERY DOMAIN'S
# PAGES ARE READ FOR THE ADDRESS LISTS THEY NAME.
#
# SM1141's filing left open: "Pages are looked for under the docroot and its private
# store; a domain with its own content root outside both is not walked." There is no
# such domain. A content root is served only through confine_content_root
# (lazysite-processor/pipeline.pm): the value is read relative to the docroot (a
# leading slash is stripped), must resolve - symlinks included - to a directory
# INSIDE the docroot, and never the engine's tree; anything else falls back to the
# docroot. The manager writes it the same way (Manager::Domains::_clean_content_root).
# A gated page under a domain moves to the private store at the same relative path
# (SM286). So the two trees Lazysite::Auth::AddressRefs walks are every place a
# domain's page can be served from. This pins that: a page under each kind of domain
# root, public and private, is found, and the delete guard refuses for each.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Private        ();
use Lazysite::Auth::AddressRefs ();

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

sub api {
    my ( $d, $req ) = @_;
    my $in = File::Temp->new;
    print {$in} encode_json($req);
    close $in;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, '--api';
    my $out = `$cmd < \Q$in\E 2>/dev/null`;
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}

my $d    = site_tempdir();
my $priv = Lazysite::Private::private_root($d);
make_path("$d/lazysite/auth");
spit( "$d/lazysite/lazysite.conf", join "\n",
    'alias_hosts: ext.example.org, abs.example.org',
    'alias.ext.example.org.content_root: sites/ext',
    # written as an absolute path: the engine serves it from <docroot>/abs
    'alias.abs.example.org.content_root: /abs',
    '' );
spit( "$d/lazysite/auth/address-lists.json", encode_json( {
    ( map { $_ => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } qw(l-ext l-priv l-abs) ),
} ) );
spit( "$d/sites/ext/p.md",               "---\ntitle: P\naddresses: [l-ext]\n---\nP\n" );
spit( "$priv/sites/ext/members/m.md",    "---\ntitle: M\nauth: required\naddresses:\n  - l-priv\n---\nM\n" );
spit( "$d/abs/a.md",                     "---\ntitle: A\naddresses_deny: [l-abs]\n---\nA\n" );

my $r = Lazysite::Auth::AddressRefs::rules($d);
is_deeply( $r->{faults}, [], 'the walk meets no fault' );
my %found = map { ( $_->{name} => $_->{ref} ) } grep { $_->{where} eq 'page' } @{ $r->{rules} };
is( $found{'l-ext'},  'sites/ext/p.md',         'a page under a domain content root is read' );
is( $found{'l-priv'}, 'sites/ext/members/m.md', 'a gated page of that domain, in the private store, is read' );
is( $found{'l-abs'},  'abs/a.md',               'a page under a root written as an absolute path is read where it is served' );

for my $n (qw(l-ext l-priv l-abs)) {
    my $del = api( $d, { action => 'address-list-delete', name => $n } );
    ok( !$del->{ok}, "the delete guard refuses $n" );
    is( $del->{kind}, 'in-use', '...as in use' ) or diag( $del->{error} // '' );
}

done_testing();
