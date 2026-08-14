#!/usr/bin/perl
# tools/lazysite-compliance.pl - the release compliance hook.
#
# WHY THIS EXISTS. The 2026-08-14 eight-dimension review sorted its findings by
# whether the thing assessed was defended by a MECHANISM or maintained by a
# PERSON, and the results separated perfectly: every gate, lint, generated
# document and enforced floor passed; every hand-kept record was a finding. The
# Declaration of Conformity was three stable releases behind, the
# significant-change register had gone stale over its own triggers, the feature
# timeline stopped eight releases back, the restore-rehearsal cadence had lapsed
# for four stable cycles, and the bench baseline predated two minor lines.
#
# Not one mechanised control had rotted. Not one hand-maintained record had
# survived six weeks of the release cadence.
#
# This project already knows the remedy - it found the same failure four times
# in its own test suite in one month (a hand-maintained list of templates, of
# scripts, of deb payload entries, of front-end configs) and converted each into
# something derived. This tool applies that move to the compliance records: it
# replaces a person remembering with a build failing.
#
# It checks CURRENCY, not correctness. It cannot know whether the threat model
# is any good; it can know that nobody has looked at it since two releases ago,
# which is the failure that actually happened.
#
# Run by tools/release.sh before a cut. --check exits non-zero on a blocking
# finding; --report prints the state and always exits 0.
use strict;
use warnings;
use FindBin;
use File::Basename qw(dirname);

my $ROOT    = dirname($FindBin::Bin);
my $MODE    = ( grep { $_ eq '--report' } @ARGV ) ? 'report' : 'check';
my $CHANNEL = 'edge';
for my $i ( 0 .. $#ARGV ) {
    $CHANNEL = $ARGV[ $i + 1 ] if $ARGV[$i] eq '--channel' && $ARGV[ $i + 1 ];
}

sub slurp {
    my ($rel) = @_;
    open my $fh, '<', "$ROOT/$rel" or return '';
    local $/;
    return <$fh>;
}

