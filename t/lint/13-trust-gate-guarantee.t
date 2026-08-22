#!/usr/bin/perl
# SECURITY GUARANTEE (advisory 2026-07): the authenticated identity is carried in
# the X-Remote-* headers, which are trustworthy ONLY when our auth wrapper sets
# them from the HMAC-verified cookie (and flags LAZYSITE_AUTH_TRUSTED=1). A client
# must never assert its own identity by SENDING those headers. Every CGI that
# CONSUMES the identity headers must therefore apply the in-app trust gate before
# trusting them - a backstop for when the web-server edge fails to strip them (the
# dev server, a hand-written vhost, a forwarding proxy).
#
# This test makes that invariant mechanical: it scans the repo-root CGIs and fails
# the build if any CGI reads HTTP_X_REMOTE_USER without gating it. It exists
# because a manager-API gap (it consumed the header ungated) shipped undetected -
# the processor had the gate, its sibling did not, and no test asserted the copy
# stayed in sync.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; <$fh> }
sub base  { ( $_[0] =~ m{([^/]+)\z} )[0] }

# The wrapper is the trusted SETTER of the identity headers (it writes them from
# the verified cookie), so it is exempt from the consumer rule.
my %exempt = ( 'lazysite-auth.pl' => 1 );

my @cgis  = sort glob("$root/*.pl");
my @sinks;    # CGIs that consume the identity header
for my $cgi (@cgis) {
    my $b   = base($cgi);
    my $src = slurp($cgi);
    next if $exempt{$b};
    # Consumes the client-influenceable identity header?
    next unless $src =~ /\$ENV\{\s*['"]?HTTP_X_REMOTE_USER/;
    push @sinks, $b;

    # Must gate it: either the shared/inline gate (LAZYSITE_AUTH_TRUSTED checked
    # AND the X-Remote-* headers deleted when untrusted), or a call to
    # apply_trust_gate (the processor's named form).
    my $inline_gate = ( $src =~ /LAZYSITE_AUTH_TRUSTED/ )
        && ( $src =~ /delete[^\n]*HTTP_X_REMOTE/ );
    my $named_gate = $src =~ /apply_trust_gate/;

    # A THIRD, STRICTER SHAPE: never trust the header at all.
    #
    # Both gates above permit the header to be believed WHEN the front door
    # says it wrapped the request. A surface that the front door routes but
    # does NOT wrap cannot rely on that signal - which is SM411's whole
    # reasoning, and why lazysite-data.pl exists in the form it does: it
    # deletes every X-Remote-* unconditionally and then sets the identity from
    # a session cookie it verified itself.
    #
    # Accepted because it is STRONGER, not because it is different. The two
    # conditions together are what make it so: an unconditional delete on its
    # own would leave a surface with no identity, and verify_session_cookie on
    # its own would leave the claimed header in place beside the verified one.
    # A file that stops doing either falls back to the gates above.
    my $self_verifies = ( $src =~ /^\s*delete \$ENV\{\$_\} for grep \{[^\n]*HTTP_X_REMOTE/m )
        && ( $src =~ /verify_session_cookie/ );

    ok( $inline_gate || $named_gate || $self_verifies,
        "$b gates client-supplied X-Remote-* (LAZYSITE_AUTH_TRUSTED + delete, apply_trust_gate, or unconditional delete + self-verified session) before trusting it"
    );
}

# Guard against the test going vacuous (e.g. a refactor that stops matching the
# header spelling): the two known identity sinks must both be seen.
my %seen = map { $_ => 1 } @sinks;
ok( $seen{'lazysite-manager-api.pl'}, 'the manager-API is recognised as an identity sink (test not vacuous)' );
ok( $seen{'lazysite-processor.pl'},   'the processor is recognised as an identity sink (test not vacuous)' );

done_testing;
