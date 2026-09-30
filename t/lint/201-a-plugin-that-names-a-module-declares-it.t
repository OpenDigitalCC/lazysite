#!/usr/bin/perl
# SM925 X1: notify-xmpp needed Net::XMPP, said so in its header comment - "Net::XMPP
# / Debian libnet-xmpp-perl" - and declared nothing under `owns.deps`, the field
# ADR 0009 created and the enable path reads. So it enabled cleanly on a host that
# did not have the module, accepted eight fields including a password, reported
# nothing wrong, and failed at first delivery on a live site. Two sibling plugins
# use the mechanism; the fact was written down nine lines from where the machinery
# would have read it.
#
# WHAT THIS GATE DELIBERATELY DOES NOT DO, because both dead ends are the lesson.
#
# It does not scan for an undeclared `require`. The `require Net::XMPP` is not in
# the plugin at all - delivery lives in Lazysite::Notify and the plugin is a
# descriptor - so a sweep of plugins/ for undeclared requires finds nothing here.
# That is what tmp/sm925-dep-audit.pl did on its first run: it flagged two other
# plugins and missed the one the report was about.
#
# And it does not flag a `Foo::Bar` name in prose. That version was written, run,
# and abandoned: it failed 12 of 16 plugins on `Cwd::abs_path`, `JSON::PP::true`
# and `Digest::SHA::sha256_hex` - fully-qualified CALLS, not dependencies - and on
# `Devel::Cover` in a comment. It even flagged form-handler.pl for a comment THIS
# FILING added mentioning Net::XMPP. A detector that cannot tell "depends on" from
# "mentions" is noise, and a noisy gate gets switched off.
#
# What is left is narrow and sound: a DEBIAN PERL PACKAGE NAME. `libnet-xmpp-perl`
# never appears by accident - it appears when somebody is telling an operator what
# to install, which is precisely the moment the machinery should have been told
# too. Measured 2026-09-30: two plugins carry one, and before this build one of the
# two declared nothing.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my @plugins = sort glob( $root . '/plugins/*.pl' );
cmp_ok( scalar @plugins, '>=', 10, 'the plugin set is present' );

my $named = 0;
for my $p (@plugins) {
    ( my $base = $p ) =~ s{.*/}{};
    open my $fh, '<', $p or do { fail("$base: unreadable"); next };
    my $src = do { local $/; <$fh> };
    close $fh;

    my %pkg;
    while ( $src =~ /\b(lib[a-z0-9]+(?:-[a-z0-9]+)*-perl)\b/g ) { $pkg{ lc $1 } = 1 }
    next unless %pkg;
    $named++;

    my $out = qx{$^X "$p" --describe 2>/dev/null};
    my $d   = eval { decode_json($out) };
    unless ( ref $d eq 'HASH' ) {
        fail("$base: --describe did not produce a descriptor");
        next;
    }
    my $owns = ref $d->{owns} eq 'HASH' ? $d->{owns} : {};
    my @declared = ( @{ $owns->{deps} || [] }, @{ $owns->{bins} || [] } );

    ok( scalar @declared,
        "$base names " . join( ', ', sort keys %pkg ) . " and declares a dep or a bin" )
        or diag( "  Naming a Debian package tells an OPERATOR to install something.\n"
            . "  `owns.deps` is what tells the ENABLE PATH, and without it the plugin\n"
            . "  enables on a host that has not installed it and fails at first use -\n"
            . "  the state SM472 and ADR 0009 exist to prevent. Add:\n"
            . "      owns => { deps => ['Module::Name'], capabilities => [] },\n" );
}

# Not vacuous. If the detector stops matching - a rewording, a moved comment - this
# is the assertion that fails instead of the file passing on an empty census.
cmp_ok( $named, '>=', 2, "plugins naming a Debian Perl package were found ($named)" );

done_testing();