# A scalar out of a YAML-ish front-matter or fenced block. Deliberately simple:
# these are our own files in a known shape, not arbitrary YAML.
sub meta_field {
    my ( $text, $key ) = @_;
    return $1 if $text =~ /^\s*\Q$key\E:\s*["']?([^"'\n#]+?)["']?\s*(?:#.*)?$/m;
    return '';
}

sub vparse { return [ map { $_ + 0 } ( $_[0] =~ /(\d+)/g ) ] }

sub vcmp {
    my ( $a, $b ) = ( vparse( $_[0] // '' ), vparse( $_[1] // '' ) );
    for my $i ( 0 .. 2 ) {
        my $c = ( $a->[$i] // 0 ) <=> ( $b->[$i] // 0 );
        return $c if $c;
    }
    return 0;
}

my $VERSION = slurp('VERSION');
$VERSION =~ s/\s+//g;
die "lazysite-compliance: cannot read VERSION\n" unless length $VERSION;

my ( @fail, @warn, @ok );

sub blocking { push @fail, $_[0] }
sub advisory { push @warn, $_[0] }
sub good     { push @ok,   $_[0] }

# --- 1. the registers declare the version they were reviewed at -------------
#
# The whole point of anchoring on a version: a compliance claim is a claim about
# a version. "The register is current" is meaningless without saying current as
# of what.
for my $r (
    [ 'docs/compliance/OBLIGATIONS.md', 'reviewed_at_version', 'obligations register' ],
    [ 'docs/compliance/TECHNICAL-FILE.md', 'covers_version',   'technical file' ],
    )
{
    my ( $rel, $key, $name ) = @{$r};
    my $text = slurp($rel);
    unless ( length $text ) {
        blocking("$name: $rel is missing");
        next;
    }
    my $at = meta_field( $text, $key );
    if ( !length $at ) {
        blocking("$name: $rel has no $key");
    }
    elsif ( vcmp( $at, $VERSION ) < 0 ) {
        blocking(
            "$name: $key is $at, cutting $VERSION - walk $rel and update it");
    }
    else {
        good("$name reviewed at $at");
    }
}

# --- 2. the Declaration of Conformity tracks the stable line ----------------
#
# Only meaningful for a stable cut: the declaration attaches to a stable
# release, and three shipped without one being advanced.
{
    my $doc = slurp('docs/DECLARATION-OF-CONFORMITY.md');
    my ($stamped) = $doc =~ /Version\s*\|\s*([0-9]+\.[0-9]+\.[0-9]+)/;
    $stamped //= '';
    my $signed = ( $doc =~ /\(unsigned draft\)/ ) ? 0 : 1;

    if ( $CHANNEL eq 'stable' ) {
        my $behind = ( length $stamped && vcmp( $stamped, $VERSION ) < 0 ) ? 1 : 0;
        blocking("declaration of conformity: stamped '$stamped', cutting $VERSION")
            if $behind;
        blocking('declaration of conformity: unsigned') unless $signed;
        # Say so when it is fine. A gate that is silent on success cannot be
        # distinguished from a gate that did not run.
        good('declaration of conformity current and signed')
            if !$behind && $signed;
    }
    elsif ( !$signed || ( length $stamped && vcmp( $stamped, $VERSION ) < 0 ) ) {
        advisory( "declaration of conformity is stamped '$stamped'"
                . ( $signed ? '' : ' and unsigned' )
                . " - not blocking on $CHANNEL, blocking at the next stable" );
    }
    else { good('declaration of conformity current') }
}

# --- 3. the significant-change register covers this release -----------------
#
# ADR 0007 defers the first pentest engagement ON CONDITION that significant
# changes are assessed and recorded. A deferral whose conditions are not being
# recorded is not a deferral, so an unreferenced release weakens the waiver.
{
    my $sec     = slurp('docs/SECURITY.md');
    my @entries = ( $sec =~ /^### (\d{4}-\d{2}-\d{2})/mg );
    if ( !@entries ) {
        blocking('significant-change register: no dated entries found');
    }
    else {
        my ($latest) = sort { $b cmp $a } @entries;
        # Every SM number the changelog attributes to this release should be
        # findable in the register or explicitly out of scope. Cheap proxy: the
        # register must mention the version being cut, or carry an entry newer
        # than the previous release's changelog date.
        if ( $sec =~ /\Q$VERSION\E/ ) {
            good("significant-change register references $VERSION");
        }
        else {
            advisory( "significant-change register's newest entry is $latest "
                    . "and it does not mention $VERSION - confirm no trigger fired" );
        }
    }
}

# --- 4. the feature timeline has not fallen behind --------------------------
#
# Cross-referenced against the CHANGELOG's release headings rather than any
# three-part number in the file: FEATURES.md also cites perl versions and
# dependency versions, and a naive match reports "current" off a 5.40.1.
{
    my %release = map { $_ => 1 }
        ( slurp('CHANGELOG.md') =~ /^## (\d+\.\d+\.\d+)/mg );
    my $feat     = slurp('docs/FEATURES.md');
    my @vs       = grep { $release{$_} } ( $feat =~ /\b(\d+\.\d+\.\d+)\b/g );
    my ($newest) = sort { vcmp( $b, $a ) } @vs;
    $newest //= '';
    if    ( !length $newest ) { advisory('FEATURES.md: no release versions found') }
    elsif ( vcmp( $newest, $VERSION ) < 0 ) {
        advisory("FEATURES.md newest release entry is $newest, cutting $VERSION");
    }
    else { good('FEATURES.md current') }
}

# --- 5. the bench baseline is not older than the tree it gates --------------
{
    my $base = slurp('dist/config/bench-baseline.json');
    my ($cap) = $base =~ /"captured_at"\s*:\s*"([^"]+)"/;
    if ( !$cap ) { advisory('bench baseline: no captured_at') }
    else         { advisory("bench baseline captured $cap - re-capture at a stable cut")
            if $CHANNEL eq 'stable' }
}

# --- 6. a restore rehearsal exists for the current stable cycle -------------
{
    my $rel      = slurp('docs/RELIABILITY.md');
    my @dates    = ( $rel =~ /^\s*(\d{4}-\d{2}-\d{2})\s*\|/mg );
    my ($latest) = sort { $b cmp $a } @dates;
    # RELIABILITY.md commits to "at least once per stable release cycle", so the
    # rule is encoded against the stable releases themselves rather than an
    # arbitrary window: a rehearsal older than the newest STABLE cut means that
    # cycle went without one. On the tree this was written against, the newest
    # rehearsal was 2026-07-12 and four stable releases had shipped since.
    my ($last_stable) = sort { $b cmp $a }
        ( slurp('CHANGELOG.md') =~ /^##[^\n]*STABLE[^\n]*\((\d{4}-\d{2}-\d{2})\)/mgi );

    if    ( !$latest ) { advisory('RELIABILITY.md: no rehearsal entries found') }
    elsif ( !$last_stable ) {
        good("newest restore rehearsal $latest (no stable cut to measure against)");
    }
    elsif ( $latest lt $last_stable ) {
        my $msg = "restore rehearsal: newest is $latest, older than the last "
            . "stable cut ($last_stable) - the declaration requires one per "
            . 'stable release cycle';
        $CHANNEL eq 'stable' ? blocking($msg) : advisory("$msg (blocking at stable)");
    }
    else { good("newest restore rehearsal $latest") }
}

# --- 7. dated obligations that have entered their lead time -----------------
#
# Read the dates out of the obligations register and say which are close. The
# register is the source; this tool does not carry its own copy of the calendar.
{
    my $obl = slurp('docs/compliance/OBLIGATIONS.md');
    # Only rows still OPEN or STARTED carry a DUE date; a `met` row's date is
    # the date it was discharged, and warning on that is pure noise.
    my @rows = grep { /\|\s*(?:OPEN|STARTED)\s*\|/ }
        ( $obl =~ /^([^|\n]*\|[^\n]*\d{4}-\d{2}-\d{2}[^\n]*)$/mg );
    my @t     = gmtime(time);
    my $today = sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    my $soon  = 0;
    for my $row (@rows) {
        my ($date) = $row =~ /(\d{4}-\d{2}-\d{2})/;
        next unless $date;
        next if $date lt $today;
        next if $date gt _plus_days( $today, 120 );
        my ($what) = split /\s*\|\s*/, $row;
        $what =~ s/^\s+|\s+$//g;
        next unless length $what;
        $soon++;
        advisory("obligation within 120 days: $what ($date)");
    }
    good('no dated obligation inside 120 days') unless $soon;
}

sub _plus_days {
    my ( $ymd, $days ) = @_;
    my ( $y, $m, $d ) = split /-/, $ymd;
    my $t = eval {
        require Time::Local;
        Time::Local::timegm( 0, 0, 12, $d, $m - 1, $y ) + $days * 86_400;
    };
    return '9999-12-31' unless $t;
    my @g = gmtime($t);
    return sprintf '%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3];
}

# --- report -----------------------------------------------------------------

print "lazysite compliance check - version $VERSION, channel $CHANNEL\n\n";
print "  ok   $_\n" for @ok;
print "  WARN $_\n" for @warn;
print "  FAIL $_\n" for @fail;
printf "\n%d ok, %d warning(s), %d blocking\n", scalar @ok, scalar @warn,
    scalar @fail;

if ( $MODE eq 'report' ) {
    print "\n(report mode - exit 0 regardless)\n";
    exit 0;
}
if (@fail) {
    print "\nBlocking. These are records, not code - each is a few minutes of\n"
        . "work now and an audit finding later. See docs/compliance/OBLIGATIONS.md.\n";
    exit 1;
}
exit 0;

__END__

=head1 NAME

lazysite-compliance.pl - release-time currency check over the compliance records

=head1 SYNOPSIS

  perl tools/lazysite-compliance.pl --report
  perl tools/lazysite-compliance.pl --check --channel stable

=head1 DESCRIPTION

Checks that the hand-maintained compliance records have been walked for the
version being cut: the dated obligations register, the Annex VII technical file
index, the Declaration of Conformity, the significant-change register, the
feature timeline, the bench baseline and the restore-rehearsal register.

It checks B<currency>, not correctness - whether somebody has looked, not
whether what they wrote is right. That is the failure mode the 2026-08-14
eight-dimension review found: every mechanised control passed and every
hand-maintained record had gone stale.

Blocking findings differ by channel. A Declaration of Conformity behind the
version is advisory on C<edge> and blocking on C<stable>, because the
declaration attaches to a stable release.

=head1 SEE ALSO

F<docs/compliance/OBLIGATIONS.md>, F<docs/compliance/TECHNICAL-FILE.md>,
F<docs/review/2026-08-14-eight-dimension/>.

=cut
