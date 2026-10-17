package Odoo::Test::CredFake;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Test::AccountsFixture qw(make_instance);
use Odoo::Test::FakeOdoo;

# An instance for core.credential: the accounts fixture (identity check, auth_totp's enable
# wizard and disable action) with one ordinary user, bob@acme.example, who changes his own
# password through res.users.change_password as Odoo does it: the old password is checked, a
# password under six characters is refused (a policy), the new one is kept. The wizard also
# carries its provisioning url. As a transport for bin/oom-ops (OOM_OPS_TEST_TRANSPORT) it
# gives a session context as bob and, at exit, writes the end state (the password bob has,
# whether two-factor is on) to the file CRED_FAKE_STATE names, so a test can look after the
# process is gone.

our $OLD = 'Old-Pw-6f2a9c';

sub instance ($series = 16) {
    my $g = $series >= 19 ? 'group_ids' : 'groups_id';
    my $f = make_instance($series);
    $f->{fields}{'auth_totp.wizard'}{url} = { type => 'char', store => 1 };
    $f->insert( 'res.users', { id => 40, login => 'bob@acme.example', name => 'Bob', active => 1, share => 0, totp_enabled => 0, partner_id => 8, $g => [10] } );
    $f->{pw}{'bob@acme.example'} = $OLD;
    $f->{methods}{'res.users.change_password'} = sub ( $fk, $args, $kw ) {
        my ( $old, $new ) = @$args;
        my $user = $fk->{session_user} // die "fake: no session\n";
        Odoo::Test::FakeOdoo::_fault( 'AccessDenied', 'Access Denied' ) if ( $fk->{pw}{$user} // '' ) ne ( $old // '' ) || !length( $old // '' );
        Odoo::Test::FakeOdoo::_fault( 'UserError', 'Setting empty passwords is not allowed for security reasons!' ) if !length( $new // '' );
        Odoo::Test::FakeOdoo::_fault( 'UserError', 'Password must have at least 6 characters.' ) if length($new) < 6;
        $fk->{pw}{$user} = $new;
        return JSON::PP::true;
    };
    for my $m (qw(res.users.action_totp_enable_wizard res.users.identitycheck.run_check)) {
        my $was = $f->{methods}{$m};
        $f->{methods}{$m} = sub ( $fk, $args, $kw ) {
            my $act = $was->( $fk, $args, $kw );
            if ( ref $act eq 'HASH' && ( $act->{res_model} // '' ) eq 'auth_totp.wizard' ) {
                my $w = $fk->record( 'auth_totp.wizard', $act->{res_id} );
                ( my $raw = $w->{secret} ) =~ s/\s//g;
                $w->{url} = "otpauth://totp/odoo:bob?secret=$raw&issuer=odoo";
            }
            return $act;
        };
    }
    return $f;
}

my $FAKE;

sub context_args {
    my $series = $ENV{CRED_FAKE_SERIES} || 16;
    $FAKE = instance($series);
    return ( credential => { login => 'bob@acme.example', password => $OLD }, transport => $FAKE->web_session, retries => [0] );
}

END {
    return unless $FAKE && $ENV{CRED_FAKE_STATE};
    my ($bob) = grep { $_->{login} eq 'bob@acme.example' } map { $FAKE->record( 'res.users', $_ ) } @{ $FAKE->all_ids('res.users') };
    open my $fh, '>', $ENV{CRED_FAKE_STATE} or die "$ENV{CRED_FAKE_STATE}: $!";
    print {$fh} JSON::PP->new->canonical->encode( { pw => $FAKE->{pw}{'bob@acme.example'}, totp_enabled => $bob->{totp_enabled} ? 1 : 0 } );
    close $fh;
}

1;
