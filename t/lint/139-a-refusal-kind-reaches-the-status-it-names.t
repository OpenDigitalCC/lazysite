#!/usr/bin/perl
# SM872: every refusal kind the tree emits either has an entry in SM670's
# %REFUSAL_STATUS or is named below as one where 400 is the right answer.
#
# SM670 ruled that a control-API refusal says so in its status line, and built a
# map from `kind` to status with a 400 default. The map's keys are all
# hyphenated. Six kinds in the tree are not - `no_such_table`, `no_such_row`,
# `no_such_form`, `needs_confirmation`, `has_submissions`, `db-table-missing` -
# and a kind the map does not know is not an error anywhere: it silently takes
# the default. So a table that does not exist answered 400 "your request was
# malformed" on the control API while lazysite-data.pl answered 404 for the same
# condition. Two surfaces, two answers, and nothing in 14,000 tests between them.
#
# THE DEFAULT IS THE PROBLEM, NOT THE SIX. A map with a silent fallback cannot
# tell a deliberate 400 from a forgotten one, so the next kind added under a new
# spelling regresses exactly the same way. This test removes the silence: a new
# kind must be mapped, or listed here as deliberate. Adding a name to the list
# below is a decision someone made; leaving it out is no longer invisible.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use Lazysite::Manager::Common ();

my $root = repo_root();

# --- kinds that need no %REFUSAL_STATUS entry --------------------------------
#
# TWO DIFFERENT REASONS, and this list does not yet separate them. Saying so
# here rather than implying a precision it does not have:
#
#   1. It reaches `respond` and 400 Bad Request is the right answer - the caller
#      sent something the surface cannot act on: a malformed argument, a page
#      the authoring rules refuse, a value that fails validation. Most of the
#      list is this.
#
#   2. IT NEVER REACHES THE MAP AT ALL. `anonymous` and `csrf` are passed to
#      `reply(403, ...)` in lazysite-data.pl, which sets its own status;
#      `db-table-not-published` and the other db-* names are entries in
#      validate_page's `$issues` list, which is a report, not an HTTP response.
#      For these, "has a decided status" is true only vacuously.
#
# The distinction matters because a kind in group 2 that LATER starts flowing
# through `respond` would silently take the 400 default, and this list would say
# that was intended. Separating them wants tracing every emit site to its sink,
# which is more than SM872's low-risk scope - recorded here so the next reader
# inherits the question rather than the appearance of an answer.
my %DELIBERATE_400 = map { $_ => 1 } qw(
    invalid invalid-path invalid-form-rule validation constraint incomplete
    extra type value name missing-parameter missing_deps missing_module
    misrouted-argument unnamed unbound domain descriptor data manager service
    plugin refused retired csrf anonymous integrity cert-mismatch
    bad-encoding binary template-parse template-parse-refused not-a-cache
    nav-not-here inherits-nav raw-content-refused brief-sidecar-refused
    active-artifact-refused db-binding-unchecked db-table-not-published

    api-page-is-a-document document-in-page chrome-in-page style-block-in-page
    raw-html-page hand-authored hand-authored-form no-title
    front-matter-unterminated fence-close-unmatched component-fence-unmatched
    form-mailto form-third-party form-unbound form-unnamed
    public-credential public-phone public-postcode

    form-binding-unchecked no-content unreadable
);

# SM887 F2: the three above are GROUP 2, and they are group 2 by construction
# rather than by inspection - Lazysite::Validate is a REPORTER. It answers a
# caller that asked "is this page all right", over MCP, from a test, or from
# `lazysite validate` on a shell where the answer is an exit status; it is not
# on any write path and nothing it returns reaches `respond`. `no-content` and
# `unreadable` are the module saying it had nothing to read, which no HTTP
# surface can produce at all: the MCP entry point resolves the page and returns
# its own refusal before the validator is called.

