#!/usr/bin/perl
# SM975: a token reaches only the domains its scope names, and a token naming
# no scope reaches none (ruled 2026-10-09).
#
# A manage_domains token that nobody had scoped wrote every domain on the
# instance: domain-set, remap-save and site-backup-apply read its empty scope as
# unconfined, and domain-add, domain-alias-add and domain-remove did not ask.
# remap-save also took a host the instance does not serve. The probe was
# tmp/sm944-s22-token-scope-probe.pl; this file is that probe as assertions,
# for every domain write it found, on the control API and on MCP.
#
# WHAT STAYS. A token scoped to one domain still writes that domain and is
# refused outside it; the operator's cookie session, which names no scope, still
# writes every domain. A check that refused everyone would pass the unscoped
# half and break domain management, so the other two are asserted too.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui manage_domains manage_users manage_config manage_content);
my $s   = new_site( root => $root );
my $d   = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other" );
for my $x (qw(mine other)) {
    open my $fh, '>', "$d/sites/$x/index.md" or die $!;
    print {$fh} "# $x\n";
    close $fh;
}
{
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "extensions:\n  - plugins/remap.pl\n";
    close $cf;
}

# The operator: a cookie session holding manage_users, so unconfined.
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui manage_domains manage_users manage_config manage_content)], \@ALL );
sub boss { my ( $a, $b ) = @_; return $s->call( 'boss', $a, body => $b ) }

for my $x ( [ 'mine.example.org', 'sites/mine' ], [ 'other.example.org', 'sites/other' ] ) {
    my $r = boss( 'domain-add', { host => $x->[0], content_root => $x->[1],
            site_url => "https://$x->[0]", site_name => $x->[0] } );
    ok( $r->{ok}, "set up $x->[0]" ) or diag( $r->{error} // '' );
}
my $rule = [ { prefix => '/web', destination => 'https://backend.example.com' } ];
ok( boss( 'remap-save', { host => 'other.example.org', rules => $rule } )->{ok},
    'the operator sets a rule on other.example.org' );
my $pkg = boss( 'site-backup-create', { host => 'mine.example.org' } )->{name} // '';
like( $pkg, qr/^lazysite-site-mine\.example\.org-/, 'the operator packages mine.example.org' );

# Two token accounts holding the same capabilities. 'scoped' is confined to
# sites/mine by naming its group in that domain's allowed_groups - the way an
# operator gives a token a scope, and the way the refusal tells them to.
sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %auth;
for my $u (qw(unscoped scoped)) {
    $s->add_user($u);
    $s->grant( $u, "tok-$u", [qw(api manage_domains manage_content)], \@ALL );
    my $t = uapi( { action => 'token', username => $u } )->{token} // '';
    ok( length $t, "a manage_domains token for '$u'" );
    $auth{$u} = 'Basic ' . encode_base64( "$u:$t", '' );
}
ok( boss( 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'tok-scoped' } )->{ok},
    'the operator scopes tok-scoped to mine.example.org' );

