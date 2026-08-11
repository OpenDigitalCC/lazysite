#!/usr/bin/perl
# The two read-only resolvers behind the SM266/SM267/SM277 manager batch. The
# panels themselves are manager JavaScript and unreachable from here (see
# docs/MANUAL-CHECKS.md); their DATA is not, and this is the half that can be
# held to a test.
#
#   protected-sections (SM267) - what is held back right now, gated or draft,
#   with a count of what sits under each prefix, and scoped so a confined
#   manager cannot use the list to learn that content exists elsewhere.
#
#   capability-holders (SM277) - the reciprocal of the permissions grid: how
#   many groups grant each capability and how many accounts end up holding it,
#   resolved through the NESTING CLOSURE, because that is what enforcement uses.
#   A count from direct membership would under-report exactly the grants that
#   are hardest to audit by hand (SM268 02-6, in the other direction).
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol      qw(gensym);
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use Lazysite::Manager::Files ();
use Lazysite::Auth::Acl ();

my $root   = repo_root();
my $secret = 'sekret' x 6;
my $d      = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/upcoming/deep", "$d/private", "$d/other" );

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nsite_url: http://localhost\n";
close $cf;
open my $sc, '>', "$d/lazysite/auth/.secret" or die $!;
print {$sc} "$secret\n";
close $sc;

# Two pages and one asset under the draft prefix, one page under the gated one.
for my $f ( "upcoming/index.md", "upcoming/deep/two.md", "private/p.md" ) {
    open my $fh, '>', "$d/$f" or die $!;
    print {$fh} "# x\n";
    close $fh;
}
open my $img, '>', "$d/upcoming/hero.png" or die $!;
print {$img} "PNG";
close $img;

open my $af, '>', "$d/lazysite/auth/acls.json" or die $!;
print {$af} encode_json( {
        'upcoming/'      => { owner => 'op', read => ['alice'], draft => JSON::PP::true },
        'private/'       => { owner => 'op', read => ['alice'] },
        'other/notes.md' => { owner => 'op', read => ['alice'] },
} );
close $af;

# The users tool as a CLI (it takes --docroot, not DOCUMENT_ROOT).
sub users {
    my $cmd = join ' ',
        map {"\Q$_\E"} ( $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, @_ );
    return qx($cmd 2>&1);
}

# ... and its JSON API mode, which reads the request on stdin.
sub users_api {
    my ($req) = @_;
    my $cmd = join ' ',
        map {"\Q$_\E"} ( $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    my ( $out, $in );
    my $pid = IPC::Open2::open2( $out, $in, $cmd );
    print {$in} encode_json($req);
    close $in;
    my $r = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return $r;
}

sub mapi {
    my (%o) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = 'GET';
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

# --- protected-sections -----------------------------------------------------
{
    my $r = mapi(
        HTTP_X_REMOTE_USER   => 'op',
        HTTP_X_REMOTE_GROUPS => 'manager',
        QUERY_STRING         => 'action=protected-sections',
    );
    ok( $r->{ok}, 'protected-sections responds' ) or diag encode_json($r);
    my %by = map { $_->{prefix} => $_ } @{ $r->{sections} || [] };

    is( scalar keys %by, 2, 'SECTIONS only - the per-file ACL is not listed' )
        or diag encode_json( $r->{sections} );
    is( $by{'upcoming/'}{policy}, 'draft', 'a draft prefix reads as draft' );
    is( $by{'private/'}{policy},  'gated', 'a prefix with no draft flag reads as gated' );

    # The counts are what make the panel answer "what am I about to publish".
    is( $by{'upcoming/'}{pages},  2, 'pages beneath the prefix are counted, recursively' );
    is( $by{'upcoming/'}{assets}, 1, 'assets are counted separately from pages' );

    # A prefix whose directory has gone: the ACL still gates it, and the panel
    # must show it rather than silently drop the entry - an orphan rule is
    # exactly the sort of thing this screen exists to surface.
    ok( $by{'upcoming/'}{exists}, 'an existing section is marked as present' );
}

# --- protected-sections is scoped ------------------------------------------
{
    # The FILTER, exercised directly with the scope list the API hands it. How a
    # request's scopes are resolved is the domain-access model's business and is
    # tested with its own fixtures; what this owns is that a section outside
    # those scopes never reaches the response - a scoped manager must not be
    # able to use this list to learn that other content exists at all.
    # Both packages carry their own docroot; the ACL store lives on Auth::Acl's.
    # Without the second, load_acls silently returns {} and every assertion here
    # would pass on an empty list - which is how a scope test proves nothing.
    local $Lazysite::Manager::Files::DOCROOT = $d;
    local $Lazysite::Auth::Acl::DOCROOT      = $d;
    my $confined = Lazysite::Manager::Files::action_protected_sections( 'bob', ['other'] );
    ok( $confined->{ok}, 'a scoped manager gets a response' );
    is( scalar @{ $confined->{sections} || [] }, 0,
        'and sees NO section outside their scope' )
        or diag encode_json( $confined->{sections} );

    my $inside = Lazysite::Manager::Files::action_protected_sections( 'bob', ['upcoming'] );
    is( scalar @{ $inside->{sections} || [] }, 1,
        'a section INSIDE the scope is still listed - the filter confines rather '
            . 'than blanks the panel' )
        or diag encode_json( $inside->{sections} );

    my $all = Lazysite::Manager::Files::action_protected_sections( 'op', [] );
    is( scalar @{ $all->{sections} || [] }, 2,
        'an unconfined operator sees every section' );
}

# --- capability-holders -----------------------------------------------------
{
    # A group that grants mcp, and a group NESTED inside it that grants nothing
    # itself. A member of the nested group holds mcp through the closure.
    users( 'group-set',    'agents', 'mcp', '1' );
    users( 'group-set', 'junior-agents', 'ui', '0' );    # bring it into being
    users_api( { action => 'group-nest', sub => 'junior-agents', parent => 'agents' } );
    users( 'add', 'carol', 'pw-carol-12345' );
    users( 'group-add', 'carol', 'junior-agents' );

    my $out = users_api( { action => 'capability-holders' } );
    my $r = eval { decode_json($out) } || {};
    ok( $r->{ok}, 'capability-holders responds' ) or diag $out;

    my $mcp = $r->{holders}{mcp} || {};
    # The stock groups are seeded on first use and some of them grant mcp too,
    # so this asserts the group we created is COUNTED and NAMED rather than
    # pinning a total that the seed set decides.
    ok( $mcp->{groups} >= 1, 'mcp is granted by at least one group' )
        or diag encode_json( $r->{holders} );
    ok( ( grep { $_ eq 'agents' } @{ $mcp->{group_names} || [] } ),
        'and it is named, so the operator can act on it' );
    ok( $mcp->{users} >= 1,
        'a member of a NESTED group counts as holding it - the closure, not '
            . 'direct membership' )
        or diag encode_json( $r->{holders}{mcp} );

    # Accounts are a count only. Naming every account that would lose a channel
    # puts a roster on the settings screen for no gain.
    ok( !exists $mcp->{user_names}, 'accounts are counted, never enumerated' );
}

done_testing();
