#!/usr/bin/perl
# SM359: search_files was honest about withholding and offered no way to ask for
# the rest, and its two limits were indistinguishable.
#
# WHAT IS BEING PAGED, because it decided what to build. A depth-first walk of
# the site's own content tree reading a few hundred small text files - 181 on
# lazysite.io, 442 on dito.tech - against a 2,000-file budget and a 200-match
# cap. The FILE budget never fires on a real site; it stops a runaway tree. The
# MATCH cap fires constantly, because a common word reaches 200 hits in the first
# few pages.
#
# So the caller who hits truncation almost always has too broad a QUERY rather
# than too small a page, and the response could not say so - both limits set the
# same bare boolean, and the two want opposite responses. Naming which one
# stopped the walk is the smaller change and the more useful one, so it is
# tested first.
#
# NOT TESTED, because it is not built: a total. The scan stops AT the cap, so
# "200 of 1,431" would mean walking the whole tree and reading every file -
# exactly the cost the cap avoids.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";

# A site with a known number of matches, spread over several files so the walk
# has to cross directories to collect them.
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/a/deep");
make_path("$docroot/b");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nmcp_enabled: true\n";
close $cf;

my $TOTAL = 0;
for my $spec ( [ 'index.md', 5 ], [ 'a/one.md', 7 ], [ 'a/deep/two.md', 6 ], [ 'b/three.md', 4 ] ) {
    my ( $rel, $n ) = @$spec;
    open my $fh, '>', "$docroot/$rel" or die $!;
    print {$fh} "---\ntitle: T\n---\n";
    print {$fh} "line $_ says NEEDLE here\n" for 1 .. $n;
    close $fh;
    $TOTAL += $n;
}

