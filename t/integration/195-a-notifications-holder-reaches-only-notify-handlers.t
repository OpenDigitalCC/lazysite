#!/usr/bin/perl
# SM1010 R5 (ruled 2026-10-12 with SM1034 Q9): a group holding only
# manage_notifications reaches the handler actions - list, save, delete - and
# the destination rule keeps it to notify handlers. Before, the door asked for
# manage_forms, manage_data or manage_connectors, so the capability that writes
# a notification rule could not reach the page it is written on.
#
# What the widened door must NOT admit: another type's handler (save, change or
# delete), the configuration of the site's other handlers (the list shows it
# only its own type), the form bindings, and the schedule actions, whose door is
# unchanged. A holder of the old capabilities sees what it always saw.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps add_account run_child);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1010-r5-secret-' x 3;

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub api {
    my ( $d, $who, $action, $body ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => ( $post ? 'POST' : 'GET' ),
        QUERY_STRING   => "action=$action",
        CONTENT_LENGTH => length($json),
        REMOTE_ADDR    => '192.0.2.40',
        HTTP_X_REMOTE_USER => $who, HTTP_X_REMOTE_GROUPS => "role-$who", LAZYSITE_AUTH_TRUSTED => 1,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ),
    );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/forms" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
}
add_account( $d, $_ ) for qw(op notifier alice);
grant_caps( $d, 'op', 'ui', 'manage_users', 'manage_forms', 'manage_notifications' );
grant_caps( $d, 'notifier', 'ui', 'manage_notifications' );

my %SMTP = ( id => 'mail', type => 'smtp', name => 'Mail', to => 'ops@example.org', from => 'site@example.org' );
my %NOTIFY = ( id => 'rule', type => 'notify', name => 'Rule', recipients => '[{"accounts":["alice"]}]',
    unsubscribe_path => '/account' );

ok( api( $d, 'op', 'handler-save', \%SMTP )->{ok}, 'the operator makes an email handler' );
ok( api( $d, 'op', 'handler-save', \%NOTIFY )->{ok}, 'and a notification rule' );

# --- the door opens for manage_notifications alone ----------------------------------
my $list = api( $d, 'notifier', 'handler-list' );
ok( $list->{ok}, 'handler-list: manage_notifications alone reaches it' ) or diag explain $list;
is_deeply( [ map { $_->{id} } @{ $list->{handlers} || [] } ], ['rule'],
    'handler-list: it is shown the notification rule and not the email handler' );
unlike( encode_json($list), qr/ops\@example\.org/, 'handler-list: nothing of the email handler\'s settings' );
is_deeply( $list->{forms} // {}, {}, 'handler-list: and not the site\'s form bindings' );
ok( ref $list->{types} eq 'HASH' || ref $list->{types} eq 'ARRAY', 'handler-list: the types it can write are listed' );

my $full = api( $d, 'op', 'handler-list' );
is( scalar @{ $full->{handlers} || [] }, 2, 'handler-list: a manage_forms holder still sees both' );

my $save = api( $d, 'notifier', 'handler-save', { %NOTIFY, id => 'rule2', name => 'Rule 2' } );
ok( $save->{ok}, 'handler-save: it writes a notification rule' ) or diag explain $save;

my $smtp = api( $d, 'notifier', 'handler-save', { %SMTP, id => 'mail2' } );
ok( !$smtp->{ok}, 'handler-save: it cannot write an email handler' );
like( $smtp->{error} // '', qr/manage_forms/, 'handler-save: and is told which permission that needs' );

my $turn = api( $d, 'notifier', 'handler-save', { %NOTIFY, id => 'mail' } );
ok( !$turn->{ok}, 'handler-save: it cannot turn the email handler into a rule (that needs both)' );

my $del = api( $d, 'notifier', 'handler-delete', { id => 'mail' } );
ok( !$del->{ok}, 'handler-delete: it cannot delete the email handler' );
ok( api( $d, 'notifier', 'handler-delete', { id => 'rule2' } )->{ok}, 'handler-delete: it deletes its own kind' );

# --- the doors that were not widened ------------------------------------------------
ok( !api( $d, 'notifier', 'schedule-list' )->{ok}, 'schedule-list: still closed to it' );
ok( !api( $d, 'notifier', 'form-targets-save', { form => 'contact', handlers => ['rule'] } )->{ok},
    'form-targets-save: binding still needs manage_forms' );
ok( !api( $d, 'alice', 'handler-list' )->{ok}, 'handler-list: still closed to a member with none of them' );

done_testing;
