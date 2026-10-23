#!/usr/bin/perl
# SM1275 (rulings 10a, 10b): a run whose apply left a change UNKNOWN (its request
# was sent and no answer came, SM1218) is resumed. The answer names the run (`run`,
# the plan id - never the journal's path). Resuming it, OOM reads each unknown
# change back first: found made, it is journalled done; found not made, it is
# carried and applied with the rest; with no way to read it back, the resume is
# refused `unknown-outcome` (409) and names the change, until a person says it was
# made (assume_done) or was not (assume_not_done). Only the run's own maker, or a
# holder of settle_odoo_writes, may say so; anyone the binding admits may check
# again. A binding any visitor may run is never resumed by a visitor. A settled run
# is not resumed twice. Every resume is one call record naming the run and the
# decision. In-process, on OOM's fake Odoo; t/unit/odoo/107 holds it through oomd
# and the page endpoint.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();
use Odoo::Error;

my ( $d, $fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
bind( $d, id => 'mix', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'title=title' );
bind( $d, id => 'mix-later', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    params => 'title=title' );
bind( $d, id => 'open', operation => 'shop.mixed', modes => 'public', apply => 'immediate', params => 'title=title' );

my %SAM   = ( mode => 'authenticated', actor => 'sam',   groups => ['staff'], caps => {}, ip => '192.0.2.5' );
my %ALICE = ( mode => 'authenticated', actor => 'alice', groups => ['staff'], caps => {}, ip => '192.0.2.6' );
my %OPS   = ( mode => 'authenticated', actor => 'ops', groups => [], caps => { settle_odoo_writes => 1, manage_connectors => 1 },
    ip => '192.0.2.7' );

sub timeout { return Odoo::Error->new( kind => 'transport', sent => 1, write => 1, message => 'Timed out while waiting for socket to become ready for reading' ) }
sub run_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, strict => 1, %ctx );
    } );
    return $r;
}
sub resume_as {
    my ( $run, %c ) = @_;
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::resume( $run, %c ) } );
    return $r;
}
sub lines { return scalar @{ $fake->all_ids('x.basket') } }
sub name1 { return $fake->record( 'x.product', 1 )->{name} }
sub reset_shop {
    delete $fake->{fail}{$_}    for keys %{ $fake->{fail} };
    delete $fake->{methods}{$_} for keys %{ $fake->{methods} };
    $fake->record( 'x.product', 1 )->{name} = 'Tea';
}
# The write reaches Odoo and is made; its answer never comes.
sub made_but_no_answer {
    $fake->{methods}{'x.product.write'} = sub {
        my ( $f, $margs ) = @_;
        my ( $ids, $vals ) = @$margs;
        $f->record( 'x.product', $_ )->{name} = $vals->{name} for @$ids;
        die timeout();
    };
}
sub by_seq { my ($l) = @_; return { map { ( $_->{key} => $_ ) } @{ $l || [] } } }