sub search {
    my (%args) = @_;
    # A different tree for the file-budget case, passed rather than localised:
    # $docroot is a lexical and local() does not reach one.
    my $root_dir = delete $args{_docroot} // $docroot;
    my $stub     = "$root_dir/users-stub.pl";
    open my $sf, '>', $stub or die $!;
    print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
    close $sf;
    chmod 0755, $stub;

    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'search_files', arguments => { query => 'NEEDLE', %args } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $root_dir;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = eval { decode_json( $jb // '' ) };
    return $r && $r->{result} ? $r->{result}{structuredContent} : undef;
}

subtest 'the whole set, when it fits' => sub {
    my $r = search();
    ok( $r && $r->{ok}, 'search answers' ) or diag encode_json( $r // {} );
    is( $r->{count},     $TOTAL,          "all $TOTAL matches returned" );
    is( $r->{truncated}, JSON::PP::false, 'and nothing is withheld' );
    ok( !exists $r->{truncated_reason},
        'no reason, because nothing stopped the walk - its absence is not a '
            . 'third state to interpret' );
};

subtest 'a truncated set says WHY it stopped' => sub {
    # The whole point. "There is more, ask again or narrow the query" and "the
    # tree was too big to finish, narrow the base" want opposite responses from
    # the caller and used to be the same boolean.
    my $r = search( limit => 5 );
    is( $r->{count},     5,              'a page of five' );
    is( $r->{truncated}, JSON::PP::true, 'truncated' );
    is( $r->{truncated_reason}, 'match_limit',
        'because the MATCH limit stopped it, not the file budget' );
};

subtest 'and it can be paged to completion' => sub {
    my ( @seen, $pages );
    my $offset = 0;
    while (1) {
        my $r = search( limit => 5, offset => $offset );
        push @seen, map { "$_->{path}:$_->{line}" } @{ $r->{matches} };
        $pages++;
        last unless $r->{truncated};
        $offset += $r->{count};
        die 'runaway' if $pages > 20;
    }
    is( scalar @seen, $TOTAL, "every one of the $TOTAL matches was reached" );

    my %once;
    $once{$_}++ for @seen;
    is( scalar( grep { $once{$_} > 1 } keys %once ), 0,
        'each exactly once - no skips, no repeats, on a tree that did not change' );
};

subtest 'the last page reports itself as the last' => sub {
    # `truncated` means "there is more after this page", not "this page is
    # full". They differ on exactly the page a caller stops on, so a caller that
    # reads it as "full" pages for ever or stops one page early.
    my $r = search( limit => $TOTAL );
    is( $r->{count}, $TOTAL, 'the page holds everything' );
    is( $r->{truncated}, JSON::PP::false,
        'and is not truncated, though it is exactly full' );
};

subtest 'count says what it counts' => sub {
    my $r = search( limit => 3 );
    is( $r->{count},  3, 'count is matches RETURNED' );
    is( $r->{limit},  3, 'the limit is echoed' );
    is( $r->{offset}, 0, 'and the offset, so a caller can page without bookkeeping' );
    ok( !exists $r->{total},
        'no total is claimed - the scan stops early by design, so producing one '
            . 'would mean reading every file' );
};

subtest 'a limit is bounded, and nonsense falls back to the default' => sub {
    my $r = search( limit => 100_000 );
    is( $r->{limit}, 500, 'a huge limit is capped rather than honoured' );

    my $z = search( limit => 0 );
    is( $z->{limit}, 200, 'a zero limit is the default, not an empty response' );
};

subtest 'paging past the end is empty, not an error' => sub {
    my $r = search( offset => $TOTAL + 10 );
    ok( $r && $r->{ok}, 'still ok' );
    is( $r->{count},     0,               'with nothing in it' );
    is( $r->{truncated}, JSON::PP::false, 'and not truncated' );
};

subtest 'the exclusions hold on every page, not only the first' => sub {
    # The filing named this as the thing that would be easy to get wrong while
    # adding paging, and it was right to.
    #
    # WHAT ACTUALLY EXCLUDES IT, stated accurately because the first version of
    # this comment got it wrong. The engine tree is skipped at DESCENT - the
    # walk never pushes `lazysite` or `lazysite-assets` onto the stack - so a
    # file there is never a candidate at any offset. `is_blocked_path` is also
    # applied per candidate as defence in depth, and in this walk it is
    # unreachable: it catches the lazysite/ tree (already skipped) and dangerous
    # extensions, and none of those appears in the searchable extension set.
    # Checked, rather than assumed - removing the blocklist call leaves this
    # test passing, which is exactly what defence in depth looks like from a
    # test and is worth knowing before someone reads a green suite as coverage.
    #
    # What IS asserted here is the property that matters for paging: the skip
    # happens before anything advances the match counter, so an excluded file
    # cannot surface at a later offset.
    open my $fh, '>', "$docroot/lazysite/secret.md" or die $!;
    print {$fh} "NEEDLE in the engine tree\n" for 1 .. 3;
    close $fh;

    for my $offset ( 0, 5, 10, 15, 20 ) {
        my $r = search( limit => 5, offset => $offset );
        is( scalar( grep { $_->{path} =~ m{/lazysite/} } @{ $r->{matches} } ),
            0, "nothing from the engine tree at offset $offset" );
    }
    unlink "$docroot/lazysite/secret.md";
};

subtest 'the FILE budget is a different answer from the match limit' => sub {
    # Without this the distinction the whole change is for goes untested:
    # collapsing both reasons into 'match_limit' left the suite green, because
    # no fixture had ever been large enough to reach the file budget.
    #
    # It needs a genuinely oversized tree rather than a lowered constant. The
    # budget is what the running engine uses, and a test that reaches it by
    # moving the goalposts proves the goalposts move.
    my $big = tempdir( CLEANUP => 1 );
    make_path("$big/lazysite/auth");
    make_path("$big/many");
    open my $bc, '>', "$big/lazysite/lazysite.conf" or die $!;
    print {$bc} "site_name: B\nmcp_enabled: true\n";
    close $bc;
    for my $i ( 1 .. 2100 ) {
        open my $fh, '>', "$big/many/f$i.md" or die $!;
        print {$fh} "nothing of interest here\n";
        close $fh;
    }

    my $r = search( _docroot => $big );
    is( $r->{truncated}, JSON::PP::true, 'a tree over the budget truncates' );
    is( $r->{truncated_reason}, 'file_budget',
        'and says the FILE budget stopped it - narrow the base, not the query' )
        or diag( 'match_limit and file_budget want opposite responses from the '
            . 'caller. One boolean for both was the defect.' );
    is( $r->{count}, 0, 'with no matches, since none of those files hold one' );
};

done_testing();
