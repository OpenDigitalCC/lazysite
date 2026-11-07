#!/usr/bin/perl
# SM1396 (ruling 53): THE OFFLINE KIT'S WRITE GUARD SENDS A QUEUED CHANGE ONCE,
# AND WHAT IT KEEPS IS OWNED BY LOGIN.
#
# extensions/app-offline/assets/kit.js, run under node on top of the real Odoo
# browser helper, against an endpoint stand-in listening on 127.0.0.1 that
# records every request and its Idempotency-Key (t/lib/app-offline-kit-harness.js):
#
#   * offline, a change is queued (answered `queued` with its key), nothing is
#     sent; the signal back - fired twice over - sends each queued change once,
#     in order, with its own key;
#   * a send that is cut off keeps the change with its key, and the next flush
#     sends it again with the SAME key: the resend the server makes safe;
#   * with nobody signed in a change is refused (`no-owner`), queued nowhere;
#   * a change queued by one login is not sent while another is signed in on
#     the same browser, and stays the first login's;
#   * online, a change goes at once, once, with the key the page gave;
#   * a read's last good answer is kept and answered when the network is gone,
#     marked kept, for the same read and the same owner alone;
#   * signing out drops what was kept for the person; their queued change waits;
#   * the store holds no token.
#
# Sabotage: drop the `flushing` guard from API.flush and the two `online` events
# send each change twice - this fails on posts.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);

my $root   = repo_root();
my $helper = "$root/extensions/odoo/assets/lazysite-odoo.js";
my $kit    = "$root/extensions/app-offline/assets/kit.js";
ok( -f $kit, 'the kit is the extension\'s own asset' ) or BAIL_OUT('extensions/app-offline/assets/kit.js is missing');
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
plan skip_all => 'node is not installed' unless length $node && -x $node;

my $r   = run_child( [ $node, "$root/t/lib/app-offline-kit-harness.js", $helper, $kit ], stderr => 'merge', timeout => 60 );
my $out = $r->{out} // '';
my $f   = eval { decode_json($out) };
ok( $f && !$f->{error}, 'the harness ran against its 127.0.0.1 endpoint' ) or BAIL_OUT( "harness: " . ( $f->{error} // $out ) );

is( $f->{owner_learnt}, 'signin:0123456789abcdef', 'the owner is learnt from the endpoint\'s label, never a login' );

subtest 'offline: queued; the signal back, twice over, sends each change once' => sub {
    my $q = $f->{queue};
    is( $q->{r1}, 'queued', 'the first change is queued' );
    is( $q->{r2}, 'queued', 'and the second' );
    is( $q->{queued_answer_status}, 0, 'a queued answer has no HTTP status: nothing was asked' );
    ok( $q->{keys_differ}, 'each with a key of its own' );
    is( $q->{posted_before_online}, 0, 'nothing was sent while offline' );
    is( $q->{posts}, 2, 'two POSTs for two changes, with two online events' );
    is_deeply( $q->{keys}, $q->{expected}, 'in order, each carrying its own Idempotency-Key' );
    is_deeply( $q->{bindings}, [ 'basket', 'basket' ], 'each the binding it named' );
    is( $q->{queue_after}, 0, 'and the queue is empty' );
};

subtest 'cut off mid-send: kept with its key, sent again with the same key' => sub {
    my $c = $f->{cut_off};
    is( $c->{answer}, 'queued', 'no answer came, so the change is queued' );
    is( $c->{cut_posts}, 1, 'the cut-off send reached the wire once' );
    is_deeply( $c->{cut_answered}, [ JSON::PP::false ], '...and was not answered' );
    is( $c->{posts}, 2, 'the next flush sends it once more' );
    is( $c->{keys}[0], $c->{key}, 'with the key the page was told' );
    is( $c->{keys}[1], $c->{key}, 'the SAME key the first time: the server does not write twice' );
    is( $c->{queue_after}, 0, 'and it leaves the queue once answered' );
};

subtest 'nobody signed in: refused, queued nowhere' => sub {
    is( $f->{no_owner}{answer}, 'no-owner', 'refused by kind' );
    is( $f->{no_owner}{posts}, 0, 'not sent' );
    is_deeply( $f->{no_owner}{owners}, [], 'and kept for nobody' );
};

# Rulings 161, 163: on a default Odoo site (the site sign-in off) ?csrf=1 names
# the person and no owner (t/unit/odoo/41 holds the endpoint's half); the kit
# then keeps nothing and sends nothing kept.
subtest 'a default Odoo site: signed in, no owner, nothing kept' => sub {
    my $s = $f->{default_site};
    is( $s->{owner}, undef, 'no owner is learnt from an answer that names none' );
    is( $s->{offline}, 'no-owner', 'a change made offline is refused by kind' );
    is( $s->{online},  'no-owner', 'and one made online' );
    is( $s->{posts},   0,          'neither is sent' );
    is( $s->{queued},  0,          'nor queued' );
    is( $s->{live_status}, 200, 'a read is answered live' );
    is( $s->{kept_read}, 'rejected', 'and is not kept for when the network is gone' );
    is_deeply( $s->{owners}, [], 'the store keeps nothing for anybody' );
};

subtest 'another login on the same browser' => sub {
    my $o = $f->{other_login};
    is( $o->{queued}, 'queued', 'the first login\'s change was queued' );
    is( $o->{owner_now}, 'signin:fedcba9876543210', 'the second is signed in now' );
    is( $o->{posts}, 0, 'the first\'s change is not sent as the second' );
    is( $o->{a_queue}, 1, 'it stays the first login\'s' );
    is( $o->{b_queue}, 0, 'the second has none' );
    is( $o->{b_visible_queue}, 0, 'and sees none' );
};

subtest 'online: at once, once, with the page\'s key' => sub {
    my $o = $f->{online};
    is( $o->{status}, 200, 'answered' );
    ok( $o->{planned}, 'with the endpoint\'s answer' );
    is( $o->{posts}, 1, 'one POST' );
    is( $o->{key}, 'page-gave-this-key', 'carrying the key the page gave' );
    is( $o->{queue_after}, 0, 'and nothing queued' );
};

subtest 'kept reads: the last good answer, for the same read and owner alone' => sub {
    my $k = $f->{kept};
    is( $k->{live_status}, 200, 'a live read answers' );
    ok( !$k->{live_kept}, '...not marked kept' );
    is( $k->{kept_status}, 200, 'the network gone, the same read answers' );
    ok( $k->{kept_flag} && $k->{kept_marked}, '...marked kept, in the answer and in its data' );
    is( $k->{kept_rows}, 'Widget', '...with the rows it kept' );
    is( $k->{kept_at}, 'string', '...and when' );
    is( $k->{other_read}, 'rejected', 'a read never made is not invented' );
    is( $k->{other_owner}, 'rejected', 'another login finds nothing of the first\'s' );
};

subtest 'signing out' => sub {
    my $s = $f->{signout};
    is( $s->{reads_before}, 1, 'a kept read' );
    is( $s->{queue_before}, 1, 'and a queued change, before' );
    is( $s->{reads_after}, 0, 'the kept read goes with the sign-out' );
    is( $s->{queue_after}, 1, 'the queued change waits for the person' );
    is( $s->{owner_after}, undef, 'and nobody owns the page now' );
};

ok( !$f->{store_text}{has_token}, 'the store holds no token' );

done_testing;
