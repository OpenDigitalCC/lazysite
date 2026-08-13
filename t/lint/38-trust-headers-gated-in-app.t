#!/usr/bin/perl
# SM293 step 4: the in-app gate is the control, so it has to be true on every
# surface that reads a trust header.
#
# `X-Remote-User` and friends are how the auth wrapper tells the engine who is
# signed in. A client can send them too, so if a surface believed them a visitor
# could name themselves an operator in a header. The documented remedy has always
# been "strip them at the front end", which is a rule in configuration lazysite
# ships as a template, cannot test where it is installed, and mostly cannot see -
# the pattern behind SM248, SM268 H17 and SM283.
#
# The real control is in-app: a trust header is honoured only when the auth
# wrapper vouched for the request (LAZYSITE_AUTH_TRUSTED=1) or the operator opted
# into a trusted reverse proxy (auth_proxy_trusted: true). Otherwise it is
# DELETED and the attempt logged.
#
# This pins that. Without it the demotion of the front-end strip from "required"
# to "recommended hardening" would be a documentation change resting on an
# unenforced claim - which is precisely how the access-control document came to
# state the opposite of the behaviour twice.
#
# The check is deliberately "reads implies gates" rather than a fixed file list:
# a NEW surface that starts reading a trust header is the case that matters, and
# a fixed list would not notice it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# lazysite-auth.pl is the wrapper: it SETS these headers after validating the
# session cookie, and sets LAZYSITE_AUTH_TRUSTED to say so. It is the source of
# the trust, so it is the one file that must not gate itself.
my %SETS_TRUST = map { $_ => 1 } qw(lazysite-auth.pl);

my @cgis = qw(
    lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl
    lazysite-dav.pl lazysite-mcp.pl lazysite-oauth.pl
);

my ( @reads, @unguarded );
for my $rel (@cgis) {
    open my $fh, '<', "$root/$rel" or die "$rel: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # Strip comments, so a file that only DISCUSSES the headers does not count
    # as reading them. This matters: several files explain the mechanism at
    # length without touching it.
    ( my $code = $src ) =~ s/^\s*#.*$//mg;

    next unless $code =~ /HTTP_X_REMOTE_(?:USER|GROUPS|NAME|EMAIL)/;
    push @reads, $rel;

    next if $SETS_TRUST{$rel};
    push @unguarded, $rel
        unless $code =~ /LAZYSITE_AUTH_TRUSTED/ && $code =~ /auth_proxy_trusted/;
}

ok( @reads, 'at least one surface reads a trust header (the check is live)' )
    or diag('no surface matched - the header names may have been renamed');

is_deeply( \@unguarded, [],
    'every surface that reads a trust header also gates it on the auth '
        . 'wrapper vouching for the request, or the operator opting into a '
        . 'trusted proxy' )
    or diag( 'ungated: ' . join ', ', @unguarded );

# The gate must DELETE the headers, not merely log them. Logging an ignored
# header while leaving it in %ENV for the next reader is the shape of fix that
# looks right in review and changes nothing.
subtest 'the gate removes the headers rather than only noting them' => sub {
    for my $rel ( grep { !$SETS_TRUST{$_} } @reads ) {
        open my $fh, '<', "$root/$rel" or die;
        my $src = do { local $/; <$fh> };
        close $fh;
        # Either spelling: a hash slice, or a loop over the names. The first
        # version of this check demanded the slice, and reported the processor
        # as ungated when it deletes them one at a time in a loop - the test
        # being wrong about the code, which is worth a comment because it is
        # the same mistake as prose being wrong about the code.
        like( $src, qr/delete \s* (?: \@ENV\{ | \$ENV\{ )/x,
            "$rel deletes the untrusted headers from the environment, rather "
                . "than only logging them and leaving them for the next reader" );
    }
};

done_testing();
