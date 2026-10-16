#!/usr/bin/perl
# SM1094: `auth_groups: [` (unterminated) was reported as "write [[] or a '- ['
# line below it" - the raw value spliced into the example, so the example read
# garbled. The message now quotes the value it read as a literal and gives the
# correct forms with generic names, apart from the value.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use Lazysite::Validate ();

for my $v ( '[', 'editors', '[a, b' ) {
    my $u = Lazysite::Validate::read_access_keys("auth_groups: $v\n")->{unreadable}{auth_groups};
    ok( $u, "auth_groups: $v is unreadable" ) or next;
    like( $u, qr/\Q'$v'\E/, "  the value $v is quoted as read" );
    unlike( $u, qr/write \[\Q$v\E\]/, '  and not spliced into a bracket example' );
    unlike( $u, qr/'- \Q$v\E'/, '  nor into a list-line example' );
    like( $u, qr/auth_groups: \[editors\]/, '  the flow form is shown on its own, with a generic name' );
    like( $u, qr/"- editors"/, '  and the list form' );
}

my $issues = Lazysite::Validate::validate_content( content => "---\ntitle: T\nauth_groups: [\n---\nbody\n");
my ($i) = grep { $_->{kind} eq 'access-key-unreadable' } @{ ref $issues eq 'HASH' ? $issues->{issues} : $issues };
ok( $i, 'validate reports access-key-unreadable (code unchanged)' ) or diag explain $issues;
is( $i->{key}, 'auth_groups', 'for auth_groups' ) if $i;

done_testing();
