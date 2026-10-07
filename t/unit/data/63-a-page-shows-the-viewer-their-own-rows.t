#!/usr/bin/perl
# SM857, the read half: `db:<table>(mine)` - the viewer's own rows.
#
# A page binding could not name the viewer (deliberately - SM856), so no filter
# in this engine was written by the server and a page rendered the same rows for
# everybody. `(mine)` is the one the server writes: the ENGINE adds
# `created_by = <the signed-in viewer>`, from the trust-gated identity, and
# nothing in the binding or the request supplies the value.
#
# Ruled R3 (2026-10-07), and these are its clauses, each held below through the
# real render path - the processor run as the CGI it is:
#
#   * an anonymous viewer sees NO rows - never all rows, never an error page;
#   * a table without created_by (no `timestamps: true`) is refused BY NAME at
#     render and logged - never silently empty, never all rows;
#   * a (mine) page bypasses the shared page cache exactly as a gated page does.
#     THIS IS THE SECURITY PROPERTY: a cached (mine) page served to the next
#     viewer is one person's rows on another person's screen;
#   * rows written before SM860 carry no created_by and belong to NOBODY - an
#     empty owner never matches a viewer, including an anonymous one.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir processor_path load_processor);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row);
use Lazysite::Data::Query  qw(parse_binding);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my $docroot = site_tempdir();    # lint 118: not a bare tempdir
setup_test_site($docroot);
make_path("$docroot/lazysite/db/tables");

# PUBLIC on purpose. A private table already refuses an anonymous viewer at the
# table gate, so the anonymous case would pass without (mine) doing anything;
# published, the only thing between a visitor and every row is (mine) itself.
spit( "$docroot/lazysite/db/tables/notes.yaml",
    "title: Notes\npublic: true\ntimestamps: true\n"
        . "fields:\n  body:\n    type: text\n  status:\n    type: text\n" );
spit( "$docroot/lazysite/db/tables/plain.yaml",
    "title: Plain\npublic: true\nfields:\n  body:\n    type: text\n" );
apply_schema( $docroot, $_ ) for qw(notes plain);

insert_row( $docroot, 'notes', { body => 'ANN-ONE', status => 'open' }, actor => 'ann' );
insert_row( $docroot, 'notes', { body => 'ANN-TWO', status => 'closed' }, actor => 'ann' );
insert_row( $docroot, 'notes', { body => 'BOB-ONE', status => 'open' }, actor => 'bob' );

# Rows written before SM860: one with created_by NULL (what an anonymous write
# stamps) and one with it EMPTY - both spellings of "nobody" a store can hold.
insert_row( $docroot, 'notes', { body => 'NOBODY-NULL',  status => 'open' } );
insert_row( $docroot, 'notes', { body => 'NOBODY-EMPTY', status => 'open' } );
{
    my $dbh = DBI->connect( "dbi:SQLite:dbname=$docroot/lazysite/db/data.sqlite",
        '', '', { RaiseError => 1 } );
    $dbh->do(q{UPDATE notes SET created_by = '' WHERE body = 'NOBODY-EMPTY'});
    $dbh->disconnect;
}
insert_row( $docroot, 'plain', { body => "PLAIN-$_" } ) for 1 .. 2;

open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "plugins:\n  - plugins/data.pl\n";
close $cf;

my $LIST = '[% FOREACH i IN items %]<li>[% i.body %]</li>[% END %]';

# WITH A ttl:, which is the shape that leaks. A db: binding withdraws the mtime
# proof of freshness (SM604), so a page with no ttl: re-renders every request
# whatever the cache holds; one with a ttl: is served from the cache for that
# long - to whoever asks next.
spit( "$docroot/mine.md",
    "---\ntitle: Mine\nttl: 300\ntt_page_var:\n  items: db:notes(mine,order=body)\n"
        . "  n: db:notes.count(mine)\n---\n$LIST count=[% n %]\n" );
spit( "$docroot/mine-open.md",
    "---\ntitle: Mine open\ntt_page_var:\n  items: db:notes(mine, status=open)\n---\n$LIST\n" );
