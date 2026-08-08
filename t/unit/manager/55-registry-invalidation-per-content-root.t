#!/usr/bin/perl
# SM251: deleting a page clears the generated registries for EVERY content root,
# not only the docroot's.
#
# update_registries writes a domain's sitemap/llms.txt INTO that domain's content
# root - the whole point of per-domain registries - while the invalidator only
# ever unlinked "$DOCROOT/$out". So the refresh aimed at the wrong file: on a
# multi-domain instance, deleting a page under a domain's content root left THAT
# domain's registries in place and the deleted URL stayed listed until the TTL
# expired. It was reported as slow convergence, which is what it looks like from
# outside.
#
# The generated registries are unlinked, not rewritten - the processor rebuilds a
# missing output on the next request - so what is asserted is their ABSENCE.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd ();
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files   ();
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Common  ();

# realpath, not the raw tempdir: the manager's containment check compares the
# RESOLVED path against $DOCROOT, and /tmp is a symlink on some hosts - so a raw
# tempdir makes every write look like an escape attempt.
my $d = Cwd::realpath( tempdir( CLEANUP => 1 ) );
make_path( "$d/lazysite/templates/registries", "$d/lazysite/manager/locks",
    "$d/sites/clienta", "$d/sites/clientb" );

# Two registry templates, so the loop over templates is exercised too.
for my $t (qw(sitemap.xml llms.txt)) {
    open my $fh, '>', "$d/lazysite/templates/registries/$t.tt" or die $!;
    print {$fh} '[% FOREACH p IN pages %][% p.url %][% END %]';
    close $fh;
}

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Agency\n"
    . "alias_hosts: a.example, b.example, chrome.example\n"
    . "alias.a.example.content_root: sites/clienta\n"
    . "alias.b.example.content_root: sites/clientb\n";
close $cf;

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Files::LOCK_DIR = "$d/lazysite/manager/locks";

# Common carries its OWN $DOCROOT and validate_path reads that one, not Files'.
# Each manager module holds its own copy, set per request by the dispatcher, so a
# test driving the modules directly has to set both - miss this and every write
# fails as "Invalid path" against an empty docroot.
$Lazysite::Manager::Common::DOCROOT = $d;

sub seed_registries {
    for my $root ( $d, "$d/sites/clienta", "$d/sites/clientb" ) {
        for my $out (qw(sitemap.xml llms.txt)) {
            open my $fh, '>', "$root/$out" or die $!;
            print {$fh} "stale listing including /gone\n";
            close $fh;
        }
    }
}

sub present {
    my ($root) = @_;
    return join ',', grep { -f "$root/$_" } qw(sitemap.xml llms.txt);
}

# --- the roots are discovered from the domain config ------------------------
{
    my @roots = Lazysite::Manager::Files::_registry_roots();
    is( scalar @roots, 3, 'docroot plus each registered content root' )
        or diag join ', ', @roots;
    ok( ( grep { $_ eq $d } @roots ),                 'the docroot is included' );
    ok( ( grep { $_ eq "$d/sites/clienta" } @roots ), 'clienta content root' );
    ok( ( grep { $_ eq "$d/sites/clientb" } @roots ), 'clientb content root' );

    # A chrome-only alias has no content root of its own and shares the
    # docroot's registries (SM110), so it must NOT add a root.
    is( scalar( grep {m{chrome}} @roots ), 0,
        'a chrome-only alias adds no root - it shares the docroot' );
}

# --- invalidation clears every root -----------------------------------------
{
    seed_registries();
    is( present($d), 'sitemap.xml,llms.txt', 'seeded: docroot' );
    is( present("$d/sites/clienta"), 'sitemap.xml,llms.txt', 'seeded: clienta' );

    Lazysite::Manager::Files::_invalidate_registries();

    is( present($d), '', 'the docroot registries are cleared' );
    is( present("$d/sites/clienta"), '',
        "clienta's OWN registries are cleared - the case that used to be missed" );
    is( present("$d/sites/clientb"), '', "and clientb's" );
}

# --- a delete goes through it -----------------------------------------------
# The unit above proves the helper; this proves the delete path calls it, which
# is what the report was actually about.
{
    open my $pg, '>', "$d/sites/clienta/gone.md" or die $!;
    print {$pg} "# Gone\n";
    close $pg;
    seed_registries();

    my $r = Lazysite::Manager::Files::action_delete( '/sites/clienta/gone.md', 'tester' );
    ok( $r->{ok}, 'the page deletes' ) or diag( $r->{error} // '' );
    is( present("$d/sites/clienta"), '',
        "deleting a page under a domain's content root clears THAT domain's registries" );
}

# --- no domains configured: unchanged behaviour ------------------------------
# The single-site case is the overwhelming majority and must not regress.
{
    my $s = Cwd::realpath( tempdir( CLEANUP => 1 ) );
    make_path("$s/lazysite/templates/registries");
    open my $t, '>', "$s/lazysite/templates/registries/sitemap.xml.tt" or die $!;
    print {$t} 'x';
    close $t;
    open my $c, '>', "$s/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: Solo\n";
    close $c;
    open my $o, '>', "$s/sitemap.xml" or die $!;
    print {$o} "stale\n";
    close $o;

    local $Lazysite::Manager::Files::DOCROOT = $s;
    my @roots = Lazysite::Manager::Files::_registry_roots();
    is( scalar @roots, 1, 'a single-site instance has exactly one root' );
    Lazysite::Manager::Files::_invalidate_registries();
    ok( !-f "$s/sitemap.xml", 'and its registry is still cleared' );
}

done_testing();
