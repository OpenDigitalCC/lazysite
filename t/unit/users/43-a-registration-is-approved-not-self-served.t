#!/usr/bin/perl
# SM673: approve a registration request - create the account and hand back the
# claim link in one step.
#
# Registration stays INVITATION-ONLY. Nothing public creates an account, and
# SM268's ruling - minting credentials is a human-at-a-browser operation - is
# intact: this is called BY an operator looking at a submission, not by the
# submission arriving. What it removes is the transcription of a name and an
# address out of a form into a CLI.
#
# THE TRAP IT AVOIDS. The obvious pending state is "create the account disabled,
# enable it on approval" - and cmd_claim_create refuses a disabled account
# outright, so that shape fails at the very next step. The pending state is the
# SUBMISSION, which the forms pipeline already stores. Nothing exists until
# approval, and what approval creates is a live account with NO password and a
# single-use link to set one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use JSON::PP;

my $root  = repo_root();
my $users = "$root/tools/lazysite-users.pl";
plan skip_all => 'users tool missing' unless -f $users;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");

sub conf {
    my ($extra) = @_;
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    print {$c} $extra if $extra;
    close $c;
}
conf();

sub run {
    my (@a) = @_;
    my $cmd = join ' ', map { quotemeta } ( $^X, $users, '--docroot', $d, @a );
    return qx($cmd 2>&1);
}
sub api {
    my ($req) = @_;
    my $json = encode_json($req);
    my $out  = qx(printf '%s' \Q$json\E | $^X \Q$users\E --api --docroot \Q$d\E 2>/dev/null);
    my $r    = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}
sub stored_credential {
    open my $fh, '<', "$d/lazysite/auth/users" or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    my ($c) = $s =~ /^\Q$_[0]\E:(.*)$/m;
    return $c;
}

subtest 'approval creates the account and mints a claim' => sub {
    my $r = api( { action => 'account-approve', username => 'learner1' } );
    ok( $r->{ok}, 'approved' ) or diag( $r->{error} // '' );
    is( $r->{user}, 'learner1', 'naming the account' );
    ok( $r->{claim}, 'with a claim token' );
    like( $r->{url} // '', qr{/claim}, 'and a link to redeem it' );

    # NO PASSWORD WAS SET. The operator never sees, chooses or transmits one -
    # which is the property /claim already has, and the reason this does not
    # call `add` with something generated.
    is( stored_credential('learner1'), '',
        'the account holds NO credential until the person sets one' )
        or diag( 'A generated password here would be a secret the operator '
            . 'has seen, which is what the claim flow exists to avoid.' );
};

subtest 'the account is NOT created disabled' => sub {
    # The shape that fails: claim-create refuses a disabled account, so a
    # "pending = disabled" design breaks at the step that hands over the link.
    my $perms = run( 'settings', 'learner1' );
    unlike( $perms, qr/disabled\s*[:=]\s*(?:1|true|yes)/i,
        'the approved account is live, not disabled' )
        or diag( 'cmd_claim_create refuses a disabled account outright, so '
            . 'this would have failed at the next step.' );
};

subtest 'with no registration_group it joins nothing' => sub {
    my $r = api( { action => 'account-approve', username => 'learner2' } );
    ok( $r->{ok}, 'approved' );
    is_deeply( $r->{group}, [], 'and is placed in no group' )
        or diag( 'No shipped group grants only a login, so guessing one here '
            . 'would hand a new account whatever that group carries.' );
};

subtest 'registration_group places it, when the site names one' => sub {
    conf("registration_group: learners\n");
    run( 'group-set', 'learners', 'ui', 'on' );
    my $r = api( { action => 'account-approve', username => 'learner3' } );
    ok( $r->{ok}, 'approved' ) or diag( $r->{error} // '' );
    is_deeply( $r->{group}, ['learners'], 'placed in the configured group' );
    like( run( 'groups' ), qr/learners:.*learner3/, 'and the store agrees' );
};

subtest 'a name already taken is refused, and nothing is half-made' => sub {
    my $r = api( { action => 'account-approve', username => 'learner1' } );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/already exists/, 'saying why' );
};

subtest 'approval is not delegable' => sub {
    # account-approve is absent from %DELEGABLE in the manager API, so a
    # delegate holding create_sub_users and NOT manage_users cannot call it.
    # It creates a TOP-LEVEL account, which is exactly what that list exists to
    # keep away from a sub-manager. Asserted here rather than assumed, because
    # the protection is by OMISSION and an omission is easy to undo by accident.
    my $api_src = do {
        open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($block) = $api_src =~ /my %DELEGABLE = map \{ \$_ => 1 \} qw\((.*?)\)/s;
    ok( defined $block, 'the delegable set was found' ) or return;
    unlike( $block, qr/\baccount-approve\b/,
        'account-approve is NOT delegable - it needs full manage_users' );
};

done_testing();
