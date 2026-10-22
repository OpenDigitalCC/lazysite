#!/usr/bin/perl
# SM962: a username a person typed is refused BY NAME, never rewritten.
#
# cmd_add stripped every character a username cannot hold - `jo+hn` became
# `john` - and said nothing about it. Every caller then carried on with the name
# it had passed in. Reproduced through account-approve before the fix: the CLI
# created `john`, then answered "the account was created but User 'jo+hn' not
# found", because the group joins and the claim were made for `jo+hn`. The store
# was left holding a credential-less account nobody asked for, with no link to
# reach it - and `john` may be somebody else's name.
#
# No caller relied on the stripping (setup-sysop and the Users API `add` had the
# same shape: strip, then go on with the original), so cmd_add itself refuses
# now, which closes every door at once. SM858's button already refused such a
# name before calling account-approve; this is the same refusal one layer down.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_cmd run_child);

my $tool = repo_root() . '/tools/lazysite-users.pl';
plan skip_all => 'users tool missing' unless -f $tool;

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    return $d;
}

sub cli {
    my ( $d, @a ) = @_;
    my $out = run_cmd( $^X, $tool, '--docroot', $d, @a );
    return ( $? >> 8, $out );
}

sub api {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    my $r = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}

sub accounts {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/users" or return ();
    my @u = map { ( split /:/ )[0] } grep { /\S/ } <$fh>;
    close $fh;
    return sort @u;
}

sub settings {
    my ($d) = @_;
    open my $fh, '<:raw', "$d/lazysite/auth/user-settings.json" or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) } || {};
    close $fh;
    return $j;
}

sub members {
    my ( $d, $g ) = @_;
    my ( undef, $out ) = cli( $d, 'groups' );
    my ($line) = grep { /^\Q$g\E:/ } split /\n/, $out;
    return '' unless defined $line;
    $line =~ s/^\Q$g\E:\s*//;
    $line =~ s/\s*\[backend\]\s*$//;
    $line =~ s/\s+$//;
    return $line;
}

my $NAMED   = qr/'jo\+hn' cannot be a username: '\+' is not allowed/;
my $ALLOWED = qr/letters, digits, '\.', '_' and '-'/;

subtest 'the CLI: account-approve with a name it would have rewritten' => sub {
    my $d = site();
    my ( $rc, $out ) = cli( $d, 'account-approve', 'jo+hn' );
    isnt( $rc, 0, 'it refuses' );
    like( $out, $NAMED,   'naming the name and the character' );
    like( $out, $ALLOWED, 'and the characters a username may hold' );
    is_deeply( [ accounts($d) ], [], 'and NO account was created - not jo+hn, not john' )
        or diag( 'cmd_add stripped jo+hn to john and created it; the rest of '
            . 'the step went on with jo+hn and failed, leaving john behind.' );
    ok( !keys %{ settings($d) }, 'and no claim or setting was written' );
};

subtest 'the Users API: nothing is created, and nothing is joined' => sub {
    my $d = site();
    cli( $d, 'group-set', 'learners', 'ui', 'on' );
    my $s = api( $d, { action => 'group-settings-set', group => 'learners',
            key => 'registration', value => 'on' } );
    ok( $s->{ok}, 'a group takes registrations' ) or diag( $s->{error} // $s->{_raw} );

    my $r = api( $d, { action => 'account-approve', username => 'jo+hn' } );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'invalid', 'as an invalid request' );
    like( $r->{error} // '', $NAMED, 'by name' );
    like( $r->{error} // '', qr/nothing was created/, 'saying that nothing was created' );
    unlike( $r->{error} // '', qr/account was created/,
        'and never that the account was created' );
    is_deeply( [ accounts($d) ], [], 'no account exists' );
    is( members( $d, 'learners' ), '', 'and the registration group gained nobody' );
};

subtest 'every door through cmd_add refuses the same way' => sub {
    my $d = site();
    my ( $rc, $out ) = cli( $d, 'add', 'jo+hn', 'pw123456789-long-enough' );
    isnt( $rc, 0, 'add refuses' );
    like( $out, $NAMED, 'by name' );

    my $r = api( $d, { action => 'add', username => 'jo hn', password => 'pw123456789-long-enough' } );
    ok( !$r->{ok}, 'the API add refuses' );
    like( $r->{error} // '', qr/'jo hn' cannot be a username: ' ' is not allowed/,
        'naming a space as the character' );

    ( $rc, $out ) = cli( $d, 'setup-sysop', '--user', 'jo+hn' );
    isnt( $rc, 0, 'setup-sysop refuses' );
    like( $out, $NAMED, 'by name' );
    is_deeply( [ accounts($d) ], [], 'and none of them created anything' );
};

subtest 'a name made only of characters a username may hold is accepted' => sub {
    my $d = site();
    my ( $rc, $out ) = cli( $d, 'account-approve', 'jo.hn_s-2' );
    is( $rc, 0, 'approved' ) or diag($out);
    is_deeply( [ accounts($d) ], ['jo.hn_s-2'], 'as exactly that name' );
    ok( settings($d)->{'jo.hn_s-2'}{claim_hash}, 'and the claim is on that account' );
};

done_testing();
