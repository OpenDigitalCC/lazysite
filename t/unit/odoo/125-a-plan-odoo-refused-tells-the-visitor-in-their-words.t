#!/usr/bin/perl
# SM1374 (T-62): a plan that fails at Odoo answered the visitor "the plan did not
# apply completely - see the counts" - an operator's sentence - and Odoo's reason
# was only in the changes. Now the answer's `error` is Odoo's own message when the
# failed change was refused as VALIDATION (ValidationError, UserError), without the
# "Odoo Server Error:" OOM's transport puts before it; any other failure answers a
# plain sentence for the visitor. No other category's text reaches the answer at
# all (an access fault names a model and groups), in `error` or in the change. The
# counts stay in the result and the operator's log line. Fakes only: the shop
# fixture's transport, nothing near a real Odoo.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Odoo::Error;

my $PLAIN = q{The change was not saved. Try again, or tell the site's operator.};

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'quick', operation => 'shop.mixed', modes => 'public', apply => 'immediate',
    params => 'title=title' );

sub refuse {
    my ( $class, $msg ) = @_;
    $fake->{fail}{'x.basket.create'}
        = Odoo::Error->new( kind => 'fault', message => $msg, ( defined $class ? ( fault_class => $class ) : () ) );
    return;
}

sub quick {
    my ( $log, $r ) = quiet(
        sub {
            my ($b) = Lazysite::Odoo::find_binding('quick');
            Lazysite::Odoo::call( $b, {}, mode => 'public', visitor_key => undef, ip => '192.0.2.9' );
        } );
    return ( $r, $log );
}

sub failed {
    my ($r) = @_;
    return ( grep { ( $_->{outcome} // '' ) eq 'failed' } @{ $r->{result}{changes} || [] } )[0] // {};
}

for my $class (qw(odoo.exceptions.UserError odoo.exceptions.ValidationError)) {
    subtest "a $class answers Odoo's message, without the server's prefix" => sub {
        refuse( $class, 'Odoo Server Error: The period is closed for this date' );
        my ( $r, $log ) = quick();
        is( $r->{kind}, 'apply-incomplete', 'apply-incomplete as ever' ) or diag explain $r;
        is( $r->{error}, 'The period is closed for this date', "the answer is Odoo's reason" );
        my $c = failed($r);
        is( $c->{message}, 'The period is closed for this date', '  and so is the change\'s message' );
        ok( $c->{validation}, '  which says it is validation' );
        ok( !$c->{withheld},  '  and is not withheld' );
        unlike( $r->{error}, qr/see the counts|Odoo Server Error/i, '  no operator sentence, no prefix' );
        is( $r->{result}{counts}{failed}, 1, 'the counts stay in the result' );
        like( $log, qr/did not apply completely.*failed=1/, '  and in the log line' );
    };
}

my $ACCESS = q{Odoo Server Error: You are not allowed to access 'Secret Ledger' (x.secret.ledger) records.}
    . q{ This operation is allowed for the following groups: - Accounting / Auditor};
for my $case (
    [ 'odoo.exceptions.AccessError', $ACCESS, 'an access fault' ],
    [ 'odoo.exceptions.MissingError', 'Odoo Server Error: Record does not exist or has been deleted. (Record: x.secret.ledger(42,))', 'a missing record' ],
    [ undef, 'Odoo Server Error: psycopg2 relation x_secret_ledger column q_internal', 'an unclassified fault' ],
    )
{
    my ( $class, $msg, $what ) = @$case;
    subtest "$what answers the plain sentence, and none of its text" => sub {
        refuse( $class, $msg );
        my ( $r, $log ) = quick();
        is( $r->{kind},  'apply-incomplete', 'apply-incomplete' ) or diag explain $r;
        is( $r->{error}, $PLAIN,             'the plain visitor sentence' );
        my $c = failed($r);
        ok( $c->{withheld},    '  the change\'s text is withheld' );
        ok( !$c->{validation}, '  and is not called validation' );
        my $json = JSON::PP->new->canonical->encode($r);
        unlike( $json, qr/secret|Ledger|Auditor|psycopg|x_secret|Record does not exist|Server Error/i,
            '  nothing of Odoo\'s text anywhere in the answer' );
        is( $r->{result}{counts}{failed}, 1, 'the counts stay in the result' );
        like( $log, qr/did not apply completely.*failed=1/, '  and in the log line' );
    };
}

subtest 'a validation message the filter withholds still answers the plain sentence' => sub {
    refuse( 'odoo.exceptions.UserError', 'Odoo Server Error: cannot write /var/lib/odoo/filestore/x' );
    my ($r) = quick();
    is( $r->{error}, $PLAIN, 'the plain sentence' );
    ok( failed($r)->{withheld}, '  the change is withheld' );
    unlike( JSON::PP->new->encode($r), qr{/var/lib}, '  and the path is nowhere' );
};

done_testing();
