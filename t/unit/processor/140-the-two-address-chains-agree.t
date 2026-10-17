#!/usr/bin/perl
# SM1139 (slice B of SM1134): the render path's address chain and the library's
# name the same rules for the same path, and refuse in the same words.
#
# The processor is module-free on the render path (ADR 0001), so it carries its
# own _address_chain (lazysite-processor/acl.pm); the manager API, MCP and WebDAV
# ask Lazysite::Auth::Acl::address_chain / address_denial. Two readers of one
# store that disagreed about WHICH rules govern a path would limit a page on one
# door and not on another, so they are compared here over a table: the path's own
# key, its page stem, a folder, a nested folder, the site-wide rule in each of its
# spellings, entries that name no list, trailing and leading slashes, and a
# sibling folder whose name only starts the same.
#
# The decision itself is the module's on both sides (the processor loads it on
# first use), so what is pinned is the chain and the sentence.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_minimal_site load_processor site_tempdir);
use Lazysite::Auth::Acl ();

my $docroot = site_tempdir();
setup_minimal_site($docroot);
load_processor($docroot);

my $MAP = {
    'page.md'        => { owner => 'x', addresses => ['one'] },
    'sec'            => { owner => 'x', addresses => ['two'], addresses_deny => ['bad'] },
    'sec/inner/'     => { owner => 'x', addresses => ['three'] },
    '/lead'          => { owner => 'x', addresses_deny => ['bad'] },
    'plain'          => { owner => 'x', read => ['@staff'] },    # names no list: not a layer
    'empty'          => { owner => 'x', addresses => [], addresses_deny => [] },
    'sec2'           => { owner => 'x', addresses => ['sibling'] },
    '/'              => { owner => 'x', addresses_deny => ['site'] },
    'junk'           => 'not a hash',
    'odd'            => { addresses => 'office' },               # not a list: not a layer
};
my @RELS = (
    'page.md', 'page', 'sec/a.md', 'sec/inner/b.md', 'sec/inner/deep/c.txt', 'sec', 'sec.md',
    'lead/x.md', 'plain/x.md', 'empty/x.md', 'sec2/x.md', 'secx/y.md', 'other.md', 'junk/a.md',
    'odd/a.md', '/sec/a.md', 'sec/inner',
);

sub shape {
    my ($chain) = @_;
    return join ' ; ', sort map {
        join '|', $_->{key}, join( ',', @{ $_->{allow} } ), join( ',', @{ $_->{deny} } )
    } @$chain;
}

for my $rel (@RELS) {
    my $p = main::_address_chain( $MAP, $rel );
    my $l = Lazysite::Auth::Acl::address_chain( $MAP, $rel );
    is( shape($p), shape($l), "the same layers govern '$rel'" );
}

subtest 'the pin can see a difference' => sub {
    is( shape( main::_address_chain( $MAP, 'sec/inner/b.md' ) ),
        '/||site ; sec/inner/|three| ; sec|two|bad',
        'a nested folder is two layers, and the site-wide rule a third' );
    is( scalar @{ main::_address_chain( $MAP, 'plain/x.md' ) }, 1, 'an entry naming no list is not a layer (only the site-wide one is)' );
    is( scalar @{ main::_address_chain( $MAP, 'secx/y.md' ) }, 1, 'a folder whose name only starts the same does not govern' );
    is( scalar @{ main::_address_chain( $MAP, 'odd/a.md' ) }, 1, 'a value that is not a list is no layer' );
};

subtest 'both refuse in the ruled words' => sub {
    make_path( "$docroot/lazysite/auth", "$docroot/internal" );
    for my $f (
        [ 'address-lists.json', encode_json( { office => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } ) ],
        [ 'acls.json', encode_json( { internal => { owner => 'x', addresses => ['office'] } } ) ],
        )
    {
        open my $fh, '>', "$docroot/lazysite/auth/$f->[0]" or die $!;
        print {$fh} $f->[1];
        close $fh;
    }
    local $ENV{REMOTE_ADDR} = '192.0.2.9';
    local $Lazysite::Auth::Acl::DOCROOT = $docroot;
    my $d = Lazysite::Auth::Acl::address_denial('internal/a.md');
    ok( $d && !$d->{ok}, 'the library refuses an address outside the list' );
    is( $d->{error}, main::_address_refusal_sentence(), 'in the same words the render path uses' );
    is( $d->{error}, 'This page is not available from your address.', 'which are the ruled sentence' );
    $ENV{REMOTE_ADDR} = '203.0.113.7';
    is( Lazysite::Auth::Acl::address_denial('internal/a.md'), undef, 'and admits an address in it' );
    delete $ENV{REMOTE_ADDR};
    is( Lazysite::Auth::Acl::address_denial('internal/a.md'), undef,
        'a caller with no web request (the users tool) has no visitor address to limit' );
};

done_testing;
