#!/usr/bin/perl
# SM1016: `lazysite-domains.pl set --key allowed_groups` refuses a group the site
# does not have, as group-add does (t/tools/120).
#
# RULED by the release manager on 2026-10-12: "lazysite-domains.pl should
# reject invalid groups". `set` replaces the whole list, and wrote any
# well-formed name: a misspelt group admitted nobody and the tool said "ok".
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-domains.pl';
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/sites/a" );

sub put {
    my ( $rel, $text ) = @_;
    open my $fh, '>', "$d/$rel" or die "$rel: $!";
    print {$fh} $text;
    close $fh;
}
put( 'lazysite/lazysite.conf',
    "site_name: Agency\nalias_hosts: a.example\nalias.a.example.content_root: sites/a\n" );
put( 'lazysite/auth/groups', "staff: bob\neditors: alice\n" );
put( 'lazysite/auth/users',  "alice:x\nbob:x\n" );

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return <$fh> }

sub cli {
    my (@args) = @_;
    my $cmd    = join ' ', map { quotemeta } $^X, $tool, '--docroot', $d, @args;
    my $out    = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

{
    my ( $rc, $out ) = cli( qw(set --host a.example --key allowed_groups --value), '@staff,editors' );
    is( $rc, 0, 'set allowed_groups to groups the site has' ) or diag $out;
    like( conf(), qr/^alias\.a\.example\.allowed_groups: staff, editors$/m, 'stored as names' );
}
{
    my $before = conf();
    my ( $rc, $out ) = cli( qw(set --host a.example --key allowed_groups --value), 'staff,staf,@ghost' );
    is( $rc, 1, 'set with groups the site does not have exits 1' );
    like( $out, qr/^error: No groups \@staf, \@ghost on this site/m, 'naming each one' );
    is( conf(), $before, 'and changes nothing' );
}
{
    my $before = conf();
    my ( $rc, $out ) = cli( qw(set --host a.example --key locked_users --value), 'alice,mallory' );
    is( $rc, 1, 'set locked_users with an account the site does not have exits 1' );
    like( $out, qr/No account mallory on this site/, 'naming it' );
    is( conf(), $before, 'and changes nothing' );
}

done_testing();
