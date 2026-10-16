#!/usr/bin/perl
# SM1086: an operator may add someone to the operator group.
#
# The release manager on edge, 2026-10-16, signed in as a member of sysops:
# "You cannot add anyone to 'sysops': it grants 'manager', which you may not
# confer." The ceiling (SM268 H8) lets an actor confer what it holds. The
# operator flag, `manager`, is a group flag and not one of @CAP_KEYS, so
# caps_for never reported it while the granted side counted it - and no
# signed-in account, the operator included, could ever confer it.
#
# What this holds:
#
# - an operator adds an account to the operator group
# - an account with manage_users and grant authority over EVERY capability but
#   `manager` is still refused, and refused on `manager` - so the operator flag
#   stays the operator's (SM991), and the refusal is about the flag itself
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Settings ();
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

# STDERR captured with STDOUT: every refusal is a die (see t/unit/users/30).
sub cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, @args;
    return `$cmd 2>&1` // '';
}

sub api {
    my ( $d, $req ) = @_;
    my $in = File::Temp->new;
    print {$in} encode_json($req);
    close $in;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, '--api';
    my $out = `$cmd < \Q$in\E 2>/dev/null`;
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
cli( $d, 'setup-sysop', '--user', 'op', 'secretpw1234' );
cli( $d, 'add', $_, 'pw12345678-long-enough' ) for qw(carol del gina);

my $r0 = api( $d, { action => 'group-add', username => 'del', group => 'user-managers' } );
ok $r0->{ok}, 'del joins user-managers (as the CLI operator)' or diag $r0->{error};
for my $c ( grep { $_ ne 'manager' } @Lazysite::Auth::Settings::CAP_KEYS ) {
    cli( $d, 'group-set', 'user-managers', 'grantable-add', $c );
}

subtest 'the operator adds an account to the operator group' => sub {
    my $r = api( $d,
        { action => 'group-add', username => 'carol', group => 'sysops', actor => 'op' } );
    ok $r->{ok}, 'accepted' or diag $r->{error};
    open my $g, '<', "$d/lazysite/auth/groups" or die $!;
    my $groups = do { local $/; <$g> };
    like $groups, qr/^sysops:.*\bcarol\b/m, 'and the membership is stored';
};

subtest 'a manage_users holder is refused, on the operator flag itself' => sub {
    my $r = api( $d,
        { action => 'group-add', username => 'gina', group => 'sysops', actor => 'del' } );
    ok !$r->{ok}, 'refused';
    like $r->{error} // '', qr/it grants 'manager'/,
        'refused on manager - every other capability it could confer';
    my $self = api( $d,
        { action => 'group-add', username => 'del', group => 'sysops', actor => 'del' } );
    ok !$self->{ok}, 'and it cannot add itself';
};

done_testing;
