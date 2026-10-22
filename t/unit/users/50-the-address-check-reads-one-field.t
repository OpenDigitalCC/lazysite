#!/usr/bin/perl
# P4 (WORK-PLAN-0154): approving an account request reads one field per account.
#
# form-submission-approve checks that the name and the address it is about to
# use are free, and it asked the users tool for `users-detail` to do it - every
# account's full effective settings, each derived afresh (groups, capabilities,
# domain scopes, the seeding check). Reported from a site of 695 imported
# accounts: 42.8 s of CPU, so the browser gave up before the approval answered.
# Measured here before the fix over a generated store of 700 accounts: 28.4 s.
#
# `users-detail` now takes `fields`, naming the stored settings the caller
# needs. Only `email` can be named - the one the check reads - and the answer
# carries that key and nothing else, read from the settings store once. Without
# `fields` the answer is the full one, as before.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $tool = repo_root() . '/tools/lazysite-users.pl';
plan skip_all => 'users tool missing' unless -f $tool;

sub api {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    my $r = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
my $N = 40;
my %s;
open my $u, '>', "$d/lazysite/auth/users" or die $!;
for my $i ( 1 .. $N ) {
    my $name = sprintf 'member%03d', $i;
    print {$u} "$name:\$placeholder\$\n";
    $s{$name} = { email => "$name\@example.org", display_name => "Member $i",
        comment => 'not asked for' }
        unless $i == $N;    # the last account records no address
}
close $u;
open my $sf, '>', "$d/lazysite/auth/user-settings.json" or die $!;
print {$sf} encode_json( \%s );
close $sf;

subtest 'fields => [email] answers each account with its address and nothing else' => sub {
    my $r = api( $d, { action => 'users-detail', fields => ['email'] } );
    ok( $r->{ok}, 'answered' ) or return diag( explain $r );
    is( scalar @{ $r->{users} || [] }, $N, 'every account is listed' );
    my %by = map { $_->{user} => $_->{settings} } @{ $r->{users} };
    is_deeply( $by{member001}, { email => 'member001@example.org' },
        'an account carries its address, and only its address' );
    is_deeply( $by{ sprintf 'member%03d', $N }, { email => undef },
        'an account with no address says so with an empty value' );
    my @extra = grep { keys %{ $by{$_} } != 1 } sort keys %by;
    is_deeply( \@extra, [], 'no account carries a derived setting' );
    ok( $r->{store_readable}, 'and the answer says the store was read' );
};

subtest 'a field that is not offered is refused, by name' => sub {
    for my $f ( ['totp_secret'], [ 'email', 'claim_hash' ], [], 'email' ) {
        my $r = api( $d, { action => 'users-detail', fields => $f } );
        ok( !$r->{ok}, 'refused: ' . encode_json( { fields => $f } ) );
        like( $r->{error} // '', qr/fields: only 'email'/, 'naming what can be asked for' );
        ok( !exists $r->{users}, 'and nothing is listed' );
    }
};

subtest 'without fields, the full answer is unchanged' => sub {
    my $r = api( $d, { action => 'users-detail' } );
    ok( $r->{ok}, 'answered' ) or return diag( explain $r );
    my ($one) = grep { $_->{user} eq 'member001' } @{ $r->{users} || [] };
    is( $one->{settings}{email}, 'member001@example.org', 'the address is there' );
    ok( exists $one->{settings}{groups} && exists $one->{settings}{manage_users},
        'and so are the derived settings' );
};

done_testing;
