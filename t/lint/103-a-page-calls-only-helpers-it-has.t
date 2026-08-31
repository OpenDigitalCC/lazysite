#!/usr/bin/perl
# A manager page's script calls only escapers that exist on that page.
#
# config.md's style preview called escHtml(). That page defines esc(), and the
# layout defines neither globally - so the call threw ReferenceError, the modal
# was never appended, and the Preview button looked simply inert. Nothing
# logged, nothing rendered, and the source read correctly: the two names are
# both plausible and the manager uses BOTH across different pages.
#
# This checks the escaper family only. A general "is this function defined"
# lint needs a JavaScript parser; this needs a list of two names and catches
# the mistake that actually happened.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";
my @names = qw(esc escHtml);

# Names the shared layout puts on window, which any page may call.
my $layout = do {
    open my $fh, '<', "$root/starter/lazysite/manager/layout.tt" or die $!;
    local $/; <$fh>;
};
my %global = map { $_ => 1 }
    grep { $layout =~ /\bwindow\.\Q$_\E\s*=/ || $layout =~ /function\s+\Q$_\E\s*\(/ } @names;

my @bad;
for my $f ( sort glob "$root/starter/manager/*.md" ) {
    ( my $page = $f ) =~ s{.*/}{};
    my $src = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    my ($js) = $src =~ /<script>(.*)<\/script>/s;
    next unless defined $js;
    $js =~ s{//[^\n]*}{}g;    # a name in a comment is not a call

    for my $n (@names) {
        next if $global{$n};
        next unless $js =~ /(?<![\w.])\Q$n\E\s*\(/;          # called here
        next if $js =~ /function\s+\Q$n\E\s*\(/;             # defined here
        next if $js =~ /(?:var|let|const)\s+\Q$n\E\s*=/;     # or assigned here
        push @bad, "$page: calls $n() and does not define it";
    }
}

is( "@bad", '', 'every escaper a page calls is one it defines' )
    or diag( join( "\n  ", '', @bad )
        . "\n\nA ReferenceError stops the whole handler: the control does\n"
        . "nothing, nothing is logged, and the source looks right. Use the\n"
        . "name this page actually defines." );

done_testing();
