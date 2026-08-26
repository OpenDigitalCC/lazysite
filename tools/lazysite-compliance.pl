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

my $ROOT     = dirname($FindBin::Bin);
my $MODE     = ( grep { $_ eq '--report' } @ARGV ) ? 'report' : 'check';
my $CHANNEL  = 'edge';
my $CALENDAR = ( grep { $_ eq '--calendar' } @ARGV ) ? 1 : 0;
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

my ( @fail, @warn, @ok, @masked );

sub blocking { push @fail, $_[0] }
sub advisory { push @warn, $_[0] }
sub good     { push @ok,   $_[0] }

# HUMAN SIGN-OFF, AND WHY IT IS A SWITCH.
#
# Some findings cannot be closed by a commit: walking the obligations register,
# re-reading the technical file, signing a declaration of conformity. Each needs
# a person to have actually done it, and the only honest record of that is that
# person saying so. docs/compliance/SIGNOFF.md holds their answer.
#
# MASKED IS NOT PASSED. A masked finding is printed in full, counted, and
# labelled MASKED - it simply does not stop the build. Nothing is hidden, and
# flipping the switch reveals no new information; the findings were on screen
# the whole time. That is what separates this from lowering a standard.
#
# ABSENT MEANS REQUIRED. A missing or unreadable switch is treated as `yes`, so
# deleting the file cannot quietly disable a gate - the same fail-closed rule
# the update channel follows (SM356, where it failed OPEN and a typo granted).
sub _signoff_required {
    my $text = slurp('docs/compliance/SIGNOFF.md');
    return 1 unless length $text;
    my $v = meta_field( $text, 'signoff_required' );
    return 1 unless length $v;
    return ( lc $v eq 'no' || lc $v eq 'false' || $v eq '0' ) ? 0 : 1;
}
my $SIGNOFF = _signoff_required();

# ADR 0010: a CERTIFIED cut requires the sign-offs regardless of the switch.
# The channel IS the statement that the records were walked - a certified
# build whose person-only findings were masked by a switch left at 'no' would
# be the label-lie class this project keeps burning down. Below certified the
# switch keeps its meaning: an operator may voluntarily demand the records on
# any cut, and a release manager may defer them on any cut that is not
# claiming certification.
if ( $CHANNEL eq 'certified' && !$SIGNOFF ) {
    $SIGNOFF = 1;
    print "note: signoff_required forced on - channel 'certified' claims "
        . "walked records (ADR 0010)\n";
}

