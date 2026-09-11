#!/usr/bin/perl
# SM793: every escape in the manager covers & < > " and '.
#
# The security review traced a public form value from the store to the operator's
# screen and found it inert - because the submissions viewer passes every cell
# through esc(). It filed the pass for the reason it passes: one client-side
# function is the whole defence, in the session with the most authority on the
# site, and that function did not escape the apostrophe. An attribute written in
# single quotes, by the next reader of the same data, is stored XSS.
#
# A sweep found five helpers short of the apostrophe (one of them short of the
# double quote as well) and two hand-written inline escapes. They are one rule
# now, and this pins it: any function on a manager surface that escapes `<` also
# escapes the other four - whether it is a helper named esc, escHtml, or a body
# that does it inline. Which quote an attribute uses is then nobody's concern.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my @files = (
    glob("$root/starter/manager/*.md"),
    "$root/starter/lazysite/manager/layout.tt",
    glob("$root/starter/lazysite/manager/assets/*.js"),
);

my %NEED = (
    '&' => qr{replace\(/&/g},
    '>' => qr{replace\(/>/g},
    '"' => qr{replace\(/\\?"/g},
    "'" => qr{replace\(/\\?'/g},
);

my $seen = 0;
for my $f (@files) {
    open my $fh, '<', $f or next;
    my $t = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $f ) =~ s{\A\Q$root/\E}{};
    while ( $t =~ /function\s+(\w+)\s*\([^)]*\)\s*\{/g ) {
        my ( $name, $start ) = ( $1, pos($t) );
        my ( $depth, $i ) = ( 1, $start );
        while ( $depth && $i < length $t ) {
            my $c = substr( $t, $i++, 1 );
            $depth++ if $c eq '{';
            $depth-- if $c eq '}';
        }
        my $body = substr( $t, $start, $i - $start );
        next unless $body =~ m{replace\(/</g};
        $seen++;
        my @missing = grep { $body !~ $NEED{$_} } sort keys %NEED;
        is_deeply( \@missing, [], "$rel: $name() escapes all five characters" )
            or diag("add .replace() for: @missing - or call the page's esc() rather than writing another");
    }
}

# An empty sweep passes every check. The manager has a helper on nearly every
# page, so a count this low means the extraction broke, not that they went.
cmp_ok( $seen, '>=', 15, "the sweep found the manager's escaping functions ($seen)" );

done_testing();
