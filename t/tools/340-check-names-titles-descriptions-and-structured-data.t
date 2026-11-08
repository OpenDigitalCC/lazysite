#!/usr/bin/perl
# SM1356 / SM1357: `lazysite check` checks what search engines read.
#
#   * every public page has a title and a description, and no two share a title -
#     a protected, api:, raw:, search: false or starter demonstration page is
#     not public and is not asked;
#   * the JSON-LD the engine emits, checked against each mapping's type: a row
#     missing what its type needs, a date that is not ISO 8601, a page the
#     mapping names that the site does not have, a table no visitor may read;
#   * the site's time_zone, when it names a zone the host does not know (and
#     ruling 172: the Debian package recommends tzdata);
#   * ruling 171: a folder that looks like another site's content (under sites/,
#     or holding its own lazysite.conf) and is not a declared content root.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $script = repo_root() . '/tools/lazysite-check.pl';
plan skip_all => 'lazysite-check.pl missing' unless -f $script;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub site {
    my (%o) = @_;
    my $doc = site_tempdir();
    make_path( "$doc/lazysite/$_" ) for qw(auth cache logs manager db/tables);
    spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" . ( $o{conf} // '' ) );
    spit( "$doc/index.md", "---\ntitle: Home\nsubtitle: Welcome\n---\nH\n" );
    return $doc;
}
sub run_check { my ($doc) = @_; return qx($^X \Q$script\E --docroot \Q$doc\E 2>&1) }

subtest 'titles and descriptions' => sub {
    my $d = site();
    spit( "$d/untitled.md",   "---\nsubtitle: Has a description\n---\nU\n" );
    spit( "$d/bare.md",       "---\ntitle: Bare\n---\nB\n" );
    spit( "$d/twin-a.md",     "---\ntitle: Twin\nsubtitle: one\n---\nA\n" );
    spit( "$d/twin-b.md",     "---\ntitle: twin\nmeta_desc: two\n---\nB\n" );
    spit( "$d/members.md",    "---\nauth: required\n---\nM\n" );
    spit( "$d/data.md",       "---\napi: true\n---\n{}\n" );
    spit( "$d/hidden.md",     "---\nsearch: false\n---\nH\n" );
    spit( "$d/demo.md",       "---\nstarter_role: demonstration\n---\nD\n" );
    my $out = run_check($d);
    like( $out, qr/1 public page\(s\) have no title: untitled\.md/, 'a page with no title is named' ) or diag $out;
    like( $out, qr/public page\(s\) have no description: bare\.md/, 'a page with no description is named' );
    unlike( $out, qr/no description: [^\n]*(?:twin|members|data|hidden|demo)/, 'meta_desc and subtitle both count; a page that is not public is not asked' );
    like( $out, qr/title\(s\) are shared by more than one public page: twin-a\.md and twin-b\.md/, 'a shared title is named' );

    my $good = site();
    like( run_check($good), qr/1 public page\(s\), each with a title and a description of its own/, 'all well: OK' );
};

subtest 'the emitted JSON-LD against the mapping\'s type' => sub {
    my $d = site( conf => "extensions:\n  - extensions/data.pl\n" );
    spit( "$d/events.md", "---\ntitle: Events\nsubtitle: What is on\n---\nE\n" );
    spit( "$d/lazysite/db/tables/events.yaml",
        "title: Events\npublic: true\nfields:\n  title:\n    type: text\n  starts:\n    type: text\n"
            . "structured_data:\n  type: Event\n  pages: [/events, /gone]\n  properties:\n    name: title\n    startDate: starts\n" );
    spit( "$d/lazysite/db/tables/secret.yaml",
        "title: Secret\nfields:\n  title:\n    type: text\n"
            . "structured_data:\n  type: Product\n  pages: [/events]\n  properties:\n    name: title\n" );
    spit( "$d/lazysite/db/tables/odd.yaml",
        "title: Odd\npublic: true\nfields:\n  title:\n    type: text\n"
            . "structured_data:\n  type: Vehicle\n  pages: [/events]\n  properties:\n    name: title\n" );
    apply_schema( $d, $_ ) for qw(events secret odd);
    insert_row( $d, 'events', { title => 'Quiz', starts => '2099-01-01' } );
    insert_row( $d, 'events', { title => '', starts => 'next Tuesday' } );
    insert_row( $d, 'odd', { title => 'Car' } );
    my $out = run_check($d);
    like( $out, qr/finding\(s\) in the emitted JSON-LD/, 'findings are reported' ) or diag $out;
    like( $out, qr/table 'events' row 2: Event has no name/, 'a row missing what its type needs' );
    like( $out, qr/table 'events' row 2: startDate 'next Tuesday' is not an ISO 8601 date/, 'a date that is not one' );
    like( $out, qr/structured_data names page \/gone, which this site does not have/, 'a page the site does not have' );
    like( $out, qr/table 'secret': structured_data emits nothing - the table is not public/, 'a table no visitor may read' );
    like( $out, qr/table 'odd': Vehicle is not a type lazysite check knows the essentials of/, 'a type it cannot check is said, not refused' );
    unlike( $out, qr/table 'events' row 1:/, 'and a row that holds is not named' );

    my $none = site();
    like( run_check($none), qr/no data table declares structured_data/, 'no mapping: one line' );
};

