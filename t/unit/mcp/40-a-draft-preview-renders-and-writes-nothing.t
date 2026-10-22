#!/usr/bin/perl
# SM1030 (ruled 2026-10-12 by the release manager, "yes queue the preview_page
# draft change"): MCP preview_page accepts DRAFT content and renders it
# server-side against the site's real layout and theme WITHOUT writing
# anything, so an MCP-connected editor can check a page before saving it.
#
# What this holds:
#   - a draft renders at its path with that site's layout and theme (the
#     primary's, and a domain's under the domain's own Host), new folders too;
#   - it writes nothing: every file under the site - the docroot, the private
#     store beside it, the engine tree with its caches, logs, form rules and
#     history - is the same before and after, byte for byte;
#   - the render is the public view: a gated draft shows the gate, not itself;
#   - a draft is refused for what a save of it would be refused for: bytes that
#     are not UTF-8, a form the caller does not reach, a template that does not
#     parse, the path's ACL write rule; and it is capped at 512 KiB;
#   - the caller's scope is enforced on the path.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use File::Find  ();
use Digest::SHA qw(sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use IPC::Open3  qw(open3);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper    qw(repo_root env_passthrough site_tempdir run_child);
use Lazysite::Git ();

my $root = repo_root();
my $d    = site_tempdir();
( my $site = $d ) =~ s{/[^/]+\z}{};    # the docroot's parent: docroot, store and all
my $logs = tempdir( CLEANUP => 1 );    # the MCP's stderr, outside what is compared

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $layout = '<html><head><title>[% page_title %]</title>'
    . '<meta name="theme-assets" content="[% theme_assets %]"></head>'
    . '<body><main>[% content %]</main></body></html>';
spit( "$d/lazysite/layouts/default/layout.tt", $layout );
spit( "$d/lazysite/layouts/default/layout.json", encode_json( { default_theme => 'day' } ) );
for my $t (qw(day night)) {
    spit( "$d/lazysite/layouts/default/themes/$t/theme.json",
        encode_json( { name => $t, version => '1.0', layouts => ['default'] } ) );
}
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nmcp_enabled: true\ngit_history: enabled\nlayout: default\ntheme: day\n"
        . "alias_hosts: mine.test\nalias.mine.test.content_root: sites/mine\n"
        . "alias.mine.test.theme: night\n" );
spit( "$d/index.md",            "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/404.md",              "---\ntitle: NF\n---\nNot found.\n" );
spit( "$d/about.md",            "---\ntitle: About\n---\nThe SAVED about page.\n" );
spit( "$d/sites/mine/index.md", "---\ntitle: Mine\n---\nMine.\n" );
spit( "$d/members/index.md",    "---\ntitle: Members\n---\nMembers.\n" );
spit( "$d/locked/index.md",     "---\ntitle: Locked\n---\nLocked.\n" );
spit( "$d/sites/mine/contact.md",
    "---\ntitle: C\nform: mine_form\n---\n\n:::form\nname | Name\n:::\n" );
spit( "$d/contact.md", "---\ntitle: C\nform: prim_form\n---\n\n:::form\nname | Name\n:::\n" );
spit( "$d/lazysite/forms/$_.conf", "targets:\n" ) for qw(mine_form prim_form);
spit( "$d/lazysite/auth/acls.json",
    encode_json( { members => { read => ['@staff'] }, locked => { write => ['@editors'] } } ) );

# Two grants: `op` reaches the whole site, `scoped` only sites/mine.
spit( "$d/users-stub.pl", <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
my %s  = ( mcp => 1, manage_content => 1, manage_forms => 1 );
$s{dav_scopes} = ['sites/mine'] if ( $r->{username} // '' ) eq 'scoped';
print encode_json( { ok => 1, settings => \%s } );
STUB
chmod 0755, "$d/users-stub.pl";

my $git = Lazysite::Git::git_available();
Lazysite::Git::init( $d, 'operator' )->{ok} or die 'history init failed' if $git;

# One tools/call over the CGI, as a client sends it. $raw is the request body
# as bytes, for a body no encoder would write; otherwise it is encoded here.
sub mcp {
    my ( $user, $tool, $args, $raw ) = @_;
    my $body = $raw // encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(),
        PATH                         => $ENV{PATH},
        DOCUMENT_ROOT                => $d,
        REQUEST_METHOD               => 'POST',
        CONTENT_LENGTH               => length $body,
        LAZYSITE_USERS_TOOL          => "$d/users-stub.pl",
        LAZYSITE_FORWARD_DIAGNOSTICS => 'off',
        HTTP_AUTHORIZATION           => "Bearer $user:lzs_tok",
    );
    open my $e, '>>', "$logs/stderr.log" or die $!;
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => $e )->{out};
    close $e;
    my ($jb) = ( $resp // '' ) =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) };
    return { ok => 0, error => 'NO JSON-RPC BODY' } unless ref $j eq 'HASH';
    return { ok => 0, rpc_code => $j->{error}{code}, error => "JSON-RPC error: $j->{error}{message}" }
        if $j->{error};
    return $j->{result}{structuredContent} || {};
}

sub draft { my ( $user, $path, $content ) = @_; return mcp( $user, preview_page => { path => $path, content => $content } ) }

# Every file under the site, by content and mode, and every directory. Access
# times are left out: reading is not writing.
sub snapshot {
    my %s;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                ( my $rel = $p ) =~ s{\A\Q$site\E/?}{};
                if ( -l $p ) { $s{$rel} = 'link:' . readlink $p; return }
                if ( -d $p ) { $s{$rel} = 'dir';                 return }
                open my $fh, '<:raw', $p or do { $s{$rel} = "unreadable"; return };
                my $c = do { local $/; <$fh> };
                close $fh;
                my @st = stat $p;
                $s{$rel} = sprintf '%o:%d:%d:%s', $st[2], $st[7], $st[9], sha256_hex($c);
            },
        },
        $site
    );
    return \%s;
}

