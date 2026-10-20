#!/usr/bin/perl
# SM1218 (edge walk 0.15.11, G-1): a write whose request was sent and got no answer (a
# read timeout) was reported `outcome: failed`, though Odoo had done it, and a page
# told the person to try again. OOM 0.38 answers that case as UNKNOWN (counts.unknown,
# unknown_changes with a reason). The page answer says so: apply-incomplete as ever
# (a page that checks ok or kind still refuses it) with `unknown`, the change's
# outcome `unknown` with key, message and OOM's reason, and a sentence that does not
# say the change failed. Offline: OOM's fake Odoo throws a transport error that was
# sent and was a write.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Odoo::Error;

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'mix', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    params => 'title=title' );
bind( $d, id => 'quick', operation => 'shop.mixed', modes => 'public', apply => 'immediate',
    params => 'title=title' );
my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );

sub no_answer {
    my ($msg) = @_;
    $fake->{fail}{'x.basket.create'} = Odoo::Error->new( kind => 'transport', sent => 1, write => 1,
        message => $msg // 'Timed out while waiting for socket to become ready for reading' );
}
sub quick {
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('quick');
            Lazysite::Odoo::call( $b, {}, mode => 'public', visitor_key => undef, ip => '192.0.2.9' );
    } );
    return $r;
}
sub by_bucket { my ($r) = @_; return { map { ( $_->{bucket} => $_ ) } @{ $r->{result}{changes} || [] } } }

sub says_unknown {
    my ( $r, $label ) = @_;
    ok( !$r->{ok}, "$label: not ok" );
    is( $r->{kind}, 'apply-incomplete', "$label: the kind a page that checks kind already handles" ) or diag explain $r;
    is( $r->{unknown},                 1, "$label: unknown => 1 on the answer" );
    is( $r->{result}{counts}{unknown}, 1, "$label: counts.unknown" );
    ok( !$r->{result}{counts}{failed}, "$label: nothing counted failed" );
    my $c = by_bucket($r);
    is( $c->{line}{outcome}, 'unknown', "$label: the change's outcome is unknown" );
    ok( $c->{line}{unknown}, "$label: and flagged" );
    is( $c->{line}{key}, 'line:1', "$label: its key" );
    like( $c->{line}{reason},  qr/may have made/, "$label: OOM's reason" );
    like( $c->{line}{message}, qr/Timed out/,     "$label: the transport's message" );
    ok( !$c->{rename}{unknown}, "$label: the change beside it is not flagged" );
    like( $r->{error}, qr/not known whether Odoo made it/, "$label: the sentence says it is not known" );
    unlike( $r->{error}, qr/\b(?:failed|try again|retry)\b/i, "$label: it neither says failed nor advises a retry" );
    unlike( join( ' ', map { $_->{reason} // '' } @{ $r->{result}{changes} } ), qr/try again|retry/i, "$label: no change advises a retry" );
}

subtest 'an immediate apply that gets no answer says the outcome is not known' => sub {
    no_answer();
    says_unknown( quick(), 'immediate' );
};

subtest 'a confirmed plan says the same' => sub {
    no_answer();
    my ( undef, $p ) = quiet( sub { Lazysite::Odoo::action_odoo_run( 'mix', {}, %SAM ) } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::action_odoo_confirm( $p->{plan}, %SAM ) } );
    says_unknown( $c, 'confirm' );
};

subtest 'the reason goes through the same withholding as a failure\'s message' => sub {
    no_answer('read timeout talking to /opt/odoo/run/x.sock');
    my $l = by_bucket( quick() )->{line};
    is( $l->{outcome}, 'unknown', 'still unknown' );
    ok( $l->{withheld},         'the message is withheld' );
    ok( !defined $l->{message}, 'and not given' );
    like( $l->{reason}, qr/may have made/, 'the reason stands' );
    unlike( join( ' ', map { $_ // '' } values %$l ), qr{/opt}, 'no path anywhere in the change' );
};

subtest 'a refusal Odoo answered is still failed, with no unknown' => sub {
    $fake->{fail}{'x.basket.create'} = Odoo::Error->new( kind => 'fault', message => 'The period is closed',
        fault_class => 'odoo.exceptions.UserError' );
    my $r = quick();
    is( by_bucket($r)->{line}{outcome}, 'failed', 'failed' );
    ok( !exists $r->{unknown},                 'no unknown on the answer' );
    ok( !exists $r->{result}{counts}{unknown}, 'no unknown count' );
    unlike( $r->{error}, qr/not known/, 'the ordinary sentence' );
};

subtest 'a form is not delivered on an unknown change, and is told the outcome is not known' => sub {
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    no_answer();
    my ( undef, $v ) = quiet( sub { Lazysite::Handlers::_to_odoo( { id => 'quick', operation => 'shop.mixed', modes => 'public', apply => 'immediate', params => 'title=title' }, { title => 'x' }, { origin => 'form' } ) } );
    ok( !$v->{ok}, 'not a delivery' ) or diag explain $v;
    like( $v->{why}, qr/not known whether Odoo made it/, 'and says the outcome is not known' );
};

done_testing;
