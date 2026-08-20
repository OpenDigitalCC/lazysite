#!/usr/bin/perl
# SM435: the capability descriptor is the ONLY per-capability account of the
# WebDAV boundary that anyone outside the code can read. A partner cannot
# determine which capability grants an access by experiment - the only
# instrument available, try it and see, reports the UNION of everything they
# hold - so a wrong descriptor is not a documentation defect. It is the only
# map being wrong, with nothing to notice.
#
# Nothing noticed for that reason: 0.8.1 moved lazysite/nav.conf to manage_nav
# and lazysite/forms/<name>.conf to manage_forms, wrote both new entries, and
# left the old manage_config entry in place. It survived every release since.
#
# This checks the two sides against each other in the one place a partner
# actually meets them both: every WebDAV denial names the capability it
# requires, so the deny reason IS the enforcement's own statement of the rule.
#
# IT MUST BE SET EQUALITY, and that is the whole point of the test. A
# membership check - "the capability the denial names appears in the
# descriptor" - passes cleanly against the very defect this was written for,
# because manage_nav DOES list nav.conf; the surplus manage_config entry is
# invisible to it. The failure was an EXTRA claim, not a missing one.
#
# Sabotage record (SM435, 2026-08-20): restoring 'lazysite/nav.conf' to
# manage_config's webdav list fails this test. Written the loose way, it does
# not - which is why it is written this way.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Lazysite::Capabilities ();

my $dav = "$FindBin::Bin/../../lazysite-dav.pl";
open my $fh, '<', $dav or plan skip_all => "cannot read $dav: $!";
my $src = do { local $/; <$fh> };
close $fh;

# Each governed path in authorise() states its own rule as a deny reason.
# Pull (path, capabilities-named) straight out of those strings.
my %enforced;
while ( $src =~ /editing \s+ (lazysite\/[A-Za-z0-9_<>\$.\/-]+) \s+ requires \s+ the \s+
                 ([a-z_]+(?:\s+or\s+[a-z_]+)*) \s+ capability/gx )
{
    my ( $path, $caps ) = ( $1, $2 );
    # The deny reason interpolates the form name ($name); the descriptor
    # spells the same placeholder <name>. Normalise so the two compare.
    $path =~ s/\$name/<name>/;
    $enforced{$path} = { map { $_ => 1 } grep { $_ ne 'or' } split /\s+/, $caps };
}

plan skip_all => 'no per-path WebDAV deny reasons found' unless %enforced;

# The descriptor's side: which capabilities CLAIM each path over webdav.
my $desc = Lazysite::Capabilities::describe();
my $caps = $desc->{capabilities} || {};
my %claimed;
for my $name ( keys %{$caps} ) {
    for my $entry ( @{ $caps->{$name}{unlocks}{webdav} || [] } ) {
        # Only the entries that name a concrete path; prose entries
        # ('write anywhere in the content namespace...') are not claims
        # about a single file and are out of scope here.
        next unless $entry =~ m{\A(lazysite/\S+)};
        my $path = $1;
        $claimed{$path}{$name} = 1;
    }
}

for my $path ( sort keys %enforced ) {
    my @want = sort keys %{ $enforced{$path} };
    my @got  = sort keys %{ $claimed{$path} || {} };
    is_deeply( \@got, \@want,
        "$path: the descriptor claims exactly the capabilities enforcement admits" )
        or diag( "descriptor says: @{[ @got ? join(', ', @got) : '(nothing)' ]}\n"
            . "enforcement says: @{[ join(', ', @want) ]}\n"
            . 'A capability listing a path it cannot write sends a partner to a 403.' );
}

done_testing();
