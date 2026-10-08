#!/usr/bin/perl
# SM869 adversarial review, second pass (n271): every template value the shipped
# tree places in an HTML attribute is inside quotes.
#
# The stash escapes a value for a QUOTED attribute: `"` and `'` become entities,
# so the value cannot leave the quotes. Unquoted, a space or `>` in the value
# ends the attribute and starts another - `<a href=[% x %]>` with x = `a onx=m`
# - and no escape the stash applies prevents that. So the property is held at
# the template, not the escape: no `name=[% ... %]` anywhere a page, layout,
# template or the processor's own built-in layout ships. The review found none;
# this keeps it so. t/unit/processor/90 shows a space and `>` staying in a
# quoted attribute.
#
# A directive used as a whole attribute (`<a [% IF x %]class="on"[% END %]>`)
# emits fixed text the template wrote, never a value, and is not counted.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @files;
find( { no_chdir => 1, wanted => sub { push @files, $_ if -f $_ && /\.(?:md|tt|html)\z/ } },
    "$root/starter" );
push @files, "$root/lazysite-processor.pl",
    sort glob("$root/lazysite-processor/*.pm");    # SM944: and its parts
cmp_ok( scalar @files, '>', 50, 'the shipped pages, layouts and templates were found' );

my ( @bare, $seen );
for my $f (@files) {
    open my $fh, '<', $f or next;
    local $/;
    my $t = <$fh>;
    close $fh;
    # Blank each directive's interior, so an `=` or `>` inside [% ... %] is not
    # read as part of the tag around it.
    ( my $s = $t ) =~ s{\[%(.*?)%\]}{ '[%' . ( 'x' x length $1 ) . '%]' }gse;
    while ( $s =~ m{<[a-zA-Z][\w:-]*\b((?:[^>"']|"[^"]*"|'[^']*')*)>}g ) {
        my ( $attrs, $at ) = ( $1, $-[0] );
        while ( $attrs =~ m{([\w:-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+)}g ) {
            my ( $name, $v ) = ( $1, $2 );
            next unless $v =~ /\[%/;
            $seen++;
            next if $v =~ /\A["']/;
            my $line = 1 + ( () = substr( $s, 0, $at ) =~ /\n/g );
            ( my $rel = $f ) =~ s{^\Q$root\E/}{};
            push @bare, "$rel:$line $name=$v";
        }
    }
}
cmp_ok( $seen // 0, '>', 20, 'template values in attributes were found (the scan reads them)' );
is( scalar @bare, 0, 'no template value sits in an unquoted attribute' )
    or diag( join "\n", 'Quote these:', @bare );

done_testing();
