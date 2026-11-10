#!/usr/bin/perl
#
# n807 / SM1427: REGISTERING ONE SITE DOES NOT HIDE THE OTHERS.
#
# The fleet verbs read the Hestia site list only when the registry was EMPTY. The
# Hestia deploy now writes a registry entry for each new site, so the first one on a
# host made `check --all`, `repair --all`, `probe --all`, `upgrade --all`,
# `users --all` and `sites` see that site alone. The sites they mean are the
# registry's AND the Hestia list's, merged by docroot, the registry entry winning
# (channel, policy) where a site is in both. With no registry the answer is the
# Hestia list, as before.
#
# THE FIXTURE: a registry of one site (channel beta), and a stubbed Hestia list of
# three (the one in the registry, and two that are not), through the lister's own
# knobs LAZYSITE_HESTIA_USERS and LAZYSITE_HOME_BASE.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

plan skip_all => 'running as root - the verbs drop per site' if $> == 0;

my $root = repo_root();
my $CLI  = "$root/tools/lazysite-cli.pl";
my $T    = Cwd::realpath( site_tempdir() );

sub spit { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }

my @domains = qw(a.example b.example c.example);
make_path("$T/hestia/users/u1");
my @wc;
for my $d (@domains) {
    my $doc = "$T/home/u1/web/$d/public_html";
    make_path("$doc/lazysite/auth");
    spit( "$doc/lazysite/lazysite.conf", "site_name: $d\n" );
    push @wc, "DOMAIN='$d' IP='10.0.0.1' TPL='lazysite-app' SUSPENDED='no' TIME='0'\n";
}
spit( "$T/hestia/users/u1/web.conf", join '', @wc );
make_path("$T/registry");
my $user = ( getpwuid $< )[0];
spit( "$T/registry/a.example",
    "docroot=$T/home/u1/web/a.example/public_html\ncgibin=$T/home/u1/web/a.example/cgi-bin\nowner=$user\nchannel=beta\npolicy=manual\n" );

local $ENV{LAZYSITE_HESTIA_USERS} = "$T/hestia/users";
local $ENV{LAZYSITE_HOME_BASE}    = "$T/home";

sub cli { my $args = join ' ', @_; my $o = qx($^X \Q$CLI\E $args 2>&1); return ( $? >> 8, $o ) }

{
    local $ENV{LAZYSITE_REGISTRY_DIR} = "$T/registry";
    my ( $rc, $out ) = cli('sites');
    for my $d (@domains) {
        like( $out, qr/^\s*\Q$d\E\b/m, "sites with a one-site registry lists $d" ) or diag $out;
    }
    like( $out, qr/^\s*a\.example\b[^\n]*\bbeta\b/m, 'and the registered site carries its registry channel' ) or diag $out;
    unlike( $out, qr/^\s*[bc]\.example\b[^\n]*\bbeta\b/m, 'the unregistered ones do not borrow it' ) or diag $out;

    ( $rc, $out ) = cli( 'check', '--all' );
    my @seen = $out =~ /^== (\S+)$/mg;
    is_deeply( [ sort @seen ], [ sort @domains ], 'check --all reaches all three sites' ) or diag $out;
}

{
    # No registry: the Hestia list alone, as before.
    make_path("$T/emptyreg");
    local $ENV{LAZYSITE_REGISTRY_DIR} = "$T/emptyreg";
    my ( $rc, $out ) = cli( 'check', '--all' );
    my @seen = $out =~ /^== (\S+)$/mg;
    is_deeply( [ sort @seen ], [ sort @domains ], 'with no registry, --all is the Hestia list, as it was' ) or diag $out;
}

done_testing();
