#!/usr/bin/perl
# SM1046 (ruled 2026-10-12, "Allow, own group only"): a manage_domains token
# with no scope may create a domain when it names one of its own groups as the
# domain's allowed_groups.
#
# Reported from sites.lazysite.io (0.15.4): a partner token holding
# manage_domains sent domain-add for tprf-news and was refused, because a token
# with no scope reaches no domain (SM975) and the only way to give it one was a
# domain naming its group - the domain it had been asked to create. The grant
# could not be used for the action it is named after.
#
# THE RULING, as asserted here:
#   - naming a group the account is in: the domain is created, and from then on
#     the account reaches that domain through the group and no other;
#   - naming a group it is not in: refused, nothing written;
#   - naming none: refused, with a message saying to name one;
#   - a content root inside (or containing) another domain's root: refused;
#   - audited with the caller, the host and the group.
# The scoped token's SM976 check, the operator, and SM975 for every other
# domain write are unchanged; t/integration/111 and 112 hold those.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui manage_domains manage_users manage_config manage_content);
my $s   = new_site( root => $root );    # site_tempdir() underneath
my $d   = $s->docroot;
make_path( "$d/sites/other", "$d/sites/existing" );
{
    open my $fh, '>', "$d/sites/other/index.md" or die $!;
    print {$fh} "# other\n";
    close $fh;
}

# The operator, and one domain that is not the partner's.
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui manage_domains manage_users manage_config manage_content)], \@ALL );
sub boss { my ( $a, $b ) = @_; return $s->call( 'boss', $a, body => $b ) }
ok( boss( 'domain-add', { host => 'other.example.org', content_root => 'sites/other',
            site_url => 'https://other.example.org', site_name => 'Other' } )->{ok},
    'the operator adds other.example.org' );

# The partner: a token account in `partners`, holding manage_domains, named on
# no domain - so its scope is empty. `strangers` is a group it is not in.
sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %auth;
for my $u (qw(partner)) {
    $s->add_user($u);
    $s->grant( $u, 'partners', [qw(api manage_domains manage_content)], \@ALL );
    my $t = uapi( { action => 'token', username => $u } )->{token} // '';
    ok( length $t, "a manage_domains token for '$u'" );
    $auth{$u} = 'Basic ' . encode_base64( "$u:$t", '' );
}
$s->add_user('carol');
$s->users( 'group-add', 'carol', 'strangers' );

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
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; return <$fh> }

