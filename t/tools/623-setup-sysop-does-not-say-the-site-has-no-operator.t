#!/usr/bin/perl
#
# n807 / SM1427: setup-sysop DOES NOT TELL THE OPERATOR THE SITE HAS NO OPERATOR.
#
# `setup-sysop --user sjm` printed "Note: this site has no operator yet, so 'sjm'
# has no manager access" in the middle of the run that makes sjm the operator: the
# notice belongs to `add` (SM1154), and setup-sysop composes `add` before it joins
# the operator group. The notice stays for `add` and `group-add` on their own.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root  = repo_root();
my $USERS = "$root/tools/lazysite-users.pl";
plan skip_all => 'running as root - the tool drops or refuses' if $> == 0;

sub users {
    my ( $doc, @args ) = @_;
    my $out = qx($^X -I\Q$root\E/lib \Q$USERS\E --docroot \Q$doc\E @args 2>&1);
    return ( $? >> 8, $out );
}

for my $variant ( [ 'link', '--user', 'sjm' ], [ 'password', '--user', 'sjm', 'Correct-Horse-9-Battery' ] ) {
    my $doc = site_tempdir();
    my ( $rc, $out ) = users( $doc, 'setup-sysop', @$variant[ 1 .. $#$variant ] );
    is( $rc, 0, "setup-sysop ($variant->[0]) runs" ) or diag $out;
    like( $out, qr/sjm/, 'and names the account' );
    unlike( $out, qr/no operator yet|has no manager access/,
        "setup-sysop ($variant->[0]) does not say the site has no operator" )
        or diag $out;
}

# The notice is still `add`'s: the first account on a site with no operator.
my $doc = site_tempdir();
my ( $rc, $out ) = users( $doc, 'add', 'alice', 'Correct-Horse-9-Battery' );
is( $rc, 0, 'add runs' ) or diag $out;
like( $out, qr/no operator yet/, 'and still says the site has no operator' ) or diag $out;

done_testing();