# A finding only a person can close. Blocks when sign-off is required, and is
# reported as MASKED when the release manager has said it is not yet.
sub signoff { $SIGNOFF ? push( @fail, $_[0] ) : push( @masked, $_[0] ); return }

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
        next;
    }
    if ( vcmp( $at, $VERSION ) < 0 ) {
        signoff(
            "$name: $key is $at, cutting $VERSION - walk $rel and update it");
        next;
    }

    # SM298: THE VERSION FIELD IS A PROMISE; THE HASH MAKES IT AN OBSERVATION.
    #
    # The check above catches a record nobody UPDATED. It cannot catch a record
    # whose version field was bumped without anybody re-reading the document -
    # the same failure one level down, and the shape this project has now found
    # six times.
    #
    # So the record also carries a hash of its own body. Bumping the version
    # without touching the content leaves the hash matching, and the gate can
    # then say what is actually true: the document did not change for this
    # release. Whether that is FINE is the reviewer's call - an obligations
    # register can legitimately be unchanged - so this reports rather than
    # blocks. What it removes is the ability to claim a re-read that did not
    # happen without the claim being visible.
    #
    # The hash covers the body BELOW the front matter, so stamping the version
    # and the date does not change it. Otherwise every stamp would invalidate
    # the thing it was stamping, which is the trap in the obvious version.
    my $body = $text;
    $body =~ s/\A---\n.*?\n---\n//s;         # front matter out
    $body =~ s/^\s*$key\s*:.*$//mg;          # and the stamped fields themselves
    $body =~ s/^\s*reviewed_on\s*:.*$//mg;

    # AND content_sha ITSELF, or the hash covers the field that records it:
    # stamping a value changes the body, which changes the value. The first
    # version of this did exactly that and reported "content changed" on a
    # document whose only change was the stamp.
    $body =~ s/^\s*content_sha\s*:.*$//mg;
    require Digest::SHA;
    my $now = substr( Digest::SHA::sha256_hex($body), 0, 16 );

    my $recorded = meta_field( $text, 'content_sha' );
    if ( !length $recorded ) {
        advisory( "$name: no content_sha - add `content_sha: $now` so a version "
                . 'bump without a re-read becomes visible (SM298)' );
        good("$name reviewed at $at");
    }
    elsif ( $recorded eq $now ) {
        advisory( "$name: unchanged since it was reviewed at $at - the version "
                . 'field moved and the document did not' );
        good("$name reviewed at $at (content unchanged)");
    }
    else {
        good("$name reviewed at $at (content changed; content_sha: $now)");
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

    # ADR 0010 (2026-08-20): the declaration attaches to a CERTIFIED cut, not a
    # stable one - stable ships supported software; certification is the
    # deliberate act of walking the records. This is where signoff_required
    # bites.
    if ( $CHANNEL eq 'certified' ) {
        my $behind = ( length $stamped && vcmp( $stamped, $VERSION ) < 0 ) ? 1 : 0;
        signoff("declaration of conformity: stamped '$stamped', cutting $VERSION")
            if $behind;
        signoff('declaration of conformity: unsigned') unless $signed;
        # Say so when it is fine. A gate that is silent on success cannot be
        # distinguished from a gate that did not run.
        good('declaration of conformity current and signed')
            if !$behind && $signed;
    }
    elsif ( !$signed || ( length $stamped && vcmp( $stamped, $VERSION ) < 0 ) ) {
        advisory( "declaration of conformity is stamped '$stamped'"
                . ( $signed ? '' : ' and unsigned' )
                . " - not blocking on $CHANNEL, blocking at a certified cut" );
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

    # SM609: THE DOCUMENT'S OWN STAMPS, not just its version list.
    #
    # The check above reads the timeline entries. FEATURES.md also says which
    # version it is current to, twice - in its subtitle and in its closing
    # note - and those are prose that nothing was reading. The 0.11.0 prep
    # found the subtitle claiming v0.9.14 and the footer v0.10.19 while the
    # timeline had been brought to 0.10.34: this check said "current" the
    # whole time, because it was looking at the one part that had been
    # maintained.
    #
    # Advisory, like its neighbour: a stale stamp misleads a reader and blocks
    # nothing.
    for my $stamp ( $feat =~ /(?:as of|current\s*\n?to)\s+v(\d+\.\d+\.\d+)/g ) {
        next unless vcmp( $stamp, $VERSION ) < 0;
        advisory( "FEATURES.md still says it is current to v$stamp, "
                . "cutting $VERSION" );
    }
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
        # ADR 0010: blocks the CERTIFIED cut (the declaration is a certified-
        # tier artefact); the cycle is still measured against stable cuts,
        # which is the cadence RELIABILITY.md commits to.
        $CHANNEL eq 'certified' ? blocking($msg) : advisory("$msg (blocking at certified)");
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
        # 30 days by default, 120 with --calendar. The gate's job is CURRENCY;
        # a diary entry four months out that fires on every single run stops
        # being read within a fortnight, and a warning nobody reads is the
        # failure this tool exists to prevent.
        next if $date gt _plus_days( $today, $CALENDAR ? 120 : 30 );
        my ($what) = split /\s*\|\s*/, $row;
        $what =~ s/^\s+|\s+$//g;
        next unless length $what;
        $soon++;
        # Name the window that was actually applied. Hard-coding "120 days"
        # here made the default run report a 27-day-away obligation as
        # "within 120 days", which reads as slack that does not exist.
        advisory( sprintf 'obligation within %d days: %s (%s)',
            $CALENDAR ? 120 : 30, $what, $date );
    }
    good( sprintf 'no dated obligation inside %d days', $CALENDAR ? 120 : 30 )
        unless $soon;
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
print "  ok   $_\n"   for @ok;
print "  WARN $_\n"   for @warn;
print "  MASKED $_\n" for @masked;
print "  FAIL $_\n"   for @fail;
printf "\n%d ok, %d warning(s), %d masked, %d blocking\n", scalar @ok,
    scalar @warn, scalar @masked, scalar @fail;

# Printed whenever anything is masked, and it names the file rather than
# describing it: a reader who disagrees with the decision needs to know where
# the decision lives, and a reader who does not should still be told one was
# made. A masked count that appeared without explanation would be worse than
# the finding it covers.
if (@masked) {
    print "\nMasked findings need a PERSON, not a commit, and the release\n"
        . "manager has recorded that sign-off is not yet required:\n"
        . "  docs/compliance/SIGNOFF.md  (signoff_required: no)\n"
        . "They are listed above in full and are not blocking. Set it to 'yes'\n"
        . "for a release carrying a conformity declaration - in practice, the\n"
        . "next stable.\n";
}

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
  perl tools/lazysite-compliance.pl --check --channel certified
  perl tools/lazysite-compliance.pl --report --calendar   # obligations 120 days out

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
version is advisory on C<edge>, C<beta> and C<stable>, and blocking on
C<certified>, because the declaration attaches to a certified release
(ADR 0010): stable ships supported software, certification is the deliberate
act of walking these records.

=head1 SEE ALSO

F<docs/compliance/OBLIGATIONS.md>, F<docs/compliance/TECHNICAL-FILE.md>,
F<docs/review/2026-08-14-eight-dimension/>.

=cut
