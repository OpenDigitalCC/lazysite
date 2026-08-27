#!/usr/bin/perl
# SM634: the pairing-key exchange minted a credential and never recorded WHEN.
#
# Operator report: on Sessions & Keys, "Issued" is always unknown. The page was
# right - nothing had recorded it. cmd_token sets cred_issued_at and
# cmd_connect_code sets it; cmd_token_exchange, which is how an AI partner
# normally obtains a credential from an agent brief, did not. So the estate had
# a recorded issue time for exactly the credentials it has fewest of.
#
# WHY IT MATTERS BEYOND THE COLUMN: "when was this issued" is the question an
# operator asks when deciding whether a credential is stale, and the answer was
# missing on the ones most likely to be. It is also the immutable time an
# absolute session cap would measure from (SM614), so a missing issue time is a
# gap under anything built on it later.
#
# NOT BACKFILLED, deliberately: a credential minted before this has no recorded
# issue time and inventing one - the file mtime, say - would be a confident
# guess presented as a record. Those keep saying unknown, which is true.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

my $src = do { open my $fh, '<', $tool or die $!; local $/; <$fh> };

# --- every minting path records the time ------------------------------------
# DISCOVERED, NOT LISTED. The first version of this test named the three subs I
# knew about and asserted on those - and missed cmd_token_rotate entirely, which
# mints a new credential and recorded no issue time either. A rotated token IS a
# new credential; its issue time is the rotation, not the original.
#
# A minting path is a sub that writes a fresh credential hash into %users. Find
# those, and the assertion covers a path added later without anyone remembering
# to extend this list.
my %subs;
{
    my @chunks = split /\n(?=sub )/, $src;
    for my $c (@chunks) {
        my ($name) = $c =~ /\Asub (\w+)/ or next;
        $subs{$name} = $c;
    }
}
my @minting = sort grep {
    $subs{$_} =~ /\$users\{\$user\}\s*=\s*hash_token\(/
} keys %subs;

cmp_ok( scalar @minting, '>=', 3,
    'found the credential-minting subs by what they DO, not by name' )
    or diag("found: @minting");

for my $sub (@minting) {
    like( $subs{$sub}, qr/\{cred_issued_at\}\s*=\s*time\(\)/,
        "$sub records when the credential was issued" );
}

# The connect code is not a token mint but is a credential issuance, and it
# already recorded the time - kept in the assertion so a later change that drops
# it is caught here rather than in the field.
like( $subs{cmd_connect_code} // '', qr/\{cred_issued_at\}\s*=\s*time\(\)/,
    'cmd_connect_code records it too' );

# --- and clears the previous "first use" mark --------------------------------
# A new credential that inherits the old one's used-at reads as already used,
# which is the same class of wrong answer: a record that is present and false.
for my $sub (@minting) {
    like( $subs{$sub}, qr/delete\s+\$all->\{\$user\}\{cred_used_at\}/,
        "$sub clears the previous credential's first-use mark" );
}

# --- the page reads it, and says unknown when it is genuinely absent --------
{
    my $page = "$root/starter/manager/sessions.md";
    my $p    = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
    like( $p, qr/k\.issued_at/, 'the Sessions & Keys page reads the issue time' );
    like( $p, qr/unknown/,
        'and still says unknown for a credential minted before this - which is '
            . 'true, and better than a guess dressed as a record' );
}

done_testing();
