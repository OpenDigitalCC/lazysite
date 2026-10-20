#!/usr/bin/perl
# SM1217: AN XML ID ODOO DOES NOT KNOW IS NOT REPORTED AS "NONE UNKNOWN".
#
# SM1160 named, on the Odoo status and in `lazysite check`, each odoo_group_map xml id
# that core.has_groups listed as `unknown` at the last sign-in, from a file the sign-in
# wrote (lazysite/odoo/unknown-groups.json). OOM 0.37 (fixes-37 R-1, its debian/changelog)
# answers `{ groups => { XMLID => 1|0 } }` only: "a group Odoo does not know answers 0,
# like a group the person does not hold, and the `unknown` list is gone". No operation
# of OOM answers, as the person, whether a group exists (core.rights and core.whoami read
# ir.model.data only with rights a person signing in seldom has), so lazysite can no
# longer tell. An empty list would read as "every id is known", so:
#   * the status's site_signin carries no `unknown` list; it says `unknown_named: 0`
#     and why, in words;
#   * `lazysite check` says it on the feature's line;
#   * a file an older lazysite wrote is not read: its names are from an older answer and
#     nothing would ever clear them.
use strict;
use warnings;
use Test::More;
use JSON::PP   ();
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site site_tempdir);
use OdooTest   qw(oom_or_skip odoo_site write_conf);

BEGIN { oom_or_skip() }
use Lazysite::Odoo::SiteSignin ();

my $root = repo_root();
my $d    = site_tempdir();
setup_minimal_site($d);
odoo_site($d);
my $LZ = "$d/lazysite";

sub conf_on {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_site_signin => 'on', odoo_group_map => 'base.group_user = staff, no.such_group = ghost', @_ );
}

# what an older lazysite left behind: the list an OOM before 0.37 answered
make_path("$LZ/odoo");
{
    open my $fh, '>', "$LZ/odoo/unknown-groups.json" or die $!;
    print {$fh} JSON::PP->new->canonical->encode( { unknown => ['old.group_gone'], at => 1 } );
    close $fh;
}

sub check_out { return scalar `$^X $root/tools/lazysite-check.pl --docroot $d 2>&1` }

subtest 'the status says unknown ids are not named, and carries no list' => sub {
    conf_on();
    my $r = Lazysite::Odoo::SiteSignin::report($LZ);
    is( $r->{enabled}, 1, 'on' );
    is( $r->{mapped},  2, 'both entries mapped' );
    ok( !exists $r->{unknown}, 'no list of unknown ids, which would read as "none"' ) or diag explain $r;
    is( $r->{unknown_named}, 0, 'it says such ids are not named' );
    like( $r->{unknown_note} // '', qr/does not know .* not named/, 'and why, in words' );
    unlike( JSON::PP->new->canonical->encode($r), qr/old\.group_gone/, 'the older file\'s names are not read' );
};

subtest 'check says it on the feature\'s line, and names nothing from the older file' => sub {
    conf_on();
    my $out = check_out();
    like( $out, qr/the Odoo sign-in is the site sign-in; 2 Odoo groups mapped[^\n]*does not know[^\n]*not named/,
        'the line says an id Odoo does not know is not named' )
        or diag $out;
    unlike( $out, qr/old\.group_gone/, 'and the older file\'s id is not named' );
};

subtest 'a site that has not opted in is told nothing' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection' );
    is_deeply( Lazysite::Odoo::SiteSignin::report($LZ), { enabled => 0 }, 'the report is only "off"' );
    unlike( check_out(), qr/Odoo groups? mapped/, 'and check has no line for it' );
};

done_testing();
