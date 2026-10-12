#!/usr/bin/perl
# SM1015: `lazysite-domains.pl group-add` / `group-remove` (and user-add /
# user-remove for locked_users) change ONE name in a domain's access list.
#
# RULED by the release manager on 2026-10-12: "lets have cli command to add the
# domain group". Before this the shell had only `set --key allowed_groups
# --value LIST`, which replaces the whole list - so adding one group meant
# reading the list, retyping it, and losing any group mistyped on the way.
#
# What is held here:
#   - one name in or out, the others kept, through domain_set (the conf line
#     domain_set writes, in the form it writes it);
#   - `@G` and `G` alike; the conf keeps the plain name;
#   - idempotent: present on add / absent on remove says so and exits 0;
#   - a group or account the site does not have is refused, naming it, and
#     nothing is written - a misspelt group admits nobody;
#   - a store that cannot be read is no answer, so the add is refused;
#   - --help names the four commands.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-domains.pl';
my $d    = site_tempdir();
make_path("$d/lazysite/auth");

sub put {
    my ( $rel, $text ) = @_;
    open my $fh, '>', "$d/$rel" or die "$rel: $!";
    print {$fh} $text;
    close $fh;
}
put( 'lazysite/lazysite.conf',
    "site_name: Agency\nsite_url: https://agency.example\nalias_hosts: clienta.example\n"
        . "alias.clienta.example.content_root: sites/clienta\n" );
put( 'lazysite/auth/groups',               "staff: bob\neditors: alice\n" );
put( 'lazysite/auth/groups-settings.json', '{"reviewers":{"label":"Reviewers"}}' );
put( 'lazysite/auth/users',                "alice:x\nbob:x\n" );
make_path("$d/sites/clienta");

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return <$fh> }
sub line { my ($k) = @_; my ($v) = conf() =~ /^alias\.clienta\.example\.\Q$k\E: (.*)$/m; return $v }

# Runs the tool; returns (exit status, combined output).
sub cli {
    my (@args) = @_;
    my $cmd    = join ' ', map { quotemeta } $^X, $tool, '--docroot', $d, @args;
    my $out    = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# --- --help ------------------------------------------------------------------
{
    my ( $rc, $out ) = cli('--help');
    is( $rc, 0, '--help exits 0' );
    like( $out, qr/^  $_ /m, "and names $_" ) for qw(group-add group-remove user-add user-remove);
}

# --- group-add -----------------------------------------------------------------
{
    my ( $rc, $out ) = cli(qw(group-add --host clienta.example --group @staff));
    is( $rc,                    0,       'group-add @staff succeeds' ) or diag $out;
    is( line('allowed_groups'), 'staff', 'and the conf holds the plain name' );
    like( $out, qr/^ok: \@staff added to clienta\.example's allowed_groups\./m, 'saying so' );

    ( $rc, $out ) = cli(qw(group-add --host clienta.example --group editors));
    is( $rc,                    0,                'group-add editors (no @) succeeds' );
    is( line('allowed_groups'), 'staff, editors', 'and keeps the group already there' );
    like( $out, qr/^  allowed_groups: \@staff, \@editors$/m, 'and lists the result as @names' );

    ( $rc, $out ) = cli(qw(group-add --host clienta.example --group reviewers));
    is( $rc, 0, 'a group with settings and no members yet is a group' ) or diag $out;
    is( line('allowed_groups'), 'staff, editors, reviewers', 'and is added' );
}

# --- idempotent ---------------------------------------------------------------
{
    my $before = conf();
    my ( $rc, $out ) = cli(qw(group-add --host clienta.example --group staff));
    is( $rc, 0, 'adding a group already there exits 0' );
    like( $out, qr/^unchanged: \@staff is already in clienta\.example's allowed_groups/m,
        'and says nothing changed' );
    is( conf(), $before, 'and writes nothing' );

    ( $rc, $out ) = cli(qw(group-remove --host clienta.example --group @nobody-here));
    is( $rc, 0, 'removing a group that is not there exits 0' );
    like( $out, qr/^unchanged: \@nobody-here is not in/m, 'and says so' );
    is( conf(), $before, 'and writes nothing' );
}

# --- an unknown group is refused -----------------------------------------------
{
    my $before = conf();
    my ( $rc, $out ) = cli(qw(group-add --host clienta.example --group staf));
    is( $rc, 1, 'a group the site does not have is refused' );
    like( $out, qr/No group \@staf on this site/, 'naming it' );
    is( conf(), $before, 'and nothing is written' );

    ( $rc, $out ) = cli(qw(group-add --host nowhere.example --group staff));
    is( $rc, 1, 'a domain that is not configured is refused' );
    like( $out, qr/Domain not configured: nowhere\.example/, 'naming it' );

    ( $rc, $out ) = cli(qw(group-add --host clienta.example));
    isnt( $rc, 0, 'group-add with no --group is refused' );
    like( $out, qr/requires --host and --group/, 'saying what is missing' );
}

# --- group-remove ---------------------------------------------------------------
{
    my ( $rc, $out ) = cli(qw(group-remove --host clienta.example --group @staff));
    is( $rc,                    0,                    'group-remove @staff succeeds' );
    is( line('allowed_groups'), 'editors, reviewers', 'taking out only that group' );
}

# --- user-add / user-remove (locked_users) ---------------------------------------
{
    my ( $rc, $out ) = cli(qw(user-add --host clienta.example --user alice));
    is( $rc,                  0,       'user-add alice succeeds' ) or diag $out;
    is( line('locked_users'), 'alice', 'into locked_users' );
    ( $rc, $out ) = cli(qw(user-add --host clienta.example --user nobody));
    is( $rc, 1, 'an account the site does not have is refused' );
    like( $out, qr/No account nobody on this site/, 'naming it' );
    ( $rc, $out ) = cli(qw(user-remove --host clienta.example --user alice));
    is( $rc,                    0,                    'user-remove alice succeeds' );
    is( line('locked_users'),   '',                   'leaving the list empty' );
    is( line('allowed_groups'), 'editors, reviewers', 'and allowed_groups untouched' );
}

# --- a store that cannot be read is no answer -----------------------------------
SKIP: {
    skip 'root reads a mode-000 file', 3 if $> == 0;
    chmod 0000, "$d/lazysite/auth/groups" or die $!;
    my $before = conf();
    my ( $rc, $out ) = cli(qw(group-add --host clienta.example --group staff));
    chmod 0644, "$d/lazysite/auth/groups";
    is( $rc, 1, 'with the groups file unreadable, the add is refused' );
    like( $out, qr/Cannot tell whether \@staff exists: lazysite\/auth\/groups cannot be read/,
        'naming the store' );
    is( conf(), $before, 'and nothing is written' );
}

done_testing();
