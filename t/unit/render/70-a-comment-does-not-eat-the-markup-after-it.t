#!/usr/bin/perl
# SM689: an HTML comment must not swallow the markup around it.
#
# Text::MultiMarkdown pairs `<!--` with a LATER `-->` when it hashes HTML
# blocks, and everything between the two is DISCARDED - not escaped, not
# mangled, gone. A page that explains itself in comments between its markup
# loses that markup, with no error raised anywhere.
#
# The symptom is always somebody else's bug. On the Data page it read as
# "Could not load rows: can't access property style, panel is null": a script
# looking for an element the markdown pass had eaten. The page source was
# correct, the JavaScript was correct, and every source-level test passed -
# because the loss happens between the source and the browser, which is where
# no test was looking.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require Text::MultiMarkdown; 1 }
        or plan skip_all => 'Text::MultiMarkdown not available';
}

my $processor = "$FindBin::Bin/../../../lazysite-processor.pl";
plan skip_all => "no $processor" unless -f $processor;

my $src = do { open my $fh, '<', $processor or die $!; local $/; <$fh> };

# THE PROPERTY, not the implementation: comments are protected from the
# markdown pass the same way scripts and styles already are.
like( $src, qr/\$body =~ s\{\(<!--\.\*\?-->\)\}/,
    'the markdown filter protects HTML comments from the markdown pass' )
    or diag( 'Without this the matcher pairs the wrong <!-- with a later -->, '
        . 'and every block between them is discarded.' );

sub render {
    my ( $body, $protect_comments ) = @_;
    my @raw;
    $body =~ s{(<(script|style)\b[^>]*>)(.*?)(</\2>)}{
        my $p = "RAWBLOCK_" . scalar(@raw) . "_END";
        push @raw, "$1$3$4";
        $p
    }gsei;
    if ($protect_comments) {
        $body =~ s{(<!--.*?-->)}{
            my $p = "RAWBLOCK_" . scalar(@raw) . "_END";
            push @raw, "$1";
            $p
        }gse;
    }
    my $h = Text::MultiMarkdown->new( use_fenced_code_blocks => 1 )->markdown($body);
    for my $i ( 0 .. $#raw ) { my $p = "RAWBLOCK_${i}_END"; $h =~ s/\Q$p\E/$raw[$i]/ }
    return $h;
}

# THE REPRODUCER IS THE REAL PAGE, deliberately.
#
# A hand-written minimal case does NOT reproduce this: two comments around two
# divs survive the round trip perfectly well. The pairing only goes wrong once
# a page has enough blocks and comments interleaved for the matcher to reach
# past one block to a later `-->`, which is why the defect survived every
# minimal test anyone would have thought to write - including mine.
#
# So the fixture is `starter/manager/data.md`, the page that actually broke.
# If a future edit to that page stops it reproducing, this test says so rather
# than passing quietly, because the fix would then rest on nothing.

sub data_page {
    my $data = "$FindBin::Bin/../../../starter/manager/data.md";
    return undef unless -f $data;
    my $body = do { open my $fh, '<', $data or die $!; local $/; <$fh> };
    $body =~ s/\A---\n.*?\n---\n//s;
    return $body;
}

my @WATCH = qw(rows-panel rows-table rows-title rows-note import-panel);

subtest 'the defect is real, so the fix is not decoration' => sub {
    my $body = data_page();
    plan skip_all => 'no data.md' unless defined $body;
    my $before = render( $body, 0 );
    my @lost = grep { $before !~ /id="\Q$_\E"/ } @WATCH;
    ok( scalar(@lost),
        'without the protection the Data page really does lose markup' )
        or diag( 'Nothing was lost, so this page no longer reproduces the '
            . 'pairing bug and this test is no longer proving the fix. Find a '
            . 'page that does, or establish that MultiMarkdown has changed, '
            . 'before trusting the protection on this evidence.' );
    note( "lost without protection: @lost" ) if @lost;
};

# The page that was actually broken, asserted by name. A generic case can pass
# while the real page still loses markup, because the real page's comments sit
# in positions no minimal case reproduces.
subtest 'the Data page keeps the elements its own script looks for' => sub {
    my $data = "$FindBin::Bin/../../../starter/manager/data.md";
    plan skip_all => "no $data" unless -f $data;
    my $body = do { open my $fh, '<', $data or die $!; local $/; <$fh> };
    $body =~ s/\A---\n.*?\n---\n//s;
    my $out = render( $body, 1 );
    for my $id (qw(rows-panel rows-table rows-title rows-note descriptor-panel)) {
        like( $out, qr/id="\Q$id\E"/, "$id reaches the browser" );
    }
};

done_testing();
