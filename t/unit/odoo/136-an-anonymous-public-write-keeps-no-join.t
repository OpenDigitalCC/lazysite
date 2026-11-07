#!/usr/bin/perl
# SM1395 (ruling 154): AN ANONYMOUS PUBLIC WRITE BINDING KEEPS NO JOIN. A binding
# with modes: public, apply: immediate and a write operation kept two records
# that together tied what a visitor sent to where it came from: the plan store
# (the parameters, the owner visitor:<hash>) and the call record (the IP and the
# same hash on every line). `anonymous: 1`, allowed only with modes: public:
#
#   * once the call is applied the parameters leave the plan and run records
#     (plan.json, run.json, the journal: each value redacted to null, the field
#     names kept) - here, and for a confirmed plan once it is confirmed;
#   * the call line is written without ip and without visitor (binding, time,
#     phase and outcome stay), and so is the audit row;
#   * the per-visitor rate cap still trips, counted by the hash in recent.jsonl,
#     which no call line joins to;
#   * anonymous: 1 on a binding with no public mode is refused, naming why;
#   * ruling 160: once the plan is spent the visitor hash leaves its records too
#     (meta.json's owner and OOM's actors become `visitor`); until then the owner
#     keeps it and the maker's confirm works; a spent plan is nobody's.
#     Through the real oomd, with the daemon's run folder: t/unit/odoo/137.
#
# Reverted, the first three subtests fail: the record carries ip and visitor,
# the plan keeps the parameters, and the setting is not refused.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();
use Lazysite::Handlers      ();

my ( $d, $fake ) = shop_ready();
$Lazysite::Odoo::Visitor::DOCROOT = $d;
bind( $d, id => 'anon', operation => 'shop.add', modes => 'public', apply => 'immediate', anonymous => 1,
    params => 'product=product', visitor_param => 'basket_key', rate_per_visitor_hour => 2 );
bind( $d, id => 'anonc', operation => 'shop.add', modes => 'public', apply => 'confirm', anonymous => 1,
    params => 'product=product', visitor_param => 'basket_key' );
