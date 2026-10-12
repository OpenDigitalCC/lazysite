#!/usr/bin/perl
# SM747 OB5: Odoo's faults reach a caller as a KIND - session-expired,
# invalid-credential, odoo-access-refused, transport-failure and the rest - and
# a sentence of lazysite's own. The fault's own text is logged and NEVER
# returned: three leaks in three passes (SM713, SM738, SM739) were exactly this,
# and Odoo's text can carry a traceback, a module path or a record name.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip);

BEGIN { oom_or_skip() }
use Odoo::Error;
use Lazysite::Odoo ();

my $SECRET = 'Traceback (most recent call last): /opt/odoo/addons/x.py line 9 api_key=abc123';

sub fault_of {
    my (%e) = @_;
    my $err = Odoo::Error->new( message => $SECRET, %e );
    my $log = '';
    my $r;
    {
        local *STDERR;
        open STDERR, '>', \$log or die $!;
        $r = Lazysite::Odoo::fault( $err, binding => 'b1', operation => 'shop.add', mode => 'public' );
    }
    return ( $r, $log );
}

my @cases = (
    [ 'access', { kind => 'fault', fault_class => 'odoo.exceptions.AccessError' }, 'odoo-access-refused' ],
    [ 'credential', { kind => 'fault', fault_class => 'odoo.exceptions.AccessDenied' }, 'invalid-credential' ],
    [ 'session', { kind => 'fault', fault_class => 'odoo.http.SessionExpiredException' }, 'session-expired' ],
    [ 'validation', { kind => 'fault', fault_class => 'odoo.exceptions.ValidationError' }, 'odoo-validation' ],
    [ 'missing', { kind => 'fault', fault_class => 'odoo.exceptions.MissingError' }, 'odoo-missing' ],
    [ 'other',     { kind => 'fault' },     'odoo-fault' ],
    [ 'transport', { kind => 'transport' }, 'transport-failure' ],
    [ 'scope',     { kind => 'refused', code => 'scope' },       'scope-refused' ],
    [ 'redirect',  { kind => 'refused', code => 'redirect' },    'refused' ],
    [ 'oversize',  { kind => 'refused', code => 'oversize' },    'refused' ],
    [ 'read-only', { kind => 'refused', code => 'read-only' },   'read-only' ],
    [ 'stale',     { kind => 'refused', code => 'stale' },       'stale' ],
    [ 'applied',   { kind => 'refused', code => 'applied' },     'applied' ],
    [ 'edited',    { kind => 'refused', code => 'fingerprint' }, 'edited' ],
    [ 'config',    { kind => 'config' }, 'config' ],
    [ 'usage',     { kind => 'usage' },  'invalid' ],
);

for my $c (@cases) {
    my ( $name, $e, $kind ) = @$c;
    subtest "$name -> $kind" => sub {
        my ( $r, $log ) = fault_of(%$e);
        is( $r->{ok},   0,     'not ok' );
        is( $r->{kind}, $kind, 'the kind is named' );
        unlike( $r->{error}, qr/Traceback|addons|abc123|line 9/, 'the fault text is not returned' );
        like( $log, qr/abc123/,     'it is in the log, where an operator can read it' );
        like( $log, qr/binding=b1/, 'with the binding it happened on' );
    };
}

subtest 'the four OB5 kinds are four different kinds' => sub {
    my %k = map { ( fault_of( %{ $_->[1] } ) )[0]->{kind} => 1 } @cases[ 0, 1, 2, 6 ];
    is( scalar keys %k, 4, 'access, credential, session and transport are told apart' );
};

subtest 'a die that is not OOM\'s is an internal fault, said without its text' => sub {
    my $log = '';
    my $r;
    {
        local *STDERR;
        open STDERR, '>', \$log or die $!;
        $r = Lazysite::Odoo::fault("Can't locate object method at /usr/share/perl5/X.pm line 3.\n");
    }
    is( $r->{kind}, 'internal', 'kind internal' );
    unlike( $r->{error}, qr/perl5|line 3/, 'no host path returned' );
};

subtest 'a kind decides the record\'s outcome' => sub {
    is( Lazysite::Odoo::outcome_of(undef),                 'answered' );
    is( Lazysite::Odoo::outcome_of('transport-failure'),   'unanswered' );
    is( Lazysite::Odoo::outcome_of('odoo-access-refused'), 'odoo-fault' );
    is( Lazysite::Odoo::outcome_of('invalid-credential'),  'odoo-fault' );
    is( Lazysite::Odoo::outcome_of('session-expired'),     'odoo-fault' );
    is( Lazysite::Odoo::outcome_of('scope-refused'),       'refused' );
    is( Lazysite::Odoo::outcome_of('mode'),                'refused' );
};

done_testing();
