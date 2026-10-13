#!/usr/bin/perl
# SM1019 (SM1010 phase 1): A NOTIFICATION RULE IS CHECKED WHEN IT IS SAVED.
#
# A `notify` handler names its recipients as a JSON list of sources (the grammar
# is Lazysite::Outbox's), the channels it uses, its template and its caps. A rule
# that cannot work is refused at save, naming the field - SM807's reason: the
# first event is the worst place to find out.
#
# And who may save one is the ruling's: "New 'manage_notifications' cap", a
# dedicated capability, off by default, held by the operator groups.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(site_tempdir);
use Lazysite::Handlers ();
use Lazysite::Outbox   ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nplugins:\n  - plugins/data.pl\n" );
spit( "$d/lazysite/db/tables/subscriptions.yaml",
    "title: Subscriptions\ntimestamps: true\nfields:\n  post:\n    type: text\n" );
spit( "$d/lazysite/db/tables/members.yaml",
    "title: Members\nfields:\n  email:\n    type: text\n  list:\n    type: text\n" );
$Lazysite::Handlers::DOCROOT = $d;

my $FOLLOW = '[{"owners_of":{"table":"subscriptions","where":{"post":"post"}}}]';

sub rule {
    my (%o) = @_;
    return { id => 'followers', type => 'notify', name => 'Followers', recipients => $FOLLOW,
        unsubscribe_path => '/account/following', %o };
}

subtest 'a good rule is accepted, with its defaults' => sub {
    my ( $h, $why ) = Lazysite::Handlers::validate_handler( rule() );
    ok( $h, 'accepted' ) or diag $why;
    is( $h->{channels},           'email', 'channels default to email' );
    is( $h->{notify_actor},       'false', 'the actor is left out by default' );
    is( $h->{per_recipient_hour}, '3',     'a per-recipient cap by default' );
    is( $h->{unsubscribe}, 'true', 'and the unsubscribe link is ON by default (ruled)' );
};

subtest 'every source of the grammar parses' => sub {
    my ( $src, $why ) = Lazysite::Outbox::parse_recipients(
        '[{"accounts":["ann","bob"]},'
            . '{"owners_of":{"table":"subscriptions","where":{"post":"post"}}},'
            . '{"addresses_from":{"table":"members","column":"email","where":{"list":"list"}}},'
            . '{"fixed":["office@example.org"]},'
            . '{"submitter":"account"},{"submitter":{"field":"email"}}]' );
    ok( $src, 'all six' ) or diag $why;
    is( scalar @$src, 6, 'six sources' );
};

subtest 'a rule that cannot work is refused, by field' => sub {
    for my $case (
        [ 'not JSON',   { recipients => 'everyone' }, 'recipients', qr/JSON list/ ],
        [ 'no sources', { recipients => '[]' },       'recipients', qr/names no source/ ],
        [ 'unknown source', { recipients => '[{"everyone":true}]' }, 'recipients', qr/not a source/ ],
        [ 'two keys', { recipients => '[{"fixed":["a@b.org"],"accounts":["x"]}]' }, 'recipients', qr/one key/ ],
        [ 'bad where field', { recipients => '[{"owners_of":{"table":"subscriptions","where":{"post":"a b"}}}]' },
            'recipients', qr/must name an event field/ ],
        [ 'a fixed address naming two', { recipients => '[{"fixed":["root,b@example.org"]}]' },
            'recipients', qr/more than one recipient/ ],
        [ 'bad channel', { channels => 'email,sms' }, 'channels', qr/email, bell or both/ ],
        [ 'an off-site unsubscribe page', { unsubscribe_path => '//evil.example/x' }, 'unsubscribe_path', qr/starting \// ],
        [ 'a cap that is not a number', { per_recipient_hour => 'lots' }, 'per_recipient_hour', qr/whole number/ ],
        [ 'a template path', { template => '../../etc/passwd' }, 'template', qr/must be a name/ ],
        )
    {
        my ( $label, $over, $field, $re ) = @$case;
        my ( $h, $why, $f ) = Lazysite::Handlers::validate_handler( rule(%$over) );
        ok( !$h, "$label: refused" );
        is( $f, $field, "$label: on $field" );
        like( $why, $re, "$label: saying why" );
    }
    my ( $h, $why ) = Lazysite::Handlers::validate_handler(
        rule( unsubscribe => 'false', unsubscribe_path => '' ) );
    ok( $h, 'the unsubscribe link can be turned off, and then needs no page' ) or diag $why;
    # SM1073: the link is the engine's one-click link, so a rule needs no page
    # for it while it is on either.
    ( $h, $why ) = Lazysite::Handlers::validate_handler( rule( unsubscribe_path => '' ) );
    ok( $h, 'unsubscribe on with no page of its own is accepted (SM1073)' ) or diag $why;
    ( $h, $why ) = Lazysite::Handlers::validate_handler( rule( recipients => '[{"submitter":"account"}]' ) );
    like( $why, qr/notify_actor/, 'writing to the submitter\'s account needs notify_actor' );
    ( $h, $why ) = Lazysite::Handlers::validate_handler(
        rule( recipients => '[{"submitter":"account"}]', notify_actor => 'true' ) );
    ok( $h, 'and is accepted with it' ) or diag $why;
};

subtest 'saving one needs manage_notifications - the ruling' => sub {
    my $r = Lazysite::Handlers::action_handler_save( rule(),
        caps => { manage_forms => 1, manage_data => 1, manage_connectors => 1 } );
    is( $r->{kind}, 'forbidden', 'every other handler capability is not enough' );
    like( $r->{error}, qr/manage_notifications/, 'and the refusal names the one it needs' );

    $r = Lazysite::Handlers::action_handler_save( rule(), caps => { manage_notifications => 1 } );
    ok( $r->{ok}, 'with it, the rule is saved' ) or diag explain $r;
    is( Lazysite::Handlers::cap_for_type('notify'), 'manage_notifications',
        'and that is the type\'s capability, which the schedule asks of its job account too' );
};

subtest 'the tables a rule reads are checked against the site' => sub {
    my $r = Lazysite::Handlers::action_handler_save(
        rule( recipients => '[{"owners_of":{"table":"posts","where":{"id":"post"}}}]' ),
        caps => { manage_notifications => 1 } );
    like( $r->{error}, qr/no table 'posts'/, 'an undeclared table is refused' );

    $r = Lazysite::Handlers::action_handler_save(
        rule( recipients => '[{"owners_of":{"table":"members","where":{"list":"list"}}}]' ),
        caps => { manage_notifications => 1 } );
    like( $r->{error}, qr/timestamps: true/, 'owners_of a table that records no writer is refused' );

    $r = Lazysite::Handlers::action_handler_save(
        rule( recipients => '[{"addresses_from":{"table":"members","column":"mail"}}]' ),
        caps => { manage_notifications => 1 } );
    like( $r->{error}, qr/has no column mail/, 'a column the table lacks is refused' );

    $r = Lazysite::Handlers::action_handler_save(
        rule( recipients => '[{"addresses_from":{"table":"members","column":"email","where":{"list":"list"}}}]' ),
        caps => { manage_notifications => 1 } );
    ok( $r->{ok}, 'addresses held in a table are allowed (ruled: engine = mechanism)' )
        or diag explain $r;
};

done_testing();
