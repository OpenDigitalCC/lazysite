#!/usr/bin/perl
# tools/backlog.pl - list the feature-request backlog from the status headers
# every docs/feature-requests/SM*.md carries (enforced by
# t/lint/09-feature-request-status.t).
#
#   perl tools/backlog.pl            # open work only (partial|parked|candidate)
#   perl tools/backlog.pl --all      # everything, shipped and superseded too
#   perl tools/backlog.pl --json     # the same set as JSON, for tooling
#
# SM658: TWO DIRECTORIES, ONE CORPUS. Terminal filings (shipped, superseded)
# live in docs/feature-requests/archive/ so the top level shows open work at a
# glance. Both are read here: archiving changed where a filing sits, not
# whether it is part of the record, and --all that stopped at the top level
# would report 489 documents as gone.
#
# SM658: THE RELATION GRAPH IS DERIVED, NEVER STORED. 543 of 544 filings
# already name another SM in their prose - 3,572 references in all - so the
# graph exists; it was simply not machine-readable. Extracting it here rather
# than writing a `relates:` field into every file is deliberate: a field copied
# out of the body is a second copy of one fact, and would drift from the prose
# the moment either was edited. That is the defect SM654 filed against the
# hand-kept `unlocks` map, and it would have been a poor lesson to learn twice.
#
# An author who wants to assert a relationship the prose does NOT state may add
# `relates:` to the frontmatter; it is unioned in below. Nothing is required to.
#
# Core-only Perl; no CPAN deps.
use strict;
use warnings;
use FindBin;

my $all  = grep { $_ eq '--all' } @ARGV;
my $json = grep { $_ eq '--json' } @ARGV;
my %OPEN = map  { $_ => 1 } qw(partial parked candidate);

my $DIR = "$FindBin::Bin/../docs/feature-requests";

# Every filing, wherever it sits. Sorted by SM number rather than by path, so
# the archive does not sort as a separate block.
my @files = ( glob("$DIR/SM*.md"), glob("$DIR/archive/SM*.md") );

# SM658: KEYED BY PATH, NOT BY NUMBER, and the difference is not academic.
# Two numbers on this corpus carry two documents each - SM076 (mcp-site-
# management and oauth) and SM270 (two takes on the same permission fight) -
# so a hash keyed by id drops one of each without a word. An index that
# silently loses a document is worse than no index, because a reader trusts
# it. Duplicates are reported below instead.
my @records;
my %seen_id;

for my $f ( sort @files ) {
    open my $fh, '<', $f or next;
    my $text = do { local $/; <$fh> };
    close $fh;
    my ($fm) = $text =~ /\A---\n(.*?)^---\n/ms;
    next unless defined $fm;
    my ($id)     = $f  =~ /(SM\d{3}[a-z]?)[^\/]*$/;
    my ($status) = $fm =~ /^status:\s*(\S+)/m;
    my ($title)  = $fm =~ /^title:\s*"?(.*?)"?\s*$/m;
    my ($note)   = $fm =~ /^status-note:\s*"(.+)"\s*$/m;
    next unless defined $status && defined $id;
    $title =~ s/^SM\d{3}[a-z]?\s*[-:\x{2014}]\s*//u if defined $title;

    # The body is everything after the frontmatter: a filing's own number
    # appears in its title and would otherwise make every item relate to itself.
    my ($body) = $text =~ /\A---\n.*?^---\n(.*)\z/ms;
    my %rel;
    $rel{$_} = 1 for ( ( $body // '' ) =~ /\b(SM\d{3})\b/g );
    # A relationship the author asserts that the prose does not make obvious.
    if ( my ($declared) = $fm =~ /^relates:\s*(.+)$/m ) {
        $rel{$_} = 1 for ( $declared =~ /\b(SM\d{3})\b/g );
    }
    delete $rel{ substr( $id, 0, 5 ) };

    # Derived first: inline, the long match makes perltidy align every value in
    # the hash to it, which is unreadable for the sake of one field.
    my $rel_path = ( $f =~ m{(docs/feature-requests/.*)$} )[0] // $f;

    push @records, {
        id     => $id,
        status => $status,
        title  => $title // '',
        note   => $note  // '',
        path   => $rel_path,
        _rel   => \%rel,
    };
    push @{ $seen_id{$id} }, $records[-1]{path};
}

# A reference to an SM that was never filed is a dangling link, not a relation -
# usually a number quoted from a commit message or an error string. Dropped
# here rather than in the loop above, because the full set is only known now.
for my $r (@records) {
    $r->{relates} = [ sort grep { $seen_id{$_} } keys %{ $r->{_rel} } ];
    delete $r->{_rel};
}

my @rows = sort { $a->{id} cmp $b->{id} || $a->{path} cmp $b->{path} } @records;
@rows = grep { $OPEN{ $_->{status} } } @rows unless $all;

if ($json) {
    # Hand-rolled, because this file promises no CPAN dependency and JSON::PP
    # is core but the rest of this tool reads as plain text handling.
    my $esc = sub {
        my ($s) = @_;
        $s = '' unless defined $s;
        $s =~ s/\\/\\\\/g;
        $s =~ s/"/\\"/g;
        $s =~ s/\n/\\n/g;
        $s =~ s/\r/\\r/g;
        $s =~ s/\t/\\t/g;
        $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord $1)/ge;
        return $s;
    };
    print "[\n";
    for my $i ( 0 .. $#rows ) {
        my $r = $rows[$i];
        printf
            qq[  {"id":"%s","status":"%s","title":"%s","note":"%s","path":"%s","relates":[%s]}%s\n],
            $esc->( $r->{id} ),
            $esc->( $r->{status} ),
            $esc->( $r->{title} ),
            $esc->( $r->{note} ),
            $esc->( $r->{path} ),
            join( ',', map { '"' . $esc->($_) . '"' } @{ $r->{relates} } ),
            ( $i == $#rows ? '' : ',' );
    }
    print "]\n";
    exit 0;
}

printf "%-7s %-10s %s\n", 'Id', 'Status', 'Item';
printf "%-7s %-10s %s\n", '--', '------', '----';
for my $r (@rows) {
    printf "%-7s %-10s %s\n", $r->{id}, $r->{status}, $r->{title};
    printf "%-18s %s\n", '', $r->{note} if length $r->{note};
}
print "\n", scalar @rows, ( $all ? " item(s) total.\n" : " open item(s).\n" );

# Loud, on STDERR, so a listing stays pipeable while the collision is not
# something a reader has to notice for themselves.
for my $id ( sort keys %seen_id ) {
    next if @{ $seen_id{$id} } < 2;
    warn "NOTE: $id names "
        . scalar( @{ $seen_id{$id} } )
        . " documents - both are indexed: "
        . join( ', ', @{ $seen_id{$id} } ) . "\n";
}