bind( $d, id => 'named', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product', visitor_param => 'basket_key' );

my ($key) = Lazysite::Odoo::Visitor::mint();
my $HASH = Lazysite::Odoo::Visitor::visitor_id($key);
my $IP   = '192.0.2.77';

sub call_it {
    my ( $id, %more ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, { product => 1 }, mode => 'public', visitor_key => $key, strict => 1, ip => $IP, %more );
    } );
    return $r;
}
sub lines {
    my ($id) = @_;
    open my $fh, '<', Lazysite::Odoo::calls_file() or return ();
    my @l = grep { ( $_->{binding} // '' ) eq $id } map { decode_json($_) } <$fh>;
    close $fh;
    return @l;
}
sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return scalar <$fh> }
sub pdir  { return Lazysite::Odoo::plans_dir() . "/$_[0]" }
sub plan_files { my ($p) = @_; return grep { -f } map { pdir($p) . "/$_" } qw(plan.json run.json journal.jsonl result.json) }
sub audit { return slurp("$d/lazysite/logs/audit.log") }

# SM1395 (ruling 160): every file under a plan's folder, and under the daemon's
# run folder its meta names, that holds a visitor hash: the hashes given (this
# test's visitor by default), or any visitor:<hex> label.
sub hashed {
    my ( $p, @h ) = @_;
    @h = ($HASH) unless @h;
    my $alt  = join "|", map { quotemeta } @h;
    my $meta = eval { decode_json( slurp( pdir($p) . '/meta.json' ) ) } || {};
    my @dirs = ( pdir($p) );
    push @dirs, Lazysite::Odoo::store_dir() . "/runs/$meta->{run_id}" if length( $meta->{run_id} // '' );
    my @hit;
    require File::Find;
    File::Find::find( { no_chdir => 1, wanted => sub {
                push @hit, $_ if -f $_ && slurp($_) =~ /visitor:[0-9a-f]{16,}|$alt/;
    } }, grep { -d } @dirs );
    return @{ [ sort @hit ] };
}

subtest 'the call record and the audit row carry no address and no visitor hash' => sub {
    my $r = call_it('anon');
    ok( $r->{ok} && $r->{applied}, 'the write applied' ) or diag explain $r;
    my @l = lines('anon');
    is( scalar @l, 1, 'one call line' );
    ok( !exists $l[0]{ip},      'no ip on it' )      or diag explain \@l;
    ok( !exists $l[0]{visitor}, 'no visitor on it' ) or diag explain \@l;
    is( $l[0]{phase},   'apply',    'the phase stays' );
    is( $l[0]{outcome}, 'answered', 'and the outcome' );
    ok( $l[0]{at} && $l[0]{binding} eq 'anon', 'and the time and the binding' );
    my ($row) = grep { /odoo-call \| anon -> / } split /\n/, audit();
    ok( $row, 'the audit row is there' );
    unlike( $row // '', qr/\Q$IP\E/, 'with no address' );
    unlike( slurp( Lazysite::Odoo::calls_file() ), qr/\Q$HASH\E/, 'the hash is on no call line' );
};

subtest 'the parameters left the plan and run records once applied' => sub {
    my ($r) = lines('anon');
    my $plan = ( call_it('anon') )->{plan};
    my @files = plan_files($plan);
    cmp_ok( scalar @files, '>=', 3, 'plan, run and journal records exist' );
    for my $f (@files) {
        my $t = slurp($f);
        unlike( $t, qr/"basket_key"\s*:\s*"[0-9a-f]{64}"|"product_id"\s*:\s*[0-9]|"qty"\s*:\s*[0-9]|"product"\s*:\s*[0-9]/,
            ( $f =~ m{/([^/]+)\z} )[0] . ' holds no parameter value' );
    }
    my $p = decode_json( slurp( pdir($plan) . '/plan.json' ) );
    ok( exists $p->{params}{product} && !defined $p->{params}{product}, 'the field names stay, the values are null' );
    ok( $p->{fingerprint},                                             'the fingerprint stays' );
    like( slurp( pdir($plan) . '/journal.jsonl' ), qr/"outcome":"done"/, 'the journal keeps its outcomes' );
    is( decode_json( slurp( pdir($plan) . '/meta.json' ) )->{owner}, 'visitor', 'the owner is kept as visitor, with no hash' );
    my @hp = hashed($plan);
    is_deeply( \@hp, [], q{and no record of the spent plan names the hash} ) or diag explain \@hp;
};

subtest 'anonymous: 1 on a binding with no public mode is refused, naming why' => sub {
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    my $r = Lazysite::Handlers::action_handler_save(
        { type => 'odoo', name => 'nope', id => 'nope', operation => 'shop.add', modes => 'authenticated',
            callers => 'staff', anonymous => 1, params => 'product=product' }, unconstrained => 1 );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{field}, 'anonymous', 'naming the field' );
    like( $r->{error}, qr/no public mode/, 'and why' );
    ok( !( Lazysite::Odoo::find_binding('nope') )[0], 'nothing saved' );
    my $bad = Lazysite::Handlers::action_handler_save(
        { type => 'odoo', name => 'x', id => 'x', operation => 'shop.add', modes => 'public', anonymous => 'maybe',
            params => 'product=product' }, unconstrained => 1 );
    like( $bad->{error} // '', qr/anonymous must be 1 or 0/, 'and a value that is neither is refused' );
};

subtest 'the per-visitor rate cap still trips, by the hash in a counter no call line joins' => sub {
    my $r = call_it('anon');    # the third call of this visitor on a cap of 2
    is( $r->{kind}, 'rate', 'refused by the cap' ) or diag explain $r;
    like( $r->{error}, qr/per-visitor cap: 2/, 'the per-visitor one' );
    like( slurp("$d/lazysite/odoo/recent.jsonl"), qr/"who":"visitor:\Q$HASH\E"/, 'counted by the hash in recent.jsonl' );
    my ($ref) = grep { ( $_->{outcome} // '' ) eq 'refused' } lines('anon');
    ok( $ref && !exists $ref->{ip} && !exists $ref->{visitor}, 'the refusal line carries neither' );
};

subtest 'a confirmed plan keeps its parameters until it is confirmed, then loses them' => sub {
    my ($k2) = Lazysite::Odoo::Visitor::mint();
    my ( undef, $p ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('anonc');
            Lazysite::Odoo::call( $b, { product => 2 }, mode => 'public', visitor_key => $k2, strict => 1, ip => $IP );
    } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    like( slurp( pdir( $p->{plan} ) . '/plan.json' ), qr/"product"\s*:\s*2/, 'the plan holds the parameter, to apply' );
    my $h2 = Lazysite::Odoo::Visitor::visitor_id($k2);
    is( decode_json( slurp( pdir( $p->{plan} ) . '/meta.json' ) )->{owner}, "visitor:$h2",
        'until it is spent the owner names the visitor, for the confirm to check' );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'public', visitor_key => $k2, ip => $IP ) } );
    ok( $c->{ok} && $c->{applied}, 'the maker\'s confirm still works' ) or diag explain $c;
    is( decode_json( slurp( pdir( $p->{plan} ) . '/meta.json' ) )->{owner}, 'visitor', 'then the owner is visitor alone' );
    my @hc = hashed( $p->{plan}, $h2 );
    is_deeply( \@hc, [], q{and no record of the spent plan names the hash} ) or diag explain \@hc;
    my ( undef, $again ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, mode => 'public', visitor_key => $k2, ip => $IP ) } );
    is( $again->{kind}, 'not-found', 'a spent plan is nobody\'s: a second confirm finds nothing' ) or diag explain $again;
    unlike( slurp( Lazysite::Odoo::calls_file() ), qr/\Q$h2\E/, 'and its refusal line names no hash either' );
    for my $f ( plan_files( $p->{plan} ) ) {
        unlike( slurp($f), qr/"product"\s*:\s*2|"product_id"\s*:\s*2|"qty"\s*:\s*[0-9]/, ( $f =~ m{/([^/]+)\z} )[0] . ' holds no value now' );
    }
    my @l = lines('anonc');
    ok( @l == 2 && !( grep { exists $_->{ip} || exists $_->{visitor} } @l ), 'the plan and apply lines carry neither' )
        or diag explain \@l;
};

subtest 'a binding without the setting records as before' => sub {
    my $r = call_it('named');
    ok( $r->{ok}, 'applied' ) or diag explain $r;
    my ($l) = lines('named');
    is( $l->{ip},      $IP,   'the address' );
    is( $l->{visitor}, $HASH, 'and the hash' );
    like( slurp( pdir( $r->{plan} ) . '/plan.json' ), qr/"product"\s*:\s*1/, 'and the plan keeps its parameters' );
    is( decode_json( slurp( pdir( $r->{plan} ) . '/meta.json' ) )->{owner}, "visitor:$HASH", 'and its owner' );
};

done_testing;