spit( "$docroot/plain-mine.md",
    "---\ntitle: Plain mine\ntt_page_var:\n  items: db:plain(mine)\n---\n$LIST\n" );
spit( "$docroot/by-bob.md",
    "---\ntitle: By bob\ntt_page_var:\n  items: db:notes(created_by=bob)\n---\n$LIST\n" );
spit( "$docroot/all.md",
    "---\ntitle: All\ntt_page_var:\n  items: db:notes(order=body)\n---\n$LIST\n" );

my $logfile = "$docroot/../render.log";

# The processor as the CGI it is. The viewer arrives the way the auth wrapper
# delivers one: X-Remote-User with LAZYSITE_AUTH_TRUSTED=1, set only after it
# verified the session cookie. Anything inherited is cleared first.
sub render {
    my ( $uri, %as ) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\ALAZYSITE_/ } keys %ENV;
    $ENV{DOCUMENT_ROOT}      = $docroot;
    $ENV{REDIRECT_URL}       = $uri;
    $ENV{REQUEST_METHOD}     = 'GET';
    $ENV{QUERY_STRING}       = '';
    $ENV{LAZYSITE_LOG_LEVEL} = 'INFO';
    if ( defined $as{user} ) {
        $ENV{HTTP_X_REMOTE_USER}    = $as{user};
        $ENV{LAZYSITE_AUTH_TRUSTED} = '1' unless $as{forged};
    }
    unlink $logfile;
    my $proc = processor_path();
    my $out  = qx($^X \Q$proc\E 2>\Q$logfile\E);
    return ( $out, slurp($logfile) );
}

sub bodies {
    my ($out) = @_;
    return join ',', sort( $out =~ m{<li>([A-Z]+-[A-Z0-9]+)</li>}g );
}

# --- THE CANARY ---------------------------------------------------------------
# The fixture renders rows at all, and an ordinary page IS cached here - so the
# absence of a (mine) page's cache file below is a finding, not a fixture that
# never caches anything.
{
    my ($out) = render('/all');
    is( bodies($out), 'ANN-ONE,ANN-TWO,BOB-ONE,NOBODY-EMPTY,NOBODY-NULL',
        'canary: an ordinary binding renders every row' );
    ok( -f "$docroot/all.html", 'canary: and an ordinary page is written to the page cache' );
}

# --- the viewer's own rows ----------------------------------------------------
my ( $ann_out, $ann_log ) = render( '/mine', user => 'ann' );
is( bodies($ann_out), 'ANN-ONE,ANN-TWO', 'ann sees her own rows and nobody else\'s' );
like( $ann_out, qr/count=2\b/, 'and .count(mine) counts hers' );
unlike( $ann_out, qr/NOBODY-/,
    'a row with an empty or NULL created_by is nobody\'s - not ann\'s' );

# --- THE SECURITY PROPERTY: the page cache ------------------------------------
ok( !-e "$docroot/mine.html", 'the (mine) page was NOT written to the shared page cache' );
like( $ann_out, qr/^Cache-Control: no-store, private/m,
    'and is served no-store, as a gated page is' );

my ($bob_out) = render( '/mine', user => 'bob' );
is( bodies($bob_out), 'BOB-ONE', 'bob, rendering the same page straight after ann, sees only his' );
unlike( $bob_out, qr/ANN-/, 'and none of ann\'s rows reach him' );
like( $bob_out, qr/count=1\b/, 'and his count is his' );

# --- an anonymous viewer ------------------------------------------------------
my ( $anon_out, $anon_log ) = render('/mine');
like( $anon_out, qr/^Status: 200/m, 'an anonymous viewer gets the page, not an error' );
is( bodies($anon_out), '', 'and NO rows - not every row, after ann rendered it' );
unlike( $anon_out, qr/NOBODY-/,
    'in particular not the rows nobody owns - anonymous is not "created_by is empty"' );
like( $anon_out, qr/count=0\b/,                                'and a count of nothing' );
like( $anon_log, qr/\(mine\) binding has no signed-in viewer/, 'and the log says why' );