sub audit_lines {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    my @l = grep { /domain-add/ } <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

my %NEW = ( host => 'tprf-news.example.org', content_root => 'sites/tprf-news',
    site_url => 'https://tprf-news.example.org', site_name => 'The Perl Foundation News', seed => 0 );

subtest 'naming no group: refused, and told to name one' => sub {
    my $r = tok( 'partner', 'domain-add', {%NEW} );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind} // '', 'forbidden', '...as forbidden' );
    like( $r->{error} // '', qr/names no dav_scope, so it reaches no domain/, '...naming the missing scope' );
    like( $r->{error} // '', qr/name one of your own groups in the request's allowed_groups/,
        '...and saying to name one of its own groups' );
    like( $r->{error} // '', qr/Your groups: partners\./, '...listing the groups it may name' );
    unlike( conf(), qr/tprf-news/, 'nothing was written' );
};

subtest 'naming a group the account is not in: refused' => sub {
    for my $g ( 'strangers', ['@strangers'], 'partners, strangers' ) {
        my $r = tok( 'partner', 'domain-add', { %NEW, allowed_groups => $g } );
        ok( !$r->{ok}, 'refused: ' . ( ref $g ? "[@$g]" : $g ) );
        is( $r->{kind}    // '', 'forbidden', '...as forbidden' );
        like( $r->{error} // '', qr/it is not in \@strangers\. Your groups: \@partners\./,
            '...naming the group and the ones it may name' );
    }
    unlike( conf(), qr/tprf-news/, 'nothing was written' );
};

subtest "a content root that is another domain's: refused" => sub {
    for my $cr (qw(sites/other sites/other/news sites)) {
        my $r = tok( 'partner', 'domain-add', { %NEW, content_root => $cr, allowed_groups => 'partners' } );
        ok( !$r->{ok}, "refused: $cr" );
        is( $r->{kind} // '', 'forbidden', '...as forbidden' );
        like( $r->{error} // '', qr/overlaps 'sites\/other', which the domain 'other\.example\.org' serves/,
            '...naming the domain it overlaps' );
    }
    my $r = tok( 'partner', 'domain-add', { %NEW, content_root => 'sites/existing', allowed_groups => 'partners' } );
    ok( !$r->{ok}, 'refused: a folder that already exists' );
    like( $r->{error} // '', qr/'sites\/existing' already exists/, '...saying so' );
    my $bad = tok( 'partner', 'domain-add', { %NEW, content_root => 'lazysite/x', allowed_groups => 'partners' } );
    ok( !$bad->{ok}, 'refused: a reserved area, as domain_add always refused it' );
    unlike( conf(), qr/tprf-news/, 'nothing was written' );
};

subtest 'the reported case: naming its own group creates the domain' => sub {
    my $before = scalar audit_lines();
    my $r      = tok( 'partner', 'domain-add', { %NEW, allowed_groups => '@partners' } );
    ok( $r->{ok}, 'created' ) or diag explain $r;
    like( conf(), qr/^alias\.tprf-news\.example\.org\.allowed_groups:\s*partners\s*$/m,
        'the domain names the group' );
    ok( -d "$d/sites/tprf-news", 'and its content root exists' );

    my @l = audit_lines();
    is( scalar @l, $before + 1, 'one audit row' );
    like( $l[-1] // '', qr/\bpartner\b/,             'naming the caller' );
    like( $l[-1] // '', qr/tprf-news\.example\.org/, 'the host' );
    like( $l[-1] // '', qr/allowed_groups=partners/, 'and the group' );
    like( $l[-1] // '', qr/\bok\b/,                  'as a success' );
};

subtest 'afterwards it reaches that domain and no other' => sub {
    my $list = tok( 'partner', 'domains-list' );
    is_deeply( [ map { $_->{host} } @{ $list->{domains} || [] } ],
        ['tprf-news.example.org'], 'domains-list shows the new domain alone' );
    ok( tok( 'partner', 'domain-set', { host => 'tprf-news.example.org', key => 'site_name', value => 'TPRF News' } )->{ok},
        'it sets a key on the new domain' );
    my $other = tok( 'partner', 'domain-set', { host => 'other.example.org', key => 'site_name', value => 'Taken' } );
    ok( !$other->{ok}, 'and is refused on the other domain' );
    unlike( conf(), qr/Taken/, '...which is unchanged' );
    ok( !tok( 'partner', 'domain-remove', { host => 'other.example.org' } )->{ok},
        'it cannot remove the other domain' );
    my $second = tok( 'partner', 'domain-add', { host => 'second.example.org',
            content_root => 'sites/second', allowed_groups => 'partners' } );
    ok( !$second->{ok}, 'a second domain outside its scope is refused (it is scoped now: SM976)' );
    like( $second->{error} // '', qr/cannot reach the content root 'sites\/second'/, '...by the scope rule' );
};

subtest 'the operator can still remove or reassign it' => sub {
    ok( boss( 'domain-set', { host => 'tprf-news.example.org', key => 'allowed_groups', value => 'bosses' } )->{ok},
        'the operator reassigns it' );
    my $list = tok( 'partner', 'domains-list' );
    ok( !( grep { $_->{host} eq 'tprf-news.example.org' } @{ $list->{domains} || [] } ),
        'and the partner no longer reaches it' );
    ok( boss( 'domain-remove', { host => 'tprf-news.example.org' } )->{ok}, 'the operator removes it' );
};

subtest 'a signed-in session does not take allowed_groups on domain-add' => sub {
    my $r = boss( 'domain-add', { host => 'cookie.example.org', content_root => 'sites/cookie',
            allowed_groups => 'bosses' } );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/domain-set/, '...pointing at domain-set' );
    unlike( conf(), qr/cookie\.example\.org/, 'nothing was written' );
};

done_testing;
