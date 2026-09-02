#!/usr/bin/perl
# SM739: an error a caller receives must not describe the machine it came from.
#
# EARNED THREE TIMES. The edge testing agent proposed this lint after finding a
# data error carrying an absolute path and the driver's vocabulary (SM713); it
# would also have caught the composed-PDF failure carrying /home/<account>/... 
# (SM738); and then it would have caught what SM738's own fix left behind - a
# date inside an echoed pandoc command line, found on the very next pass.
#
# THAT LAST ONE IS THE ARGUMENT. Sanitising somebody else's output is a losing
# position: the filter is only ever as good as the last thing that got past it.
# A lint over the SOURCE catches the class - a string being built for a caller
# that interpolates a path, a driver prefix, a date or a command - which is
# where the decision is actually made.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Where a caller-facing string is built. Not the whole tree: a comment, a log
# line or a test fixture may legitimately name a path, and flagging those would
# make this noisy enough to switch off - which is how a lint dies.
my @SURFACES = qw(
    lazysite-manager-api.pl lazysite-mcp.pl lazysite-dav.pl lazysite-data.pl
    lazysite-auth.pl lazysite-oauth.pl plugins/pandoc.pl
);
push @SURFACES, map { "lib/Lazysite/$_" }
    qw(Data/Tables.pm Manager/Common.pm Manager/Upload.pm);

my %FORBIDDEN = (
    'an absolute host path' => qr{["'][^"']*/(?:home|srv|var|usr|opt|tmp)/}, 
    'a driver prefix'       => qr/["'][^"']*\bDB[DI]::/,
    'an echoed command'     => qr/error\s*=>\s*[^;]*--metadata|error\s*=>\s*[^;]*\$cmd\b/,
);

my $checked = 0;
for my $rel (@SURFACES) {
    my $f = "$root/$rel";
    next unless -f $f;
    $checked++;
    open my $fh, '<', $f or do { fail("$rel: unreadable"); next };
    my ( $ln, %hit ) = (0);
    while ( my $l = <$fh> ) {
        $ln++;
        next if $l =~ /^\s*#/;                 # a comment may name a path
        next unless $l =~ /\berror\s*=>|\berror:\s/;   # caller-facing only
        for my $what ( keys %FORBIDDEN ) {
            push @{ $hit{$what} }, "$ln: " . substr( $l =~ s/^\s+//r, 0, 90 )
                if $l =~ $FORBIDDEN{$what};
        }
    }
    close $fh;

    for my $what ( sort keys %FORBIDDEN ) {
        is( scalar @{ $hit{$what} // [] }, 0,
            "$rel: no caller-facing error carries $what" )
            or diag( join "\n  ", '', @{ $hit{$what} } );
    }
}

cmp_ok( $checked, '>=', 9, 'the caller-facing surfaces were all found' );

subtest 'the cleaner that exists is used where it must be' => sub {
    my $t = do {
        open my $fh, '<', "$root/lib/Lazysite/Data/Tables.pm" or die $!;
        local $/; <$fh>;
    };
    # SM713 put one cleaner in front of every client-facing database error. A
    # raw $@ reaching a caller again is the regression this guards.
    my @raw = $t =~ /_err\(\s*"[^"]*\$\@"/g;
    is( scalar @raw, 0,
        'no database error hands a caller the raw $@ - _clean_db_error stands in front' )
        or diag('raw $@ in a caller-facing error: ' . scalar @raw);
};

subtest 'the converter failure says nothing at all about the host' => sub {
    my $p = do {
        open my $fh, '<', "$root/plugins/pandoc.pl" or die $!;
        local $/; <$fh>;
    };
    # SM739: fixed text, because a denylist over the converter's chatter kept
    # letting something new through - a path, then a date inside a command.
    like( $p, qr/the document could not be produced/,
        'the failure is a fixed sentence' );
    unlike( $p, qr/error => 'the conversion did not produce a document'\s*\n?\s*\. \( length \$why/,
        'and no longer interpolates the converter output' );
};

done_testing();