# Ruling 171: a folder that looks like another site's content and is not a
# declared content root is named as served on the bare host, with the remedy.
subtest 'another site\'s folder, undeclared' => sub {
    my $d = site( conf => "alias.a.example.content_root: sites/declared\n" );
    make_path( "$d/$_" ) for qw(sites/old sites/declared unpacked nested/lazysite plainfolder);
    spit( "$d/sites/old/index.md",            "---\ntitle: Old\n---\nO\n" );
    spit( "$d/sites/declared/index.md",       "---\ntitle: Declared\n---\nD\n" );
    spit( "$d/unpacked/lazysite.conf",        "site_name: Another\n" );
    spit( "$d/nested/lazysite/lazysite.conf", "site_name: Nested\n" );
    spit( "$d/plainfolder/page.md",           "---\ntitle: Folder\n---\nF\n" );
    my $out = run_check($d);
    like( $out, qr{sites/old looks like another site's content \(it is under sites/\) but is not a declared content root: the bare host serves its pages; the sitemap and llms\.txt leave it out},
        'a folder under sites/ is named' ) or diag $out;
    like( $out, qr{unpacked looks like another site's content \(it holds its own lazysite\.conf\)}, 'a folder with its own lazysite.conf' );
    like( $out, qr{nested looks like another site's content \(it holds its own lazysite\.conf\)}, 'or its own lazysite/lazysite.conf' );
    like( $out, qr{declare it as a domain's content root \(alias\.<host>\.content_root: sites/old in lazysite\.conf\), or move it out of the docroot},
        'with the remedy' );
    unlike( $out, qr{(?:sites/declared|plainfolder) looks like}, 'a declared root and an ordinary folder are not named' );
    unlike( run_check( site() ), qr{looks like another site's content}, 'silent on a site with none' );
};

# Ruling 172: the Debian package recommends tzdata, the zone files time_zone:
# names; the check (below) still names a zone the host cannot find.
subtest 'the package recommends tzdata' => sub {
    open my $cf, '<', repo_root() . '/debian/control' or die "debian/control: $!";
    my $control = do { local $/; <$cf> };
    close $cf;
    my ($stanza) = $control =~ /(^Package: lazysite-common\n.*?)(?:\n\n|\z)/ms;
    ok( $stanza, 'control has a lazysite-common stanza' ) or return;
    my ($rec) = $stanza =~ /^Recommends:\n((?: \S+,?\n)+)/m;
    like( $rec // '', qr/^ tzdata,?$/m, 'lazysite-common Recommends tzdata' );
    my ($dep) = $stanza =~ /^Depends:\n((?: \S+,?\n)+)/m;
    unlike( $dep // '', qr/tzdata/, 'and does not Depend on it' );
};

subtest 'the time zone' => sub {
    like( run_check( site( conf => "time_zone: Mars/Olympus_Mons\n" ) ),
        qr/time_zone 'Mars\/Olympus_Mons' is not a zone this host knows/, 'an unknown zone is named' );
    SKIP: {
        skip 'no zoneinfo for Europe/London', 1 unless -f '/usr/share/zoneinfo/Europe/London';
        like( run_check( site( conf => "time_zone: Europe/London\n" ) ), qr/time_zone is Europe\/London/, 'a real one is OK' );
    }
    unlike( run_check( site() ), qr/time_zone/, 'no key, nothing said' );
};

done_testing();