# A control-API call as a token client.
sub tok {
    my ( $who, $action, $body ) = @_;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN)};
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl";
    $ENV{HTTP_AUTHORIZATION}  = $auth{$who};
    $ENV{QUERY_STRING}        = "action=$action";
    $ENV{REQUEST_METHOD}      = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}      = defined $json ? length $json : 0;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ],
        stdin => ( $json // '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; return <$fh> }
my $NO_SCOPE = qr/names no dav_scope, so it reaches no domain.*allowed_groups/;

# --- an unscoped token: refused on every domain write ------------------------
subtest 'an unscoped token writes no domain' => sub {
    my @writes = (
        [ 'domain-set on a served domain', 'domain-set',
            { host => 'mine.example.org', key => 'site_name', value => 'Taken' } ],
        [ 'remap-save on a served domain', 'remap-save', { host => 'mine.example.org', rules => $rule } ],
        [ 'remap-save on a host the instance does not serve', 'remap-save',
            { host => 'unserved.example.net', rules => $rule } ],
        [ 'domain-add', 'domain-add', { host => 'new.example.org', content_root => 'sites/new' } ],
        [ 'domain-alias-add', 'domain-alias-add', { host => 'al.example.org', alias_of => 'other.example.org' } ],
        [ 'domain-remove', 'domain-remove', { host => 'other.example.org' } ],
        [ 'site-backup-apply to a domain', 'site-backup-apply', { name => $pkg, host => 'other.example.org' } ],
        [ 'site-backup-apply to the default site', 'site-backup-apply', { name => $pkg } ],
    );
    for my $w (@writes) {
        my $r = tok( 'unscoped', $w->[1], $w->[2] );
        ok( !$r->{ok}, "refused: $w->[0]" );
        is( $r->{kind} // '', 'forbidden', '...as forbidden' );
        like( $r->{error} // '', $NO_SCOPE, '...naming the missing scope and how to give one' );
    }
    my $c = conf();
    unlike( $c, qr/Taken/,             'the site name was not written' );
    unlike( $c, qr/new\.example\.org/, 'no domain was added' );
    unlike( $c, qr/al\.example\.org/,  'no alias was added' );
    like( $c, qr/other\.example\.org/, 'other.example.org is still served' );
    my @ruled = map { $_->{host} } @{ $s->call( 'boss', 'remap-list' )->{rules} || [] };
    is_deeply( \@ruled, ['other.example.org'], 'no remap rule was written for either host' );

    my $l = tok( 'unscoped', 'remap-list' );
    ok( $l->{ok}, 'remap-list still answers' );
    is( scalar @{ $l->{rules} || [] }, 0, '...with no domain\'s rules' );
};

# --- a scoped token: its domain, and nothing outside it ----------------------
subtest 'a scoped token writes its own domain only' => sub {
    my $in = tok( 'scoped', 'domain-set', { host => 'mine.example.org', key => 'site_name', value => 'Mine' } );
    ok( $in->{ok}, 'domain-set on its own domain' ) or diag( $in->{error} // '' );
    my $rin = tok( 'scoped', 'remap-save', { host => 'mine.example.org', rules => $rule } );
    ok( $rin->{ok}, 'remap-save on its own domain' ) or diag( $rin->{error} // '' );
    my $ap = tok( 'scoped', 'site-backup-apply', { name => $pkg, host => 'mine.example.org' } );
    ok( $ap->{ok}, 'site-backup-apply to its own domain' ) or diag( $ap->{error} // '' );

    for my $w (
        [ 'domain-set outside', 'domain-set', { host => 'other.example.org', key => 'site_name', value => 'X' } ],
        [ 'remap-save outside', 'remap-save', { host => 'other.example.org', rules => [] } ],
        [ 'remap-save unserved', 'remap-save', { host => 'unserved.example.net', rules => $rule } ],
        [ 'site-backup-apply outside', 'site-backup-apply', { name => $pkg, host => 'other.example.org' } ],
        )
    {
        my $r = tok( 'scoped', $w->[1], $w->[2] );
        ok( !$r->{ok}, "refused: $w->[0]" );
        is( $r->{kind}      // '', 'forbidden', '...as forbidden' );
        unlike( $r->{error} // '', $NO_SCOPE, '...for its scope, not for having none' );
    }
    my @hosts = map { $_->{host} } @{ tok( 'scoped', 'remap-list' )->{rules} || [] };
    is_deeply( \@hosts, ['mine.example.org'], 'remap-list shows its own domain\'s rules only' );
};

# --- the operator: unaffected ------------------------------------------------
subtest 'the operator still writes every domain' => sub {
    ok( boss( 'domain-set', { host => 'other.example.org', key => 'site_name', value => 'Op' } )->{ok}, 'domain-set' );
    ok( boss( 'remap-save', { host => 'unserved.example.net', rules => $rule } )->{ok}, 'remap-save, any host' );
    ok( boss( 'domain-alias-add', { host => 'al.example.org', alias_of => 'other.example.org' } )->{ok}, 'domain-alias-add' );
    ok( boss( 'domain-remove', { host => 'al.example.org' } )->{ok}, 'domain-remove' );
    my $a = boss( 'domain-add', { host => 'new.example.org', content_root => 'sites/new' } );
    ok( $a->{ok}, 'domain-add' ) or diag( $a->{error} // '' );
    my $ap = boss( 'site-backup-apply', { name => $pkg, host => 'other.example.org' } );
    ok( $ap->{ok}, 'site-backup-apply' ) or diag( $ap->{error} // '' );
};

# --- MCP: domain_set ---------------------------------------------------------
# MCP has no cookie session, so every caller is a token. site_backup and
# site_apply already refused an unscoped grant (SM578); domain_set did not ask.
subtest 'MCP domain_set: an unscoped grant reaches no domain' => sub {
    my $stub = "$d/users-stub.pl";
    open my $sf, '>', $stub or die $!;
    print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $r = eval { decode_json( do { local $/; <STDIN> } ) } || {};
my %caps = ( mcp => 1, manage_content => 1, manage_domains => 1 );
$caps{dav_scopes} = ['sites/mine'] if ( $r->{username} // '' ) eq 'inscope';
print encode_json( { ok => 1, settings => \%caps } );
STUB
    close $sf;
    chmod 0755, $stub;
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "mcp_enabled: true\n";
    close $cf;

    my $mcp = sub {
        my ( $who, $args ) = @_;
        my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
                params => { name => 'domain_set', arguments => $args } } );
        local %ENV = %ENV;
        delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
        $ENV{DOCUMENT_ROOT}       = $d;
        $ENV{REQUEST_METHOD}      = 'POST';
        $ENV{CONTENT_LENGTH}      = length $body;
        $ENV{LAZYSITE_USERS_TOOL} = $stub;
        $ENV{HTTP_AUTHORIZATION}  = "Bearer $who:lzs_tok";
        my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
            stdin => $body, stderr => 'inherit' )->{out};
        my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
        my $j    = eval { decode_json( $jb // '' ) } || {};
        return $j->{result}{structuredContent} || { error => encode_json($j) };
    };
    my $un = $mcp->( 'unscoped', { host => 'mine.example.org', key => 'site_name', value => 'ViaMcp' } );
    ok( !$un->{ok}, 'refused' );
    like( $un->{error} // '', $NO_SCOPE, '...naming the missing scope' );
    unlike( conf(), qr/ViaMcp/, '...and nothing was written' );

    my $in = $mcp->( 'inscope', { host => 'mine.example.org', key => 'site_name', value => 'McpMine' } );
    ok( $in->{ok}, 'a scoped grant still sets its own domain' ) or diag( $in->{error} // '' );
};

done_testing();
