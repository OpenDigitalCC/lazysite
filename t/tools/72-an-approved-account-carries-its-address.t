#!/usr/bin/perl
# SM858: an approved registration carries the address it was approved from, and
# the CLI command the usage has always advertised exists.
#
# SM673 shipped `account-approve`: it creates the account with NO password,
# places it in every group flagged to take registrations, and mints the
# single-use claim link. What it did not do was record an ADDRESS - so `forgot`,
# which resolves an identifier to (username, address) and answers generically
# when there is none, could never resolve an approved account. The operator had
# to carry the claim URL by hand for ever, and the "almost self service" loop
# stopped at the operator's mailbox.
#
# AND THE CLI DID NOT EXIST. The usage text has described `account-approve` in
# six lines since SM673; typing it answered "unknown command 'account-approve'",
# because no dispatch line was ever added. The filing said "the operator calls
# this from the CLI or the API"; it was the API alone.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    return $d;
}

sub users_cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map { quotemeta } ( $^X, $tool, '--docroot', $d, @args );
    my $out = qx($cmd 2>&1);
    return ( $? >> 8, $out );
}

sub settings {
    my ($d) = @_;
    my $p = "$d/lazysite/auth/user-settings.json";
    return {} unless -f $p;
    open my $fh, '<:raw', $p or return {};
    my $t = do { local $/; <$fh> };
    close $fh;
    return eval { decode_json($t) } || {};
}

subtest 'the command exists at all' => sub {
    my $d = site();
    my ( $rc, $out ) = users_cli( $d, 'account-approve' );
    unlike( $out, qr/unknown command/i,
        'account-approve is dispatched, not merely advertised' )
        or diag( 'The usage text has described this command since SM673. It '
            . 'answered "unknown command", so the operator route the filing '
            . 'named did not exist.' );
    like( $out, qr/Username required/, 'and it asks for what it needs' );
};

subtest 'approval records the address, and mints the link' => sub {
    my $d = site();
    my ( $rc, $out ) = users_cli( $d, 'account-approve', 'applicant',
        '--email', 'applicant@example.org' );
    is( $rc, 0, 'it succeeds' ) or diag($out);
    like( $out, qr{/claim\?u=applicant&c=}, 'the single-use link is printed' );

    my $s = settings($d);
    is( $s->{applicant}{email}, 'applicant@example.org',
        'the address is on the account' )
        or diag( 'Without this, forgot resolves nothing and the person can '
            . 'never fetch their own link.' );

    open my $uf, '<', "$d/lazysite/auth/users" or die $!;
    my ($line) = grep { /^applicant:/ } <$uf>;
    close $uf;
    like( $line, qr/^applicant:\s*$/m, 'and the account has NO password' );
};

subtest 'a malformed address creates nothing' => sub {
    my $d = site();
    my ( $rc, $out ) = users_cli( $d, 'account-approve', 'applicant', '--email', 'not-an-address' );
    isnt( $rc, 0, 'it refuses' );
    like( $out, qr/not an email address/, 'saying why' );
    ok( !-f "$d/lazysite/auth/users" || !( grep { /^applicant:/ } do {
                open my $fh, '<', "$d/lazysite/auth/users" or die $!; <$fh>;
        } ),
        'and no half-made account is left behind' )
        or diag( 'The address is validated BEFORE anything is created, or a '
            . 'typo leaves a credential-less account nobody asked for.' );
};

subtest 'approval without an address still works, as it always did' => sub {
    my $d = site();
    my ( $rc, $out ) = users_cli( $d, 'account-approve', 'applicant' );
    is( $rc, 0, 'it succeeds' ) or diag($out);
    like( $out, qr{/claim\?u=applicant}, 'and mints the link' );
    my $s = settings($d);
    ok( !exists $s->{applicant}{email}, 'with no address recorded' );
};

subtest 'the address is what forgot resolves - the join that was missing' => sub {
    my $d = site();
    users_cli( $d, 'account-approve', 'applicant', '--email', 'applicant@example.org' );

    # lazysite-auth.pl's resolver, driven directly: it is what stands between
    # "somebody typed their address" and "a link was minted for that account".
    my $src = do {
        open my $fh, '<', "$root/lazysite-auth.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($block) = $src =~ m{\nsub _resolve_account \{\n(.*?)\n\}\n}s;
    ok( $block, 'the resolver is one sub' ) or return;

    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    my $resolve = eval "our \$AUTH_DIR = '$d/lazysite/auth'; sub { $block\n }" or die $@;
    my ( $user, $email ) = $resolve->('applicant@example.org');
    is( $user,  'applicant',             'the address resolves to the account' );
    is( $email, 'applicant@example.org', 'and back to the address to send to' );

    my @none = $resolve->('nobody@example.org');
    ok( !@none || !defined $none[0], 'an address nobody registered resolves to nothing' );
};

done_testing();