subtest 'the answer of an apply that left a change unknown names the run, and no path' => sub {
    reset_shop();
    $fake->{fail}{'x.product.write'} = timeout();
    my $r = run_b( 'mix', { title => 'Renamed' }, %SAM );
    is( $r->{kind},    'apply-incomplete', 'apply-incomplete, as SM1218 answers it' ) or diag explain $r;
    is( $r->{unknown}, 1,                  'one change unknown' );
    like( $r->{run} // '', qr/\A[0-9a-f]{32}\z/, 'the run handle' );
    is( $r->{run}, $r->{plan}, 'is the plan the apply answered with' );
    is( $r->{may_assume}, 1, 'and its maker may assume' );
    unlike( encode_json($r), qr{/lazysite/|journal\.jsonl}, 'no host path in the answer' );
};

subtest 'found not made: carried, and applied with the rest' => sub {
    reset_shop();
    $fake->{fail}{'x.product.write'} = timeout();
    my $r = run_b( 'mix', { title => 'Renamed' }, %SAM );
    my $before = lines();
    is( name1(), 'Tea', 'Odoo did not make the write' );
    delete $fake->{fail}{'x.product.write'};
    my $s = resume_as( $r->{run}, %SAM );
    ok( $s->{ok} && $s->{applied}, 'the resume applies' ) or diag explain $s;
    is( $s->{resumes}, $r->{run}, 'it carries on the run' );
    my $set = by_seq( $s->{settled} );
    is( $set->{'rename:1'}{how},     'read',          'the rename was read back' );
    is( $set->{'rename:1'}{outcome}, 'not_attempted', 'found not made' );
    is( name1(),        'Renamed',   'and is made now' );
    is( lines(),        $before + 1, 'the line the first apply never reached is made' );
    ok( !exists $s->{run}, 'nothing is left unknown, so no run to resume' );
    my $again = resume_as( $r->{run}, %SAM );
    is( $again->{kind}, 'settled', 'a settled run is not resumed again' ) or diag explain $again;
};

subtest 'found made: journalled done, never sent again' => sub {
    reset_shop();
    made_but_no_answer();
    my $r = run_b( 'mix', { title => 'Renamed' }, %SAM );
    is( $r->{unknown}, 1, 'unknown' ) or diag explain $r;
    is( name1(), 'Renamed', 'though Odoo made it' );
    my $writes = scalar grep { ( $_->[4] // '' ) eq 'x.product' && ( $_->[5] // '' ) eq 'write' } @{ $fake->calls };
    my $before = lines();
    my $s = resume_as( $r->{run}, %SAM );
    ok( $s->{ok}, 'the resume is ok' ) or diag explain $s;
    my $set = by_seq( $s->{settled} );
    is( $set->{'rename:1'}{how},     'read', 'read back' );
    is( $set->{'rename:1'}{outcome}, 'done', 'found made' );
    is( scalar( grep { ( $_->[4] // '' ) eq 'x.product' && ( $_->[5] // '' ) eq 'write' } @{ $fake->calls } ), $writes,
        'the write was not sent again' );
    is( lines(), $before + 1, 'the rest of the run applied' );
};

subtest 'no read tells: refused by name until a person says' => sub {
    reset_shop();
    $fake->{fail}{'x.basket.create'} = timeout();
    my $r = run_b( 'mix', { title => 'Renamed' }, %SAM );
    is( $r->{unknown}, 1, 'the line is unknown' ) or diag explain $r;
    delete $fake->{fail}{'x.basket.create'};
    my $before = lines();
    my $c = resume_as( $r->{run}, %SAM );
    is( $c->{kind}, 'unknown-outcome', 'refused unknown-outcome' ) or diag explain $c;
    is( $c->{run},  $r->{run},         'naming the run' );
    is_deeply( [ map { $_->{key} } @{ $c->{changes} } ], ['line:1'], 'and the change that cannot be read back' );
    is( $c->{may_assume}, 1, 'its maker may say' );
    is( lines(), $before, 'nothing was sent' );

    my $other = resume_as( $r->{run}, %ALICE );
    is( $other->{kind}, 'unknown-outcome', 'another caller the binding admits may check again' ) or diag explain $other;
    is( $other->{may_assume}, 0, 'and is told they may not say' );
    my $no = resume_as( $r->{run}, %ALICE, assume_done => ['line:1'] );
    is( $no->{kind}, 'not-yours', 'nor may they assume' ) or diag explain $no;

    my $bad = resume_as( $r->{run}, %SAM, assume_done => 'line:1' );
    is( $bad->{kind}, 'invalid', 'an assume list is a list' );
    my $wrong = resume_as( $r->{run}, %SAM, assume_done => ['nothing:9'] );
    is( $wrong->{kind}, 'invalid', 'a change that did not end unknown is refused by OOM' ) or diag explain $wrong;

    my $s = resume_as( $r->{run}, %SAM, assume_done => ['line:1'] );
    ok( $s->{ok}, 'its maker says it was made' ) or diag explain $s;
    my $set = by_seq( $s->{settled} );
    is( $set->{'line:1'}{how},     'assumed', 'assumed' );
    is( $set->{'line:1'}{outcome}, 'done',    'done' );
    is( $s->{result}{total}, 0, 'nothing was left to apply' );
    is( lines(), $before, 'and nothing was sent' );
};

subtest 'assumed not made: carried, and made now' => sub {
    reset_shop();
    $fake->{fail}{'x.basket.create'} = timeout();
    my $r = run_b( 'mix', { title => 'Renamed' }, %SAM );
    delete $fake->{fail}{'x.basket.create'};
    my $before = lines();
    my $s = resume_as( $r->{run}, %SAM, assume_not_done => ['line:1'] );
    ok( $s->{ok}, 'resumed' ) or diag explain $s;
    is( by_seq( $s->{settled} )->{'line:1'}{outcome}, 'not_attempted', 'assumed not made' );
    is( lines(), $before + 1, 'and made by the resume' );
};

subtest 'a holder of settle_odoo_writes may say on anyone\'s run; a confirmed plan is a run too' => sub {
    reset_shop();
    $fake->{fail}{'x.basket.create'} = timeout();
    my ( undef, $p ) = quiet( sub { my ($b) = Lazysite::Odoo::find_binding('mix-later'); Lazysite::Odoo::call( $b, {}, strict => 1, %SAM ) } );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %SAM ) } );
    is( $c->{run}, $p->{plan}, 'the confirm names the run' ) or diag explain $c;
    delete $fake->{fail}{'x.basket.create'};
    my $s = resume_as( $c->{run}, %OPS, assume_done => ['line:1'] );
    ok( $s->{ok}, 'the operator settles it' ) or diag explain $s;
};

subtest 'a binding any visitor may run is not resumed by a visitor' => sub {
    reset_shop();
    my ($vk) = Lazysite::Odoo::Visitor::mint();
    $fake->{fail}{'x.basket.create'} = timeout();
    my $r = run_b( 'open', {}, mode => 'public', visitor_key => $vk, ip => '192.0.2.9' );
    is( $r->{unknown}, 1, 'unknown' ) or diag explain $r;
    ok( !exists $r->{run}, 'the visitor is given no run to resume' );
    my ($pid) = $r->{plan};
    delete $fake->{fail}{'x.basket.create'};
    my $v = resume_as( $pid, mode => 'public', visitor_key => $vk, ip => '192.0.2.9' );
    is( $v->{kind}, 'mode', 'the visitor is refused' ) or diag explain $v;
    my $s = resume_as( $pid, %OPS, assume_not_done => ['line:1'] );
    ok( $s->{ok}, 'an operator settles it, on the run\'s own terms' ) or diag explain $s;
};

subtest 'a run that is not one is not found' => sub {
    is( resume_as( 'f' x 32, %SAM )->{kind}, 'not-found', 'an id with no run' );
    is( resume_as( '../x',   %SAM )->{kind}, 'not-found', 'a malformed id' );
    my $ok = run_b( 'mix', { title => 'Fine' }, %SAM );
    reset_shop();
    my $fine = run_b( 'mix', { title => 'Fine' }, %SAM );
    ok( $fine->{ok}, 'an apply that finished' ) or diag explain $fine;
    is( resume_as( $fine->{plan}, %SAM )->{kind}, 'not-found', 'is no run to resume' );
};

subtest 'each resume is one record naming the run and the decision, never a key' => sub {
    my @rows = grep { ( $_->{phase} // '' ) eq 'resume' } @{ Lazysite::Odoo::read_calls() };
    ok( scalar @rows, 'resumes are recorded' );
    ok( ( grep { ( $_->{decision} // '' ) eq 'check' } @rows ), 'a check' );
    ok( ( grep { ( $_->{decision} // '' ) eq 'assume-done:1 assume-not-done:0' } @rows ), 'an assume, counted' );
    is( scalar( grep { !defined $_->{run} && ( $_->{kind} // '' ) ne 'not-found' } @rows ), 0, 'each names its run' );
    unlike( encode_json( \@rows ), qr/line:1/, 'and no change key' );
    my $audit = do { local $/; open my $fh, '<', "$d/lazysite/logs/audit.log" or die $!; <$fh> };
    like( $audit, qr/odoo-call \| mix -> shop\.mixed .*decision=assume-done:1/, 'the audit line names the decision' );
};

done_testing;