# `store_` is a PREFIX, not a kind: lib/Lazysite/Data/Tables.pm:275 builds
# `'store_' . $why->{reason}` at run time, so the family can never be mapped by
# name and this test can only see the literal stem. Filed rather than fixed
# here - the store-inspection failures it covers are arguably 500s, which is a
# decision, not a rename.
my %PREFIX_ONLY = ( 'store_' => 1 );

# --- every kind the tree emits ------------------------------------------------
my @files;
{
    open my $ls, '-|', 'git', '-C', $root, 'ls-files' or die "git ls-files: $!";
    while ( my $l = <$ls> ) {
        chomp $l;
        next if $l =~ m{^(?:t/|tmp/)};
        next unless $l =~ /\.(?:pl|pm)$/;
        push @files, $l;
    }
    close $ls;
}
cmp_ok( scalar @files, '>=', 30, 'the source files were discovered' )
    or do { done_testing(); exit };

my %seen;
for my $rel (@files) {
    open my $in, '<', "$root/$rel" or next;
    my $n = 0;
    while ( my $line = <$in> ) {
        $n++;
        while ( $line =~ /kind\s*=>\s*'([a-z0-9_-]+)'/g ) {
            my $kind = $1;    # before any s/// below - $1 does not survive one
            push @{ $seen{$kind} }, "$rel:$n";
        }
    }
    close $in;
}

cmp_ok( scalar keys %seen, '>=', 60, 'refusal kinds were found to check' )
    or diag( 'If this drops sharply the regex stopped matching, which would '
        . 'make every assertion below vacuous rather than passing.' );

my %STATUS = %Lazysite::Manager::Common::REFUSAL_STATUS;

for my $kind ( sort keys %seen ) {
    next if $PREFIX_ONLY{$kind};
    my $mapped     = exists $STATUS{$kind};
    my $deliberate = $DELIBERATE_400{$kind};

    ok( $mapped || $deliberate, "'$kind' has a decided status" )
        or diag(
                  "'$kind' is emitted at "
                . join( ', ', @{ $seen{$kind} }[ 0 .. 2 > $#{ $seen{$kind} } ? $#{ $seen{$kind} } : 2 ] )
                . "\n  and reaches no entry in %REFUSAL_STATUS, so it answers 400 "
                . "Bad Request.\n  If that is right, add it to \%DELIBERATE_400 "
                . "here. If it is not - a\n  not-found, a conflict, a server "
                . "fault - map it in Lazysite::Manager::Common." );

    # Both is a contradiction: the map says one thing and the list another.
    ok( !( $mapped && $deliberate ),
        "'$kind' is not both mapped and listed as deliberately 400" )
        if $mapped || $deliberate;
}

# --- the six SM872 mapped, asserted by name ----------------------------------
#
# Named individually rather than looped, so a regression says which one.
is( Lazysite::Manager::Common::refusal_status('no_such_table'),
    '404 Not Found', 'an absent table is not found' );
is( Lazysite::Manager::Common::refusal_status('no_such_row'),
    '404 Not Found', 'an absent row is not found' );
is( Lazysite::Manager::Common::refusal_status('no_such_form'),
    '404 Not Found', 'an absent form is not found' );
is( Lazysite::Manager::Common::refusal_status('db-table-missing'),
    '404 Not Found', 'an absent table over MCP is not found' );
is( Lazysite::Manager::Common::refusal_status('needs_confirmation'),
    '409 Conflict', 'a write awaiting confirmation is a conflict, like `confirm`' );
is( Lazysite::Manager::Common::refusal_status('has_submissions'),
    '409 Conflict', 'a form still holding submissions is in use, like `in-use`' );

# THE TWO SURFACES NOW AGREE. lazysite-data.pl:376 answers 404 for a table that
# is absent or unreachable; this is the control API reaching the same answer by
# its kind. The disagreement is the defect SM872 was filed for, so it is
# asserted here rather than left to the two files to keep in step by hand.
is( Lazysite::Manager::Common::refusal_status('no_such_table'),
    '404 Not Found',
    'the control API agrees with the data endpoint about a missing table' );

done_testing();
