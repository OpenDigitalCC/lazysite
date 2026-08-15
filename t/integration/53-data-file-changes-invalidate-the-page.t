#!/usr/bin/perl
# SM311: a page's data files are dependencies, and the cache tracks them.
#
# THE DEFECT, as measured by a site agent on edge running 0.10.9 during a mock
# customer build:
#
#   Initial publish, 8 items in the JSON        8 cards
#   Add a 9th item, upload the JSON alone       8 cards
#   Flush the page (GET then byte-identical PUT) 9 cards
#
# The upload succeeded, the JSON served correctly at its own URL, and the page
# carried on serving the previous render. A cached page was fresh whenever it
# post-dated its .md and lazysite.conf; a change to a file the page merely READS
# is neither.
#
# WHY IT IS WORSE THAN ORDINARY CACHE STALENESS. It defeats the feature's only
# reason to exist. Writing the list into the page would have worked - the data
# file exists so a non-technical owner, a scheduled export, or someone without
# page-editing rights can change what the page shows. That is exactly the caller
# for whom the failure is invisible AND unfixable: recovery means saving the
# page, which needs `manage_content`, which a data-directory editor does not
# hold. Nothing errors; the page is valid, fast and wrong.
#
# It is SM251 one layer down. A registry rebuilds during page PROCESSING, so
# requesting the registry does not refresh it; a page re-renders when the page is
# SAVED, so changing what it renders FROM does not refresh it. Both assume an
# artefact's inputs change only when the artefact does.
#
# This drives the real processor as a CGI, because the defect lives in the
# interaction between the render and the cache - the two things a unit test of
# either half would mock.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/themes");
make_path("$docroot/data");
make_path("$docroot/notes");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

sub write_file {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print $fh $body;
    close $fh;
}

# Fetch a page through the processor exactly as the web server would.
sub get_page {
    my ($uri) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'GET',
        REDIRECT_URL   => $uri,
        QUERY_STRING   => '',
    );
    my $out = qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out // '';
}

# Shift EVERY existing file back, preserving relative order, so a subsequent
# write lands strictly newer than all of them.
#
# THE FIRST CUT OF THIS AGED ONLY THE CACHED HTML, and the whole file passed
# against the UNFIXED engine - which is the only reason the flaw was caught.
# Ageing the render alone makes it older than its own .md, so the cache misses on
# the ordinary mtime rule and the page re-renders for a reason that has nothing
# to do with the dependency record. The test would have reported the fix working
# on an engine that did not have it.
#
# What the defect actually needs is a cache that is newer than its .md AND newer
# than the conf - genuinely fresh by every pre-existing rule - with only the DATA
# file newer still. Shifting everything back and then writing the data is how you
# get there, and it is also what really happens: an author edits data some time
# after the page was last rendered.
sub settle {
    my ($by) = @_;
    $by ||= 60;
    my $n     = 0;
    my @queue = ($docroot);
    while ( my $dir = shift @queue ) {
        opendir my $dh, $dir or next;
        for my $e ( readdir $dh ) {
            next if $e eq '.' || $e eq '..';
            my $path = "$dir/$e";
            if ( -d $path ) { push @queue, $path; next }
            my @st = stat $path or next;
            utime $st[9] - $by, $st[9] - $by, $path;
            $n++;
        }
        closedir $dh;
    }
    return $n;
}

subtest 'a json: data edit re-renders the page' => sub {
    write_file( "$docroot/data/services.json",
        '[{"name":"One"},{"name":"Two"}]' );
    write_file( "$docroot/services.md", <<'MD' );
---
title: Services
tt_page_var:
  services: json:/data/services.json
---

[% FOREACH s IN services %]<p class="card">[% s.name %]</p>
[% END %]
MD

    my $first = get_page('/services');
    my $n1    = () = $first =~ /class="card"/g;
    is( $n1, 2, 'the first render shows both items' )
        or diag("Page was:\n$first");

    # Add a third item, touching ONLY the data file - the reported action.
    ok( settle() > 0, 'everything is settled, so only the data edit is new' );
    write_file( "$docroot/data/services.json",
        '[{"name":"One"},{"name":"Two"},{"name":"Three"}]' );

    my $second = get_page('/services');
    my $n2     = () = $second =~ /class="card"/g;
    is( $n2, 3, 'editing the data alone updates the page' )
        or diag( "Got $n2 cards, expected 3.\n\n"
            . "The data file is correct on the server and the page disagrees\n"
            . "with it. The person who edited the data cannot fix this: the\n"
            . "recovery is to save the PAGE, which needs manage_content." );
};

