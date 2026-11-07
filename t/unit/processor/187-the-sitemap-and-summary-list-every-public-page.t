#!/usr/bin/perl
# SM1357, ruling 165: THE SITEMAP AND THE AI-READABLE SUMMARY (llms.txt) LIST
# EVERY PUBLIC PAGE - and nothing that is not one.
#
# They used to list only the pages that registered for them, so a page an author
# never thought to register was invisible to a search engine. Held here:
#
#   * a page with no register: key is in both; one whose register: names only a
#     feed keeps what it says and is in neither;
#   * NEVER LISTED, whatever it registers: a protected page (auth:, auth_groups:,
#     a read rule), a draft section, an api:/raw: page, a page copy (SM1354
#     keeps them under lazysite/copies/), a page that says search: false, a
#     starter demonstration page, and the engine's system pages at the root;
#   * the summary carries titles, descriptions and the organisation entry;
#   * `llms_txt: off` turns the summary off - not generated, not served - and
#     leaves the sitemap as it was;
#   * the system page names here are the script's %SYSTEM_PAGES.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir run_processor repo_root processor_path);

sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $root = repo_root();

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    setup_test_site($d);
    make_path("$d/lazysite/templates/registries", "$d/lazysite/auth");
    copy( "$root/starter/lazysite/templates/registries/$_.tt", "$d/lazysite/templates/registries/$_.tt" )
        or die $! for qw(sitemap.xml llms.txt feed.rss);
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} $o{conf} if $o{conf};
    close $cf;

    spit( "$d/plain.md",      "---\ntitle: Plain page\nsubtitle: A page nobody registered\n---\nP\n" );
    spit( "$d/feed-only.md",  "---\ntitle: Feed only\nregister:\n  - feed.rss\n---\nF\n" );
    spit( "$d/both.md",       "---\ntitle: Both\nregister:\n  - sitemap.xml\n  - llms.txt\n---\nB\n" );
    spit( "$d/members.md",    "---\ntitle: Members\nauth: required\nregister:\n  - sitemap.xml\n  - llms.txt\n---\nM\n" );
    spit( "$d/grouped.md",    "---\ntitle: Grouped\nauth_groups:\n  - staff\n---\nG\n" );
    spit( "$d/ruled/page.md", "---\ntitle: Ruled\n---\nR\n" );
    spit( "$d/upcoming/next.md", "---\ntitle: Upcoming\n---\nU\n" );
    spit( "$d/data.md",       "---\ntitle: Data\napi: true\nregister:\n  - sitemap.xml\n---\n{}\n" );
    spit( "$d/rawfile.md",    "---\ntitle: Raw file\nraw: true\n---\nX\n" );
    spit( "$d/hidden.md",     "---\ntitle: Hidden\nsearch: false\n---\nH\n" );
    spit( "$d/demo.md",       "---\ntitle: Demo\nstarter_role: demonstration\n---\nD\n" );
    spit( "$d/lazysite/copies/pages/plain.md", "---\ntitle: COPY OF PLAIN\n---\nC\n" );
    spit( "$d/login.md",      "---\ntitle: Sign in\n---\nL\n" );
    spit( "$d/lazysite/auth/acls.json", JSON::PP->new->encode( {
        ruled    => { read => ['@editors'] },
        upcoming => { draft => JSON::PP::true },
    } ) );
    return $d;
}

sub body { my ($o) = @_; $o =~ s/\A.*?\r?\n\r?\n//s; return $o }

subtest 'the sitemap lists every public page and nothing else' => sub {
    my $d   = site();
    my $map = run_processor( $d, '/sitemap.xml' );
    like( $map, qr{<loc>http://localhost/plain</loc>}, 'a page nobody registered is listed' );
    like( $map, qr{<loc>http://localhost/</loc>},      'the home page too' );
    like( $map, qr{<loc>http://localhost/both</loc>},  'a registered page, as before' );
    for my $out (qw(feed-only members grouped ruled/page upcoming/next data rawfile hidden demo login 404 api-test raw-test)) {
        unlike( $map, qr{<loc>http://localhost/\Q$out\E</loc>}, "not /$out" );
    }
    unlike( $map, qr{COPY|copies}, 'and no page copy' );
};

subtest 'the summary: public pages, titles, descriptions, the organisation' => sub {
    my $d = site( conf => "site_address: 1 High Street\nsite_email: hello\@example.org\n" );
    my $out = run_processor( $d, '/llms.txt' );
    like( $out, qr{^Content-Type: text/plain}mi, 'served as text' );
    my $txt = body($out);
    like( $txt, qr{^- \[Plain page\]\(http://localhost/plain\.md\): A page nobody registered$}m,
        'a page with its title and description' );
    for my $out (qw(Members Grouped Ruled Upcoming Data), 'Raw file', qw(Hidden Demo), 'COPY OF PLAIN', 'Feed only', 'Sign in') {
        unlike( $txt, qr{\[\Q$out\E\]}, "not $out" );
    }
    like( $txt, qr{^## About$}m,                       'the organisation entry' );
    like( $txt, qr{^- Address: 1 High Street$}m,       'with the site\'s address' );
    like( $txt, qr{^- Email: hello\@example\.org$}m,   'and its email' );

    my $plain = site();
    unlike( body( run_processor( $plain, '/llms.txt' ) ), qr{## About}, 'no organisation entry on a site that states none' );
};

subtest 'llms_txt: off turns the summary off, and only the summary' => sub {
    my $d   = site( conf => "llms_txt: off\n" );
    my $out = run_processor( $d, '/llms.txt' );
    unlike( $out, qr{^Status: 200}m, 'the summary is not served' );
    unlike( $out, qr{\[Plain page\]}, 'and lists nothing' );
    ok( !-e "$d/lazysite/cache/registries/_root/llms.txt", 'nor is it generated' );
    like( run_processor( $d, '/sitemap.xml' ), qr{<loc>http://localhost/plain</loc>}, 'the sitemap is unchanged' );

    my $on = site();
    like( run_processor( $on, '/llms.txt' ), qr{^Status: 200}m, 'on by default' );
    ok( -e "$on/lazysite/cache/registries/_root/llms.txt", 'and generated where the off site has none' );
};

subtest 'the system page names are the script\'s' => sub {
    open my $fh, '<', processor_path() or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($list) = $src =~ /my %SYSTEM_PAGES = map \{ \$_ => 1 \} qw\(([^)]*)\)/;
    ok( defined $list, 'the script\'s list is found' );
    open my $rf, '<', "$root/lazysite-processor/registries.pm" or die $!;
    my $reg = do { local $/; <$rf> };
    close $rf;
    my ($mine) = $reg =~ /my %sys = map \{ \( "\/\$_" => 1 \) \} qw\(([^)]*)\)/;
    is_deeply( [ sort split ' ', $mine // '' ], [ sort split ' ', $list // '' ], 'and the registries\' copy is the same set' );
};

done_testing();
