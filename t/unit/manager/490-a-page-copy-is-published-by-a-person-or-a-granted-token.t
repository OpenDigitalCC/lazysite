#!/usr/bin/perl
# SM1354 (ruling 155): THE CONTROL API AND THE MANAGER DOORS OF A PAGE'S COPY, AND
# THE publish_copies GATE.
#
# A person in the manager holding manage_content copies a page, saves the copy in
# the editor, sees it through the manager's preview, lists it, and publishes it as
# they save today - recorded as from a person. A control-API token holding
# manage_content copies and discards, and is refused the publish until it holds
# publish_copies too - recorded as from an agent. publish_copies is held by no
# shipped role: a manager group is seeded without it and offered it.
#
# With the change reverted the actions are unknown, publish_copies is no
# capability, and each subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);
use Lazysite::Git  ();

plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

my $root = repo_root();
my $mapi = "$root/lazysite-manager-api.pl";

sub put {
    my ( $d, $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub slurp { open my $f, '<', "$_[0]/$_[1]" or return undef; local $/; my $t = <$f>; close $f; $t }
sub subjects {
    my ( $d, $rel ) = @_;
    my ( undef, $out ) = Lazysite::Git::run_git( $d, 'log', '--format=%s', '--', $rel );
    return [ grep { length } split /\n/, ( $out // '' ) ];
}

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\ngit_history: enabled\nmanager_groups: admins\n" );
my $d = $s->docroot;
put( $d, 'page.md', "---\ntitle: P\n---\n\nversion ONE\n" );
Lazysite::Git::reset_cache();
ok( Lazysite::Git::init( $d, 'test' )->{ok}, 'content history initialised' );

my @ALL = qw(ui api manage_content publish_copies);
$s->add_user('boss');
$s->grant( 'boss', 'admins', [qw(ui manage_users)], [] );
$s->add_user('editor');
$s->grant( 'editor', 'eds', [qw(ui manage_content)], \@ALL );
$s->add_user('bot');
$s->grant( 'bot', 'bots', [qw(api manage_content)], \@ALL );
my $tok = do {
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'token', username => 'bot' } ), stderr => 'inherit' )->{out};
    ( eval { decode_json($out) } || {} )->{token};
};
ok( $tok, 'the token client has a token' );

sub api {
    my ( $method, $qs, $body ) = @_;
    my $json = defined $body ? encode_json($body) : '';
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = $method;
    $ENV{QUERY_STRING}       = $qs;
    $ENV{CONTENT_LENGTH}     = length $json;
    $ENV{CONTENT_TYPE}       = 'application/json';
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . MIME::Base64::encode_base64( "bot:$tok", '' );
    my $out = run_child( [ $^X, $mapi ], stdin => $json, stderr => 'inherit' )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

subtest 'a manager group is seeded without publish_copies and offered it' => sub {
    $s->users('list');
    my $gs = decode_json( slurp( $d, 'lazysite/auth/groups-settings.json' ) );
    ok( $gs->{admins}{manager}, 'admins is a manager group' ) or diag explain $gs->{admins};
    ok( $gs->{admins}{manage_content}, 'it holds manage_content' );
    ok( !$gs->{admins}{publish_copies}, 'and not publish_copies' );
    ok( ( grep { $_ eq 'publish_copies' } @{ $gs->{admins}{grantable} || [] } ), 'which it may grant' );
};

subtest 'a person copies, changes, previews, lists and publishes' => sub {
    my $c = $s->call( 'editor', 'page-copy', query => 'action=page-copy&path=/page.md', body => {} );
    ok( $c->{ok}, 'page-copy' ) or diag explain $c;
    my $copy = $c->{copy};
    my $w = $s->call( 'editor', 'save', query => "action=save&path=/$copy",
        body => { content => "---\ntitle: P\n---\n\nversion TWO\n" } );
    ok( $w->{ok}, 'the copy is saved in the editor' ) or diag explain $w;
    like( slurp( $d, 'page.md' ), qr/version ONE/, 'the page is unchanged' );
    my $p = $s->call( 'editor', 'preview', query => "action=preview&path=/$copy" );
    ok( $p->{ok}, 'the manager previews the copy' ) or diag explain $p;
    like( $p->{html} // '', qr/version TWO/, '...with its text' );
    my $l = $s->call( 'editor', 'page-copies', query => 'action=page-copies' );
    is( scalar @{ $l->{copies} || [] }, 1, 'page-copies lists it' ) or diag explain $l;
    is_deeply( $l->{copies}[0]{changed_by}, ['editor'], '...naming who changed it' );
    my $pub = $s->call( 'editor', 'page-copy-publish', query => 'action=page-copy-publish&path=/page.md', body => {} );
    ok( $pub->{ok}, 'a person publishes with manage_content' ) or diag explain $pub;
    like( slurp( $d, 'page.md' ), qr/version TWO/, 'the page carries the copy' );
    like( subjects( $d, 'page.md' )->[0], qr/by editor \(person\)/, 'recorded as a person\'s publish' );
};

subtest 'a token copies and discards, and publishes only with publish_copies' => sub {
    my $c = api( 'POST', 'action=page-copy&path=/page.md', {} );
    ok( $c->{ok}, 'page-copy' ) or diag explain $c;
    my $no = api( 'POST', 'action=page-copy-publish&path=/page.md', {} );
    ok( !$no->{ok}, 'publish refused without publish_copies' );
    like( $no->{error} // '', qr/publish_copies/, '...naming it' );
    like( slurp( $d, 'page.md' ), qr/version TWO/, 'the page is unchanged' );
    my $x = api( 'POST', 'action=page-copy-discard&path=/page.md', {} );
    ok( $x->{ok}, 'page-copy-discard' ) or diag explain $x;
    ok( !-e "$d/lazysite/copies/pages/page.md", 'the copy is gone' );

    $s->grant( 'bot', 'bots', [qw(api manage_content publish_copies)], \@ALL );
    my $c2 = api( 'POST', 'action=page-copy&path=/page.md', {} );
    ok( $c2->{ok}, 'a fresh copy' );
    ok( $s->call( 'editor', 'save', query => "action=save&path=/$c2->{copy}",
            body => { content => "---\ntitle: P\n---\n\nversion THREE\n" } )->{ok}, 'changed' );
    my $pub = api( 'POST', 'action=page-copy-publish&path=/page.md', {} );
    ok( $pub->{ok}, 'published with publish_copies' ) or diag explain $pub;
    like( subjects( $d, 'page.md' )->[0], qr/by bot \(agent\); prepared by bot, editor/,
        'recorded as an agent\'s publish, naming who prepared it' );

    $s->grant( 'bot', 'bots', [qw(api publish_copies)], \@ALL );
    my $half = api( 'POST', 'action=page-copy-publish&path=/page.md', {} );
    ok( !$half->{ok}, 'publish_copies without manage_content is refused' );
    like( $half->{error} // '', qr/manage_content/, '...naming it' );
};

subtest 'a multipart upload does not write into the copies folder' => sub {
    my $c = $s->call( 'editor', 'page-copy', query => 'action=page-copy&path=/page.md', body => {} );
    ok( $c->{ok}, 'an open copy' ) or diag explain $c;
    my $before = slurp( $d, 'lazysite/copies/pages/page.md' );
    my $b = 'xYzN772BOUNDARY';
    my $body = "--$b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"page.md\"\r\n"
        . "Content-Type: text/plain\r\n\r\nUPLOADED over the copy\r\n--$b--\r\n";
    my $u = $s->call( 'editor', 'file-upload', query => 'action=file-upload&path=/lazysite/copies/pages',
        raw => $body, content_type => "multipart/form-data; boundary=$b" );
    ok( !$u->{ok} || @{ $u->{errors} || [] }, 'the upload is refused' ) or diag explain $u;
    like( join( ' ', map { $_->{error} // '' } @{ $u->{errors} || [] } ) . ( $u->{error} // '' ),
        qr/copies folder|lazysite/, '...naming why' );
    is( slurp( $d, 'lazysite/copies/pages/page.md' ), $before, 'the copy is as it was' );
};

done_testing();