subtest 'a scan: source tracks additions, edits and removals' => sub {
    write_file( "$docroot/notes/a.md", "---\ntitle: Alpha\n---\n\nA.\n" );
    write_file( "$docroot/notes/b.md", "---\ntitle: Bravo\n---\n\nB.\n" );
    write_file( "$docroot/index.md",   <<'MD' );
---
title: Index
tt_page_var:
  notes: scan:/notes/*.md
---

[% FOREACH n IN notes %]<p class="row">[% n.title %]</p>
[% END %]
MD

    my $r1 = get_page('/');
    my $c1 = () = $r1 =~ /class="row"/g;
    is( $c1, 2, 'the listing starts with two entries' ) or diag("Page:\n$r1");

    # ADD: no existing file changes, but the directory mtime moves. This is the
    # half a per-file record alone would miss.
    settle();
    write_file( "$docroot/notes/c.md", "---\ntitle: Charlie\n---\n\nC.\n" );
    my $c2 = () = get_page('/') =~ /class="row"/g;
    is( $c2, 3, 'a page ADDED to the scanned directory appears' );

    # EDIT: the directory does not change, only the file. This is the half a
    # directory-mtime check alone would miss - and it is why the record lists
    # the matched files as well as the directories they came from.
    settle();
    write_file( "$docroot/notes/b.md", "---\ntitle: Bravo Renamed\n---\n\nB.\n" );
    my $r3 = get_page('/');
    like( $r3, qr/Bravo Renamed/,
        'a page EDITED in place is re-read - the case a directory mtime cannot see' )
        or diag( "The listing still shows the old title. A scan: source depends\n"
            . "on each matched file's FRONT MATTER, so tracking the directory\n"
            . "alone reports a fix that only half works." );

    # REMOVE: the file is gone, so there is nothing left to stat - the directory
    # mtime is the only remaining signal.
    settle();
    unlink "$docroot/notes/c.md";
    my $c4 = () = get_page('/') =~ /class="row"/g;
    is( $c4, 2, 'a page REMOVED from the scanned directory disappears' );
};

subtest 'a page with no declared sources is unaffected' => sub {
    # The cache behaviour of an ordinary page must not change: this is the
    # compatibility half, and it covers every page on every existing site.
    write_file( "$docroot/plain.md", "---\ntitle: Plain\n---\n\nHello.\n" );

    my $a = get_page('/plain');
    like( $a, qr/Hello/, 'it renders' );

    my $b = get_page('/plain');
    like( $b, qr/Hello/, 'and serves again from cache' );

    # No dependency record is written for a page that declares nothing, so the
    # cache path costs it one hash lookup on the peek it already does.
    my @deps = glob("$docroot/lazysite/cache/*plain*.deps");
    is( scalar @deps, 0, 'and no dependency record is written for it' );
};

subtest 'several pages sharing one data file all refresh' => sub {
    write_file( "$docroot/data/shared.json", '[{"n":"x"}]' );
    for my $p (qw(one two)) {
        write_file( "$docroot/$p.md", <<"MD" );
---
title: $p
tt_page_var:
  items: json:/data/shared.json
---

[% FOREACH i IN items %]<b class="it">[% i.n %]</b>
[% END %]
MD
        my $c = () = get_page("/$p") =~ /class="it"/g;
        is( $c, 1, "$p renders one item" );
    }

    settle();
    write_file( "$docroot/data/shared.json", '[{"n":"x"},{"n":"y"}]' );
    for my $p (qw(one two)) {
        my $c = () = get_page("/$p") =~ /class="it"/g;
        is( $c, 2, "$p picks up the shared edit" );
    }
};

subtest 'a data file that vanishes degrades rather than serving a stale page' => sub {
    write_file( "$docroot/data/gone.json", '[{"n":"a"}]' );
    write_file( "$docroot/vanish.md",      <<'MD' );
---
title: Vanish
tt_page_var:
  items: json:/data/gone.json
---

[% FOREACH i IN items %]<b class="it">[% i.n %]</b>
[% END %]
MD
    my $c = () = get_page('/vanish') =~ /class="it"/g;
    is( $c, 1, 'it renders while the data is there' );

    settle();
    unlink "$docroot/data/gone.json";
    my $after = get_page('/vanish');

    # The page must not keep serving the old render as though nothing happened.
    # What it shows instead is the existing missing-source behaviour, unchanged;
    # what matters here is that the cache stopped claiming to be current.
    unlike( $after, qr/class="it"/,
        'once the data is gone the page stops showing it' )
        or diag( "The cached render outlived its source. A missing dependency\n"
            . "is treated as unproven rather than as unchanged, deliberately:\n"
            . "re-rendering costs a render, serving a stale page costs the\n"
            . "author a silent wrong answer." );
};

done_testing();
