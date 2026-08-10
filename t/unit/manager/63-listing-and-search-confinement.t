#!/usr/bin/perl
# SM268 04-F4, 04-F5, 04-F6: three ways a partner reached past a boundary that
# the surface next door enforced.
#
# F5  action_list was the one file handler with no blocklist, and its character
#     strip PRESERVES `..`. A scoped partner spelled `..` through its own scope
#     prefix (the scope gates test the raw request string, so it passed and then
#     resolved elsewhere), and lazysite/auth was listable by any manage_content
#     grant. The listing is not merely names: every entry carries the ACL owner,
#     the read and write user lists and any live lock holder, so it is a
#     username roster keyed to files.
#
# F4  search_files excluded lazysite/ only while DESCENDING, so naming a base
#     inside the tree skipped the exclusion entirely, and the blocklist was
#     never consulted. It printed user-settings.json - a file read_file refuses -
#     a line at a time, as an unlimited-query oracle.
#
# F6  the delete_theme creator restriction read created_by from the theme's own
#     theme.json, which sits in the tree manage_themes makes writable. The
#     restriction was self-certified by the party it restricts.
#
# Every security assertion below was confirmed FAILING on the unfixed code.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_script);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/manager/locks",
    "$d/content/clientA", "$d/content/clientB",
    "$d/lazysite/layouts/base/themes/live" );

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }
sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t;
}

spit( "$d/lazysite/lazysite.conf", "site_name: T\nlayout: base\ntheme: live\nmcp_enabled: true\n" );
spit( "$d/lazysite/auth/user-settings.json",
    '{"partner-clienta":{"mcp":1,"dav_scope":"ROSTER-MARKER"}}' );
spit( "$d/lazysite/auth/acls.json",           '{}' );
spit( "$d/lazysite/nav.conf",                 "Home|/\n" );
spit( "$d/lazysite/layouts/base/layout.json", '{"name":"base","default_theme":"live"}' );
spit( "$d/lazysite/layouts/base/layout.tt",   '<html>[% content %]</html>' );
spit( "$d/lazysite/layouts/base/themes/live/theme.json", '{"name":"live","layouts":["base"]}' );
spit( "$d/content/clientA/ok.md",                        "A\n" );
spit( "$d/content/clientB/secret.md",                    "B\n" );

require Lazysite::Manager::Common;
require Lazysite::Manager::Files;
require Lazysite::Manager::Themes;
require Lazysite::Auth::Acl;
$Lazysite::Manager::Common::DOCROOT      = $d;
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/manager/locks";
$Lazysite::Auth::Acl::DOCROOT            = $d;
$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";

# --- F5 ---------------------------------------------------------------------

subtest 'action_list refuses the auth tree' => sub {
    my $r = Lazysite::Manager::Files::action_list('/lazysite/auth');
    ok( !$r->{ok}, 'refused' );
    my $names = join ',', map { $_->{name} } @{ $r->{entries} || [] };
    unlike( $names, qr/user-settings|acls/,
        'and no entry names came back with the refusal' );
};

subtest 'action_list resolves .. instead of listing through it' => sub {
    my $r = Lazysite::Manager::Files::action_list('/content/clientA/../clientB');
    ok( $r->{ok}, 'the directory is real, so the listing succeeds' );
    is( $r->{path}, '/content/clientB',
        'but it reports the CANONICAL path - confinement then has one string to '
            . 'test rather than one the caller chose the spelling of' );
};

subtest 'a listing does not advertise a blocklisted entry inside it' => sub {
    my $r = Lazysite::Manager::Files::action_list('/lazysite');
    ok( $r->{ok}, 'the lazysite root itself still lists' );
    my $names = join ',', map { $_->{name} } @{ $r->{entries} || [] };
    unlike( $names, qr/(^|,)auth(,|$)/, 'the auth directory is not offered' );
    like( $names, qr/layouts/,
        'the theme-authoring tree still is - a gate that hid everything would '
            . 'pass the two subtests above for the wrong reason' );
};

subtest 'ordinary content listing is unaffected' => sub {
    my $r = Lazysite::Manager::Files::action_list('/content/clientA');
    ok( $r->{ok}, 'listed' );
    like( join( ',', map { $_->{name} } @{ $r->{entries} || [] } ),
        qr/ok\.md/, 'with its files' );
};

# --- F4 ---------------------------------------------------------------------

subtest 'search_files does not enter the lazysite tree' => sub {
    my $stub = "$d/users-stub.pl";
    spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
    chmod 0755, $stub;

    my $call = sub {
        my ($args) = @_;
        my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
                params => { name => 'search_files', arguments => $args } } );
        my $out = run_script(
            'lazysite-mcp.pl',
            stdin => $body,
            env   => {
                DOCUMENT_ROOT       => $d,
                REQUEST_METHOD      => 'POST',
                CONTENT_LENGTH      => length($body),
                LAZYSITE_USERS_TOOL => $stub,
                HTTP_AUTHORIZATION  => 'Bearer partner:lzs_x',
            },
        );
        my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
        return defined $jb ? $jb : '';
    };

    my $inside = $call->( { query => 'dav_scope', path => 'lazysite/auth' } );
    unlike( $inside, qr/ROSTER-MARKER/,
        'naming a base INSIDE lazysite/ returns no line of the auth store - the '
            . 'descent-time check never applied to a base chosen there' );

    my $outside = $call->( { query => 'A', path => '/content' } );
    like( $outside, qr/clientA/,
        'content search still works, so the fix is a boundary and not an off '
            . 'switch' );
};

# --- F6 ---------------------------------------------------------------------

subtest 'the theme creator restriction is not self-certified' => sub {
    local $Lazysite::Manager::Themes::auth_user = 'admin';
    my $made = Lazysite::Manager::Themes::action_create_theme(
        { name => 'operator-theme', layout => 'base' } );
    ok( $made->{ok}, 'admin created a theme' ) or diag encode_json($made);

    my $tj = "$d/lazysite/layouts/base/themes/operator-theme/theme.json";
    ok( -f $tj, 'theme.json exists' );

    # Exactly what an agent holding manage_themes can do through write_file,
    # upload_file or WebDAV: rewrite the field the rule used to trust.
    my $meta = decode_json( slurp($tj) );
    $meta->{created_by} = 'attacker';
    spit( $tj, encode_json($meta) );

    my $del = Lazysite::Manager::Themes::action_theme_delete( 'operator-theme',
        { restrict_to_creator => 1, user => 'attacker' } );
    ok( !$del->{ok}, 'the forged claim is refused' ) or diag encode_json($del);
    is( $del->{kind}, 'not-yours', 'and refused as not the caller\'s theme' );
    ok( -d "$d/lazysite/layouts/base/themes/operator-theme",
        'the theme is still on disk - a refusal that still deleted would be '
            . 'the whole defect' );

    # And the real creator is still able to remove it, or this fix would have
    # recreated the litter problem SM262 existed to solve.
    my $ok = Lazysite::Manager::Themes::action_theme_delete( 'operator-theme',
        { restrict_to_creator => 1, user => 'admin' } );
    ok( $ok->{ok}, 'the account that created it may still delete it' )
        or diag encode_json($ok);
};

done_testing();
