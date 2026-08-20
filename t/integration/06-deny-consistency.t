#!/usr/bin/perl
# Single canonical agent-facing deny list. The deny set is expressed in three
# places that drifted apart historically (CAI reconciliation, 2026-06): the
# .well-known/ai-partner machine block, the onboarding brief, and the dav's
# enforcement. This test is the source of record: it pins the two agent-facing
# copies to one canonical list and checks the dav backs them, so they can no
# longer diverge silently.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# THE canonical agent-facing deny list. Change it here, in lock-step with the
# two rendered copies below, or this test fails.
my @CANONICAL = sort qw(
    /cgi-bin/ /manager/ /lazysite/auth/ /lazysite/cache/ /lazysite/logs/
    /lazysite/manager/ /lazysite/templates/ /lazysite/lazysite.conf *.pl
    /lazysite/forms/smtp.conf /lazysite/forms/handlers.conf
    /lazysite/forms/submissions/
);

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

# Pull the quoted entries (single- or double-quoted) out of a `deny: [ ... ]` /
# `"deny": [ ... ]` / `deny => [ ... ]` array.
sub deny_set {
    my ( $file, $marker ) = @_;
    my $text = slurp($file);
    $text =~ /$marker\s*\[(.*?)\]/s or die "no deny array in $file";
    my $body  = $1;
    my @items = ( $body =~ /"([^"]+)"/g, $body =~ /'([^']+)'/g );
    return [ sort @items ];
}

# SM190: the .well-known/ai-partner deny list is now CODE-SERVED from
# lazysite-processor.pl (_ai_partner_doc), not the static page - read it there.
my $wk = deny_set( "$root/lazysite-processor.pl",   qr/deny\s*=>/ );
my $br = deny_set( "$root/tools/lazysite-users.pl", qr/\bdeny:/ );

is_deeply( $wk, \@CANONICAL,
    'ai-partner (code-served) deny list matches the canonical set' );
is_deeply( $br, \@CANONICAL,
    'onboarding-brief deny list matches the canonical set' );
is_deeply( $wk, $br,
    'the two agent-facing deny lists are identical to each other' );

# SM421: the QUALIFIER travels with the list, and in lock-step.
#
# /lazysite/forms/submissions/ is listed as denied and WebDAV enforces it, but
# MCP and the control API treat it as a capability-gated carve-out - so a flat
# list reads as stronger than it is, and an operator concludes the store is
# unreachable to partners when it is not. The entry stays; the note beside it
# is what makes the list true. Both rendered copies carry it, and this pins
# them together exactly as the list itself is pinned - two copies of a
# qualifier drift the same way two copies of a list do.
sub note_for {
    my ( $file, $key ) = @_;
    my $text = slurp($file);
    return '' unless $text =~ /\Q$key\E["']?\s*(?:=>|:)\s*(.*?)(?:,
|
\s*\})/s;
    my $blob   = $1;
    my @parts  = ( $blob =~ /'([^']*)'/g, $blob =~ /"([^"]*)"/g );
    my $joined = join ' ', @parts;
    $joined =~ s/\s+/ /g;
    $joined =~ s/^\s+|\s+$//g;
    return $joined;
}

my $wk_note = note_for( "$root/lazysite-processor.pl",   '/lazysite/forms/submissions/' );
my $br_note = note_for( "$root/tools/lazysite-users.pl", '/lazysite/forms/submissions/' );

like( $wk_note, qr/WebDAV/i,
    'the ai-partner deny list qualifies the submission store' )
    or diag('A deny entry that is not absolute has to say so where it is read.');
like( $wk_note, qr/read_submissions/,
    'and names the capability that reaches it' );
like( $br_note, qr/WebDAV/i,          'the onboarding brief carries the qualifier too' );
like( $br_note, qr/read_submissions/, 'and names the same capability' );
is( $wk_note, $br_note,
    'the two qualifiers are word-for-word identical - a note that drifts is '
        . 'the defect it was written to fix, one level down' );


# The dav is the enforcement: confirm its default blocked_paths cover the
# non-lazysite/ entries the agent-facing list advertises (the whole lazysite/
# subtree is denied structurally, so only cgi-bin + the docroot manager need
# to appear as explicit blocked_paths).
my $dav = slurp("$root/lazysite-dav.pl");
$dav =~ /blocked_paths\s*=>\s*\[\s*qw\((.*?)\)/s
    or die "no default blocked_paths in lazysite-dav.pl";
my %bp = map { $_ => 1 } split ' ', $1;
ok( $bp{'cgi-bin'}, 'dav blocked_paths includes cgi-bin' );
ok( $bp{'manager'}, 'dav blocked_paths includes the docroot manager' );

# whoami reports scope.deny to agents; it must be the same canonical set, or
# an agent trusting whoami sees a different denied set than the dav enforces
# (e.g. believing all of lazysite/forms/ is writable bar the smtp password).
my $mapi_src = slurp("$root/lazysite-manager-api.pl");
$mapi_src =~ /deny\s*=>\s*\[(.*?)\]/s
    or die "no whoami scope.deny in lazysite-manager-api.pl";
is_deeply( [ sort ( $1 =~ /'([^']+)'/g ) ], \@CANONICAL,
    'whoami scope.deny matches the canonical set' );

done_testing();
