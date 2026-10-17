#!/usr/bin/perl
# SM1154 (oom-lab L-8): "Making the first account with `lazysite-users.pl add`
# + `group-add manager` gives an account with no manager access; `setup-sysop`
# is the way, and nothing on the `add` path says so."
#
# `group-add alice manager` makes a group NAMED manager, with no capabilities
# and no operator flag; the account is in it and can do nothing in the manager.
# The tool said "added" both times. On a site with no operator it now says what
# the way is. Once an operator exists the notes stop: adding accounts and
# putting them in groups is then routine.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map {"\Q$_\E"} $^X, $script, '--docroot', $d, @args;
    return `$cmd 2>&1` // '';
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

my $out = cli( $d, 'add', 'alice', 'pw12345678-long-enough' );
like( $out, qr/User 'alice' added/, 'the first account is added' );
like( $out, qr/no operator/i,       'and the tool says the site has no operator' );
like( $out, qr/setup-sysop/,        'and names setup-sysop' );
like( $out, qr/Users page/,         'and the manager Users page, for once there is an operator' );

$out = cli( $d, 'add', 'bob', 'pw12345678-long-enough' );
unlike( $out, qr/setup-sysop/, 'a second account says nothing: only the first is the set-up' );

$out = cli( $d, 'group-add', 'alice', 'manager' );
like( $out, qr/User 'alice' added to group 'manager'/, 'alice joins a group called manager' );
like( $out, qr/setup-sysop/, 'which grants no manager access, and the tool names setup-sysop' );
like( $out, qr/no operator/i, 'because the site has no operator' );

# Once there is an operator the notes stop.
cli( $d, 'setup-sysop', '--user', 'op', 'secretpw1234' );
$out = cli( $d, 'add', 'carol', 'pw12345678-long-enough' );
unlike( $out, qr/setup-sysop|no operator/i, 'with an operator, add is silent about it' );
$out = cli( $d, 'group-add', 'carol', 'manager' );
unlike( $out, qr/setup-sysop|no operator/i, 'and so is group-add' );

# On a fresh site, joining the OPERATOR group is the way and needs no note.
my $e = site_tempdir();
make_path("$e/lazysite/auth");
open my $cf2, '>', "$e/lazysite/lazysite.conf" or die $!;
print {$cf2} "site_name: T\n";
close $cf2;
cli( $e, 'setup-sysop', '--user', 'root1', 'secretpw1234' );
cli( $e, 'add', 'dan', 'pw12345678-long-enough' );
$out = cli( $e, 'group-add', 'dan', 'sysops' );
unlike( $out, qr/no operator/i, 'joining the operator group is not noted' );

# The help says it where the commands are listed.
my $help = cli( $d, '--help' );
like( $help, qr/add USERNAME PASSWORD[^\n]*\n(?:[^\n]*\n){0,3}[^\n]*setup-sysop/,
    '--help says, beside add, that the first operator is made with setup-sysop' );
like( $help, qr/group-add USERNAME GROUP[^\n]*\n(?:[^\n]*\n){0,3}[^\n]*(?:operator|setup-sysop)/,
    'and beside group-add' );

done_testing;
