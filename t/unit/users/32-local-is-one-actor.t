#!/usr/bin/perl
# SM549: `actor: local` is ONE actor in the users tool.
#
# SM268 C1 settled what `local` means: it is the operator sentinel - the
# identity the direct CLI and the manager API's operator path present - and
# the name is reserved at every door so nobody can become it by registering
# it. Five inline confinement blocks (passwd, rename, claim-create,
# claim-cancel, account-create) honoured that; _authorise_manage did not, so
# account-disable, account-enable and account-reassign refused with actor
# local while the same call with no actor succeeded. One caller, two answers.
#
# The contract this pins: for EVERY actor-taking verb, `actor => 'local'`
# and an absent actor produce the same verdict. The verbs are driven through
# the API mode the manager uses, against a fresh store each time.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    return $d;
}

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    my $r = eval { decode_json($out) };
    return $r || { ok => 0, error => "unparseable: $out" };
}

# Every verb that reads $req->{actor}, with the store each needs. The
# stores are built by the tool's own writers, never by hand (the reader must
# agree with the writer, not with the test author).
sub seeded {
    my $d = fresh_docroot();
    api( $d, { action => 'add', username => $_, password => 'pass12345678' } )
        for qw(bobby other);
    return $d;
}

my @verbs = (
    [ passwd             => { username => 'bobby', password => 'newpass123456' } ],
    [ rename             => { username => 'bobby', to       => 'robert' } ],
    [ 'account-disable'  => { username => 'bobby' } ],
    [ 'account-enable'   => { username => 'bobby' } ],
    [ 'account-reassign' => { username => 'bobby', to => 'other' } ],
    [ 'claim-create'     => { username => 'bobby' } ],
    [ 'claim-cancel'     => { username => 'bobby' } ],
);

for my $v (@verbs) {
    my ( $action, $args ) = @$v;
    my $as_local = api( seeded(), { action => $action, %$args, actor => 'local' } );
    my $no_actor = api( seeded(), { action => $action, %$args } );
    is( ( $as_local->{ok} ? 1 : 0 ), ( $no_actor->{ok} ? 1 : 0 ),
        "$action: actor local and no actor reach the same verdict" )
        or diag( "actor local -> " . ( $as_local->{error} // 'ok' )
            . "; no actor -> " . ( $no_actor->{error} // 'ok' ) );
}

# Non-vacuity: the verdict being compared is a success on at least the three
# verbs this SM is about, so "same verdict" is not "both refused".
for my $action (qw(account-disable account-enable account-reassign)) {
    my ($v) = grep { $_->[0] eq $action } @verbs;
    my $r = api( seeded(), { action => $action, %{ $v->[1] }, actor => 'local' } );
    ok( $r->{ok}, "$action with actor local succeeds - local is the operator" )
        or diag( $r->{error} // '' );
}

done_testing();
