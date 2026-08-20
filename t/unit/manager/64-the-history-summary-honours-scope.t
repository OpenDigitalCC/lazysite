#!/usr/bin/perl
# SM419: the content-history SUMMARY answered "who may see this path?"
# differently from the per-file history beside it.
#
# git-history / git-show / git-restore all resolve through _git_target, which
# blocklists and scope-confines. Their site-level complement, the summary, did
# neither: it ls-tree'd the whole committed tree and returned every path with
# its revision count, dates and last author. So a partner confined to one
# content root was refused clientB's per-file history and handed clientB's
# file inventory and edit cadence by the overview beside it - plus engine
# paths like lazysite.conf that a direct read refuses.
#
# Metadata only, and benign on a single-tenant site. On a multi-tenant one it
# is the neighbour's file tree, which is exactly the boundary the rest of the
# feature honours.
#
# Reported by the security-review agent's round-3 pass, reproduced against the
# real MCP binary. This drives the module directly, and asserts BOTH
# directions: a scoped caller sees only its own, an unscoped operator still
# sees everything.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();
use Lazysite::Git             ();

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/content/clientA", "$d/content/clientB", "$d/lazysite" );

sub spit {
    open my $fh, '>', $_[0] or die $!;
    print {$fh} $_[1];
    close $fh;
}
spit( "$d/lazysite/lazysite.conf",   "site_name: T\ngit_history: enabled\n" );
spit( "$d/content/clientA/notes.md", "A one\n" );
spit( "$d/content/clientB/notes.md", "B one\n" );

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;

my $init = Lazysite::Git::init( $d, 'operator' );
plan skip_all => 'content history could not initialise (no git?)'
    unless ref $init eq 'HASH' && $init->{ok};

sub paths_for {
    my ($scopes) = @_;
    my $r = Lazysite::Manager::Files::action_git_history_summary($scopes);
    return ( $r, [ map { $_->{path} } @{ $r->{files} || [] } ] );
}

subtest 'the fixture really recorded both tenants' => sub {
    # Without this, every assertion below could pass against an empty summary -
    # the shape of a test that proves nothing because the feature never ran.
    my ( $r, $paths ) = paths_for(undef);
    ok( $r->{ok} && $r->{enabled}, 'history is enabled' ) or diag explain $r;
    ok( ( grep { m{clientA/notes\.md} } @$paths ), 'clientA is recorded' )
        or diag( join ', ', @$paths );
    ok( ( grep { m{clientB/notes\.md} } @$paths ), 'clientB is recorded too' );
};

subtest 'a scoped caller sees only its own scope' => sub {
    my ( $r, $paths ) = paths_for( ['content/clientA'] );
    ok( ( grep { m{clientA/notes\.md} } @$paths ), 'its own file is there' );
    is( scalar( grep { m{clientB} } @$paths ), 0,
        'and NOTHING of the neighbour - not the path, not the edit cadence' )
        or diag( join ', ', @$paths );
};

subtest 'the totals describe what the caller can see' => sub {
    # A count that disagrees with its own list is its own disclosure: it tells
    # a scoped caller how many files it is not being shown.
    my ( $r, $paths ) = paths_for( ['content/clientA'] );
    is( $r->{summary}{files}, scalar @$paths,
        'summary.files matches the filtered list' );
    my $rev = 0;
    $rev += ( $_->{revisions} // 0 ) for @{ $r->{files} };
    is( $r->{summary}{revisions}, $rev, 'and so does the revision total' );
};

subtest 'blocklisted paths are absent for everyone' => sub {
    # A blocked path is blocked for its own reasons, not the caller's - an
    # unscoped operator is refused lazysite.conf on a direct read, so the
    # summary must not hand it over with dates and an author either.
    my ( $r, $paths ) = paths_for(undef);
    is( scalar( grep { m{^lazysite/lazysite\.conf$} } @$paths ), 0,
        'lazysite.conf is not in an unscoped summary' )
        or diag( join ', ', @$paths );
};

subtest 'an UNSCOPED operator still sees the whole site' => sub {
    # The control. A filter that hid everything would pass every assertion
    # above, and would break the feature for the single-tenant case that is
    # most of the fleet.
    my ( undef, $paths ) = paths_for(undef);
    ok( ( grep { m{clientA/notes\.md} } @$paths ), 'clientA present' );
    ok( ( grep { m{clientB/notes\.md} } @$paths ), 'clientB present' );
    my ( undef, $empty ) = paths_for( [] );
    is_deeply( $empty, $paths,
        'an EMPTY scope list means the whole site, as it does everywhere else' );
};

# --- SM419: the defect the fix uncovered -------------------------------------
#
# is_blocked_config -> upload_limits -> load_upload_limits, which read the
# config with `while (<$fh>)` and so assigned the GLOBAL $_. Called from inside
# a grep, that DESTROYS the element under test: the summary filter dropped the
# first path it looked at, silently.
#
# It is nastier than it sounds because upload_limits MEMOISES. Only the first
# call in a process clobbers, so the first element of the first such grep comes
# back empty and every subsequent one is fine - a corruption that looks like
# anything except what it is, and that a second run of the same code hides.
#
# The predicate is what is asserted, not the summary, because any caller can
# hit this: `grep { is_blocked_config($_) } @paths` is the obvious spelling.
subtest 'the blocklist predicates do not clobber the caller\'s $_' => sub {
    my @items = map { { path => "content/f$_.md" } } 1 .. 3;

    my @survivors = grep {
        defined $_->{path}
            && !Lazysite::Manager::Common::is_blocked_path( $_->{path} )
            && !Lazysite::Manager::Common::is_blocked_config( $_->{path} )
    } @items;

    is( scalar @survivors, 3,
        'every element survives a grep that calls the predicates' )
        or diag( 'A sub reading a filehandle with while(<$fh>) assigns the '
            . 'global $_; without `local $_` it eats the grep element under '
            . 'test. This asserts 3 because the FIRST is the one that dies.' );
    is_deeply( [ map { $_->{path} } @survivors ],
        [ map { $_->{path} } @items ],
        'and each keeps its own path, in order' );
};

done_testing();
