#!/usr/bin/perl
# SM970 (ruled 2026-10-07): every template value the shipped tree places as a
# WHOLE link target - `href="[% x %]"`, `src=`, `action=`, `formaction=`,
# `poster=` - ends in `| url_safe`.
#
# The stash escapes a value so it cannot leave its attribute; escaping leaves
# `javascript:` as it is, so a value that IS the attribute can still run script
# when followed. The filter passes no-scheme, http, https, mailto and tel values
# unchanged and turns anything else into `#` (t/unit/processor/92). Pages,
# layouts and templates under starter/ and the processor's own built-in layout
# are read; a value with text around it (`[% theme_assets %]/main.css`) is not a
# whole target - its scheme is the fixed text's - and is not counted. No `.html`
# under starter/ is a source (.gitignore excludes them all: they are rendered
# caches), so only `.md` and `.tt` are read.
#
# EXEMPT BY NAME - values the engine itself builds, never a visitor's or a row's:
#   l.url, languages.0.url   a language alternate's URL, built by the engine
#                            from the page's own path (SM179)
#   site_url                 the sysop's configured site URL (registries)
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my %EXEMPT = map { $_ => 1 } qw(l.url languages.0.url site_url);

my $root = repo_root();
my @files;
find(
    { no_chdir => 1,
        wanted => sub {
            push @files, $_ if -f $_ && /\.(?:md|tt)\z/;
        }
    },
    "$root/starter"
);
push @files, "$root/lazysite-processor.pl";
cmp_ok( scalar @files, '>', 50, 'the shipped pages, layouts and templates were found' );

my ( @bad, $whole, $filtered );
for my $f (@files) {
    open my $fh, '<', $f or next;
    local $/;
    my $t = <$fh>;
    close $fh;
    # Blank each directive's interior to find the tags (as lint 212 does); the
    # blanked copy keeps every offset, so the value is read back from $t.
    ( my $s = $t ) =~ s{\[%(.*?)%\]}{ '[%' . ( 'x' x length $1 ) . '%]' }gse;
    while ( $s =~ m{<[a-zA-Z][\w:-]*\b((?:[^>"']|"[^"]*"|'[^']*')*)>}g ) {
        my $tag_at   = $-[0];
        my $attrs_at = $-[1];
        my $attrs    = $1;
        while ( $attrs =~ m{([\w:-]+)\s*=\s*("[^"]*"|'[^']*')}g ) {
            my ( $name, $v_at, $v_len ) = ( lc $1, $-[2], length $2 );
            next unless $name =~ /\A(?:href|src|action|formaction|poster)\z/;
            my $v = substr( $t, $attrs_at + $v_at + 1, $v_len - 2 );
            next unless $v =~ /\A\s*\[%-?\s*(.*?)\s*-?%\]\s*\z/s;
            my $expr = $1;
            next if $expr =~ /\[%|%\]/;    # two directives: not one whole value
            $whole++;
            if ( $expr =~ /\|\s*url_safe\z/ ) { $filtered++; next }
            next if $EXEMPT{$expr};
            my $line = 1 + ( () = substr( $t, 0, $tag_at ) =~ /\n/g );
            ( my $rel = $f ) =~ s{^\Q$root\E/}{};
            push @bad, "$rel:$line $name=\"$v\"";
        }
    }
}
cmp_ok( $whole // 0, '>', 5, 'whole-value link targets were found (the scan reads them)' );
cmp_ok( $filtered // 0, '>', 0, 'and some already carry the filter' );
is( scalar @bad, 0, 'every whole-value link target ends in | url_safe or is exempt by name' )
    or diag( join "\n", 'Add | url_safe (SM970), or exempt by name with a reason:', @bad );

done_testing();
