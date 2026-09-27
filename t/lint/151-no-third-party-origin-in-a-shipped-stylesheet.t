#!/usr/bin/perl
# SM888 C1 and C2: NOTHING IN THE REPO CHECKED THE NO-CDN RULE.
#
# Five live sites fetched fonts from a third-party origin on every page view and
# survived repeated engine upgrades unreported. The reporter's own framing is the
# point: months of silence is "the actual defect here; the fonts are a symptom".
#
# C2 is why a markup scan is not enough. The reference was line 1 of a theme's
# stylesheet, an `@import` of a font service, so a scan of the PAGE certified it
# compliant. A stylesheet is where this hides, and `@import` is the shape it takes.
#
# WHAT THIS COVERS, and what it does not. This is the repo half: everything
# lazysite SHIPS - starter themes, layouts, manager pages and styles - must name
# no other origin, so a fresh site cannot start in breach and an upgrade cannot
# introduce one. The live half is a sweep of what each site actually serves,
# including themes an operator installed, and needs a rendered page from a real
# host; it is named in SM888 C1 and is not this test.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;

my $root = "$FindBin::Bin/../..";

# The rule is about ANOTHER ORIGIN, so a protocol-relative reference counts and a
# site-relative one does not. Data URIs are inline bytes, not a fetch.
my $THIRD_PARTY = qr{(?:https?:)?//(?!\s)[^\s'")]+}i;

my @files;
find(
    {   no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name;
            return unless $File::Find::name =~ /\.(?:css|tt|html)\z/;
            push @files, $File::Find::name;
        },
    },
    "$root/starter"
);
# The manager's own styles and pages ship too.
for my $extra ( "$root/dist/config" ) {
    next unless -d $extra;
    find(
        {   no_chdir => 1,
            wanted   => sub {
                push @files, $File::Find::name
                    if -f $File::Find::name && $File::Find::name =~ /\.(?:css|tt)\z/;
            },
        },
        $extra
    );
}

cmp_ok( scalar @files, '>=', 5, 'shipped stylesheets and templates were found' );

subtest 'no shipped stylesheet imports or fetches from another origin' => sub {
    my @bad;
    for my $f (@files) {
        open my $fh, '<', $f or die "$f: $!";
        my $n = 0;
        while ( my $line = <$fh> ) {
            $n++;
            next if $line =~ m{^\s*(?://|/\*|\*)};    # a comment, including a URL in prose
            # The two shapes that fetch: an @import, and a url() in a property.
            next unless $line =~ /\@import/i || $line =~ /url\s*\(/i;
            next unless $line =~ $THIRD_PARTY;
            my ($ref) = $line =~ /($THIRD_PARTY)/;
            push @bad, ( $f =~ s{^\Q$root/\E}{}r ) . ":$n: $ref";
        }
        close $fh;
    }
    is_deeply( \@bad, [], 'every reference is to this site' )
        or diag( "A shipped stylesheet naming another origin puts every site that\n"
            . "installs it in breach on every page view, and an import directive is\n"
            . "invisible to a scan of the rendered page.\n"
            . "to a scan of the rendered page:\n"
            . join( "\n", @bad ) );
};

subtest 'and the check would see the shape that hid for months' => sub {
    # The gate is only worth having if it catches the real case. This is line 1 of
    # the theme stylesheet the field found, and the older markup-only scan could
    # not see it at all.
    my $real = q{@import url('https://fonts.googleapis.com/css2?family=Inter&display=swap');};
    ok( $real =~ /\@import/i && $real =~ $THIRD_PARTY,
        'the @import that five sites shipped is matched' );

    my $ok_local = q{@import url('/lazysite-assets/theme/tokens.css');};
    ok( !( $ok_local =~ $THIRD_PARTY ), 'a site-relative import is not flagged' );

    my $ok_data = q{src: url(data:font/woff2;base64,AAAA) format('woff2');};
    ok( !( $ok_data =~ $THIRD_PARTY ), 'an inline data URI is not a fetch' );

    my $proto_rel = q{@import url('//fonts.example.com/x.css');};
    ok( $proto_rel =~ $THIRD_PARTY, 'a protocol-relative origin counts too' );
};

done_testing();