sub changes {
    my ( $a, $b ) = @_;
    my %k = map { $_ => 1 } keys %$a, keys %$b;
    return [ map {
            !exists $a->{$_}       ? "added $_"
                : !exists $b->{$_} ? "removed $_"
                : "changed $_"
    } grep { ( $a->{$_} // '' ) ne ( $b->{$_} // '' ) } sort keys %k ];
}

sub theme_of { my ($html) = @_; my ($t) = ( $html // '' ) =~ m{name="theme-assets" content="/lazysite-assets/default/([^"]+)"}; return $t // '(none)' }

# A COLD site: nothing has rendered, so every cache, compile cache, log, secret
# and registry a first render would create is still to be created - the
# strongest place to show a draft creates none of them. The live form's derived
# rules are put here as a render of the saved page would have left them.
spit( "$d/lazysite/forms/prim_form.rules",
    encode_json( { form => 'prim_form', version => 1, fields => [ { name => 'name' } ] } ) );

my $before = snapshot();
my %r;

subtest 'a draft renders at its path with the site\'s layout and theme' => sub {
    my $r = $r{about} = draft( op => '/about', "---\ntitle: Draft Title\n---\nThe DRAFT-MARKER body.\n" );
    ok( $r->{ok},    'ok' ) or diag explain $r;
    ok( $r->{draft}, 'says it rendered a draft' );
    is( $r->{status}, 200, 'status 200' );
    like( $r->{html}, qr/DRAFT-MARKER/, 'the draft\'s body is rendered' );
    unlike( $r->{html}, qr/SAVED about/, 'not the saved page' );
    like( $r->{html}, qr{<title>Draft Title</title>}, 'through the layout, with the draft\'s title' );
    is( theme_of( $r->{html} ), 'day',       'in the primary site\'s theme' );
    is( $r->{path},             '/about.md', 'names the page it rendered' );
};

subtest 'a draft on a domain renders under that domain\'s Host and theme' => sub {
    my $r = draft( scoped => '/sites/mine/new-page', "---\ntitle: New\n---\nNEW-PAGE-MARKER\n" );
    ok( $r->{ok}, 'a page that does not exist yet' ) or diag explain $r;
    like( $r->{html}, qr/NEW-PAGE-MARKER/, 'renders' );
    is( theme_of( $r->{html} ), 'night',     'in the domain\'s own theme' );
    is( $r->{rendered_as_host}, 'mine.test', 'and says which Host' );

    my $deep = draft( scoped => '/sites/mine/newdir/deeper/page', "---\ntitle: D\n---\nDEEP-MARKER\n" );
    ok( $deep->{ok}, 'a page in folders that do not exist yet' ) or diag explain $deep;
    like( $deep->{html} // '', qr/DEEP-MARKER/, 'renders too' );

    my $ix = draft( op => '/sites/mine/', "---\ntitle: Ix\n---\nINDEX-MARKER\n" );
    like( $ix->{html} // '', qr/INDEX-MARKER/, 'a folder path previews its index page' );
    is( $ix->{path}, '/sites/mine/index.md', 'named as the index page' );
};

subtest 'a draft with a form, a scan and nocache renders too' => sub {
    my $r = draft( op => '/contact',
        "---\ntitle: C\nform: prim_form\nnocache: true\n---\n\n:::form\nname | Name\nemail | Email | required email\n:::\n" );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    like( $r->{html} // '', qr/<form\b/,      'the form renders' );
    like( $r->{html} // '', qr/name="email"/, 'with the draft\'s new field' );
};

subtest 'the render is the public view: a gated draft shows the gate' => sub {
    my $r = draft( op => '/members/secret', "---\ntitle: S\n---\nGATED-MARKER\n" );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    isnt( $r->{status}, 200, "not served (status $r->{status})" );
    unlike( $r->{html} // '', qr/GATED-MARKER/, 'the draft is not shown' );

    my $a = draft( op => '/about', "---\ntitle: S\nauth: required\n---\nAUTH-MARKER\n" );
    isnt( $a->{status}, 200, "a draft that asks for sign-in is gated (status $a->{status})" );
    unlike( $a->{html} // '', qr/AUTH-MARKER/, 'and not shown' );
};

subtest 'NOTHING IS WRITTEN' => sub {
    my $after = snapshot();
    is_deeply( changes( $before, $after ), [], 'every file under the site is as it was' );
    ok( scalar( keys %$before ) > 20, 'and the comparison saw the site (' . scalar( keys %$before ) . ' entries)' );
    ok( ( grep { m{/lazysite/(?:layouts|forms|auth)/} } keys %$before ), 'including the engine tree' );
    my $rules = "$d/lazysite/forms/prim_form.rules";
    ok( -f $rules, 'the live form keeps its derived rules' );
    open my $rf, '<', $rules or die "$rules: $!";
    my $rt = do { local $/; <$rf> };
    close $rf;
    unlike( $rt, qr/email/, 'and they do not carry the field only the draft has' );
};

subtest 'refused for what a save would refuse' => sub {
    # Bytes that are not UTF-8 can reach the wire: a JSON encoder writes a lone
    # surrogate as its three bytes, and the server's decoder accepts them.
    my $raw = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'preview_page',
                arguments => { path => '/about', content => "---\ntitle: X\n---\nbad " . chr(0xD800) . "\n" } } } );
    my $r = mcp( op => undef, undef, $raw );
    is( $r->{kind}, 'page-encoding-refused', 'not UTF-8: refused' ) or diag explain $r;
    like( $r->{error} // '', qr/first invalid byte is at offset 21\b/, 'naming the offset' );

    my $f = draft( scoped => '/sites/mine/hook', "---\ntitle: H\nform: prim_form\n---\n\n:::form\nname | Name\n:::\n" );
    is( $f->{kind}, 'form-bind-refused', 'a form the caller does not reach: refused' ) or diag explain $f;

    my $own = draft( scoped => '/sites/mine/hook', "---\ntitle: H\nform: mine_form\n---\n\n:::form\nname | Name\n:::\n" );
    ok( $own->{ok}, 'its own form renders' ) or diag explain $own;

    my $t = draft( op => '/about', "---\ntitle: T\n---\n[% IF %]\n" );
    is( $t->{kind}, 'template-parse-refused', 'a template that does not parse: refused' ) or diag explain $t;

    my $w = draft( op => '/locked/x', "---\ntitle: L\n---\nLOCKED\n" );
    is( $w->{kind}, 'permission', 'a path its ACL will not let the caller write: refused' ) or diag explain $w;

    my $big = draft( op => '/about', "---\ntitle: B\n---\n" . ( 'x' x ( 512 * 1024 ) ) );
    is( $big->{kind}, 'too-large', 'over 512 KiB: refused' ) or diag explain $big;

    my $lz = draft( op => '/lazysite/lazysite.conf', "x: y\n" );
    is( $lz->{kind}, 'blocked', 'a draft in the engine tree: refused' ) or diag explain $lz;
};

subtest 'the scope is enforced on the path' => sub {
    my $r = draft( scoped => '/about', "---\ntitle: S\n---\nOUT-OF-SCOPE\n" );
    is( $r->{rpc_code}, -32002, 'outside the grant\'s scope: refused' ) or diag explain $r;
    unlike( $r->{html} // '', qr/OUT-OF-SCOPE/, 'nothing rendered' );
};

# SM943: a read is not audited unless it fails - so the seven refusals above
# are the only rows, and nothing else changed.
subtest 'the refusals wrote nothing but their audit rows' => sub {
    my $audit = 'public_html/lazysite/logs/audit.log';
    ( my $logs_dir = $audit ) =~ s{/[^/]+\z}{};
    is_deeply( changes( $before, snapshot() ), [ "added $logs_dir", "added $audit" ],
        'only the audit trail changed' );
    open my $fh, '<', "$site/$audit" or die "$audit: $!";
    my @rows = grep { /\S/ } <$fh>;
    close $fh;
    is( scalar @rows, 7, 'one row per refusal' ) or diag @rows;
    is( scalar( grep { /preview_page/ && /\bfail\b/ } @rows ), scalar @rows, 'each a failed preview_page' )
        or diag @rows;
};

# Last, because it is not a draft: the saved-page preview renders as a visit and
# records one, as it did before SM1030.
subtest 'the saved-page preview is unchanged' => sub {
    my $r = mcp( op => preview_page => { path => '/about' } );
    ok( $r->{ok}, 'ok' );
    like( $r->{html} // '', qr/SAVED about/, 'renders the saved page' );
    ok( !$r->{draft}, 'and does not call it a draft' );
};

done_testing;
