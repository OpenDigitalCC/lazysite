#!/usr/bin/perl
# N141D (SM864, remaining half): lazysite-check says a pre-SM659 shared
# `manager` account is present.
#
# Before SM659 the bootstrap created a ROLE ACCOUNT called `manager` by default
# - one login shared by whoever administered the site. SM659 replaced it with
# setup-sysop, which names a person, and deliberately left NO alias. The
# installer half shipped; the filing's remaining item was:
#
#   "NOT DONE: lazysite-check naming a shared-looking role account, which is how
#   an operator would learn their existing `manager` account is there. Nothing
#   renames or deletes it - an operator may be signing in with it - so surfacing
#   it is the whole remaining job."
#
# On a site that predates the change the account is simply still there and
# nothing says so. A shared credential nobody is reminded of is one nobody
# rotates, scopes or retires, and the audit trail attributes everything it does
# to a name that is not a person.
#
# REPORTED, NEVER REPAIRED. The test below asserts both halves: that the account
# is named, and that running the check leaves it exactly where it was. A check
# that quietly removed the login somebody administers the site with would be a
# far worse defect than the one it closes.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $check = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => "no $check" unless -f $check;

sub site {
    my (@users) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    open my $uf, '>', "$d/lazysite/auth/users" or die $!;
    print {$uf} "$_:x\n" for @users;
    close $uf;
    return $d;
}

sub run_check {
    my ($d) = @_;
    return scalar qx($^X \Q$check\E --docroot \Q$d\E 2>&1);
}

# --- the shared account is named -------------------------------------------
{
    my $d   = site( 'manager', 'ada' );
    my $out = run_check($d);

    like( $out, qr/account called "manager"/,
        'the shared role account is named in the report' )
        or diag( "An operator who has never read SM659 has no reason to look "
            . "for it.\n--- check output ---\n$out" );

    like( $out, qr/SM659|before SM659/,
        'and dated, so the reader knows it is a leftover rather than a fault' );

    like( $out, qr/own account|users add/i,
        'with what to do instead' )
        or diag( 'Naming a thing without naming the remedy leaves an operator '
            . 'knowing they have a problem and not what to do about it.' );

    # NOT repaired: the account file is untouched.
    open my $fh, '<', "$d/lazysite/auth/users" or die $!;
    my $users = do { local $/; <$fh> };
    close $fh;
    like( $users, qr/^manager:/m,
        'and the account is still there - the check reports, it does not repair' )
        or diag( 'The filing is explicit: "Nothing renames or deletes it - an '
            . 'operator may be signing in with it."' );
}

# --- a site without one says nothing ----------------------------------------
#
# A check that mentions this on every site teaches operators to skim past it,
# and most sites created since SM659 have no such account.
{
    my $d   = site( 'ada', 'bob' );
    my $out = run_check($d);
    unlike( $out, qr/account called "manager"/,
        'a site with no such account is not told about one' );
}

# --- an account merely CONTAINING the word is not it ------------------------
#
# `manager` is the exact name the old bootstrap used. "site-manager" is somebody
# an operator named themselves, and reporting it would be a false positive on
# the one check whose value is that it fires rarely.
{
    my $d   = site( 'site-manager', 'manager-bot' );
    my $out = run_check($d);
    unlike( $out, qr/account called "manager"/,
        'an account whose name merely contains "manager" is not reported' )
        or diag( 'Substring matching here turns a rare, meaningful notice into '
            . 'noise on sites that never had the shared account.' );
}

done_testing();