# --- the identity cannot be forged --------------------------------------------
{
    my ($out) = render( '/mine', user => 'ann', forged => 1 );
    is( bodies($out), '',
        'an X-Remote-User the auth wrapper did not vouch for is stripped: no rows' );
}

# --- (mine) combines with the literal filters ---------------------------------
{
    my ($out) = render( '/mine-open', user => 'ann' );
    is( bodies($out), 'ANN-ONE', '(mine, status=open) is ann\'s rows AND open ones' );
}

# --- a table with no owner column ---------------------------------------------
{
    my ( $out, $log ) = render( '/plain-mine', user => 'ann' );
    like( $out, qr/^Status: 200/m, 'a (mine) binding on a table with no created_by still renders the page' );
    is( bodies($out), '', 'with no rows - never every row' );
    like( $log, qr/\(mine\) binding refused - the table has no created_by/,
        'and the refusal is logged, so it is not silently empty' );
    like( $log, qr/table=plain\b/,               'naming the table' );
    like( $log, qr/timestamps: true on 'plain'/, 'and what to set' );
}

# --- and validate_page says it before anybody renders the page ----------------
{
    require Lazysite::Validate;
    my $bad = Lazysite::Validate::validate_content(
        content => slurp("$docroot/plain-mine.md"), docroot => $docroot );
    ok( ( grep { $_->{kind} eq 'db-mine-no-owner' } @{ $bad->{issues} } ),
        'validate_page reports (mine) on a table with no created_by as an issue' );
    my $good = Lazysite::Validate::validate_content(
        content => slurp("$docroot/mine.md"), docroot => $docroot );
    ok( !( grep { $_->{kind} eq 'db-mine-no-owner' } @{ $good->{issues} } ),
        'and does not report it on a table that has one' );
}

# --- the parser: one grammar, `mine` the bare word -----------------------------
{
    my $p = parse_binding('db:notes(mine, status=open, limit=5)');
    ok( $p->{ok} && $p->{mine}, 'the parser reads the bare word as (mine)' );
    is_deeply( $p->{filters}, { status => 'open' }, 'and it is not a filter' );
    my $f = parse_binding('db:notes(mine=x)');
    ok( !$f->{mine}, 'mine=x is a filter on a field called mine, not (mine)' );
    my $s = parse_binding('db:notes mine order=body');
    ok( $s->{mine}, 'the older space form says it too' );

    my $d    = Lazysite::Data::Tables::load_table( $docroot, 'notes' );
    my $both = parse_binding( 'db:notes(mine,created_by=bob)', $d );
    ok( !$both->{ok}, 'a literal created_by beside (mine) is refused, not resolved either way' );
    like( $both->{error} // '', qr/supplies created_by itself/, 'and says which' );
}

# A literal created_by filter is a filter on a column the table owns, and the
# parser always admitted it - the store's WHERE refused it until (mine) needed it.
{
    my ($out) = render('/by-bob');
    is( bodies($out), 'BOB-ONE', 'a literal created_by=bob filter renders bob\'s rows' );
}

# --- (mine) only reaches a render nobody else will be served -------------------
# The front-matter trigger is what marks a page per-viewer; a (mine) binding the
# mark never reached (a site-wide variable, an error page, a binding the peek
# cannot see) is refused rather than rendered into a cacheable page.
{
    local $ENV{HTTP_X_REMOTE_USER}    = 'ann';
    local $ENV{LAZYSITE_AUTH_TRUSTED} = '1';
    load_processor($docroot);
    main::_reset_units();
    my $err = '';
    my ( $rows, $guarded );
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        ($rows) = main::resolve_db( 'notes(mine)', 'items' );
        no warnings 'once';
        local %main::RENDER_QUERY = ( _protected => 1 );
        ($guarded) = main::resolve_db( 'notes(mine)', 'items' );
        close STDERR;
    }
    is( scalar @{$rows}, 0, 'outside a per-viewer render, (mine) renders nothing' );
    like( $err, qr/\(mine\) binding refused - it is not in a page's own tt_page_var/,
        'and says why' );
    is( scalar @{$guarded}, 2, 'inside one, the same binding renders the viewer\'s rows' );
}

done_testing();
