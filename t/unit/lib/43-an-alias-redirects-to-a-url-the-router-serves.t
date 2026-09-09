#!/usr/bin/perl
# SM801, from the field: an alias on a directory-index page 301s to a URL that
# 404s.
#
# The alias machinery was faultless - the registry built, the redirect was
# issued, the 301 was correct - and it landed the visitor on a dead end. That
# is the shape worth a test: every part reported success and the whole was
# broken, so nothing in the authoring path could report it. Only FOLLOWING the
# redirect shows it.
#
# The two halves that disagreed, both in the tracked source:
#   canonical_url_for  built the target /foo   for foo/index.md
#   sanitise_uri       serves foo/index.md at  /foo/  and nowhere else,
#                      because it appends `/index` only for a trailing slash
# and the processor's own comment says so in words (processor:688).
#
# THE GUARD IS THE FILING'S OWN SUGGESTION, done statically: for every alias,
# resolve the target the way the router would and assert a file answers it.
# One pass over the map, no server.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper        qw(site_tempdir);
use Lazysite::Aliases qw(canonical_url_for index_page lookup);

# The router's own rule, transcribed from sanitise_uri (processor:2904-2917):
# a trailing slash means "the index in that directory"; otherwise the stem is
# the page. Kept deliberately small - if this drifts from the processor, the
# subtest below that reads the processor's source is what says so.
sub router_file_for {
    my ( $docroot, $url ) = @_;
    ( my $rel = $url ) =~ s{^/+}{};
    if ( $rel =~ s{/\z}{} ) { $rel = length $rel ? "$rel/index" : 'index' }
    return unless length $rel;
    for my $cand ( "$rel.md", "$rel.html", "$rel.url" ) {
        return $cand if -f "$docroot/$cand";
    }
    return;
}

subtest 'the canonical URL of an index page is the one the router serves' => sub {
    is( canonical_url_for('case-studies/index.md'), '/case-studies/',
        'an index page keeps its trailing slash' );
    is( canonical_url_for('index.md'), '/', 'the root index is just /' );
    is( canonical_url_for('distributors.md'), '/distributors',
        'an ordinary page has no slash - it is served without one' );
};

subtest 'an alias on an index page redirects somewhere that resolves' => sub {
    my $d = site_tempdir();
    make_path("$d/case-studies");
    make_path("$d/lazysite");
    my %page = (
        'case-studies/index.md' =>
            "---\ntitle: Case studies\naliases: [/in-use]\n---\n\nBody.\n",
        'distributors.md' =>
            "---\ntitle: Distributors\naliases: [/resellers]\n---\n\nBody.\n",
    );
    for my $rel ( sort keys %page ) {
        open my $fh, '>', "$d/$rel" or die "$rel: $!";
        print {$fh} $page{$rel};
        close $fh;
        # index_page is given the CONTENT - it parses the front matter it is
        # handed rather than re-reading the file.
        index_page( $d, $rel, $page{$rel} );
    }

    for my $case ( [ '/in-use', '/case-studies/' ], [ '/resellers', '/distributors' ] ) {
        my ( $from, $want ) = @$case;
        my $target = lookup( $d, $from );
        ok( $target, "$from is an alias" ) or next;
        is( $target, $want, "$from targets $want" );

        # THE ASSERTION THE FIELD HAD TO MAKE BY HAND: follow it.
        ok( router_file_for( $d, $target ),
            "and the router resolves $target to a file" )
            or diag( "The redirect is issued correctly and lands on a 404. "
                . 'That is what makes this invisible: every part reports success.' );
    }
};

# The rule above is transcribed, so this is what catches it drifting.
subtest 'the router still appends /index only for a trailing slash' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $src =~ /(sub sanitise_uri \{.*?\n\})/s;
    ok( $sub, 'sanitise_uri was found' ) or return;
    like( $sub, qr/trailing slash means directory index/i,
        'the comment still states the rule' );
    like( $sub, qr/\$uri \.= \S+index/,
        'and a trailing slash still appends the index stem' )
        or diag( 'If this changed, canonical_url_for has to change with it - '
            . 'they are two halves of one answer and they have disagreed before.' );
};

done_testing;
