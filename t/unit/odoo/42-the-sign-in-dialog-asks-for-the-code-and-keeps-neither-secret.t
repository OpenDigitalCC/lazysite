#!/usr/bin/perl
# SM1157 (L4): the browser half of Odoo's two-factor step. The helper's sign-in
# dialog is driven under node with a stand-in DOM and a fake fetch
# (t/lib/odoo-prompt-harness.js). What is held:
#
#   * a password answered { second_factor: 'totp' } turns the dialog into the code
#     step: no password box, a one-time-code box, and "don't ask again on this
#     device" only when the server said it is offered;
#   * the code box is cleared before the answer arrives, as the password's is, and
#     the code is in the body of its own POST and no other;
#   * a wrong code says so in the dialog and the person may try again - the script
#     never loops for them;
#   * a sign-in that has run out sends the person back to the password;
#   * cancelling the code step ends the half-open sign-in (a signout POST) and the
#     dialog resolves false;
#   * an account without two-factor signs in as it always did.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $asset = "$root/starter/assets/lazysite-odoo.js";
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node is not installed' unless length $node && -x $node;

my $out = `$node "$root/t/lib/odoo-prompt-harness.js" "$asset" 2>&1`;
my $f   = eval { decode_json($out) };
ok( $f && !$f->{error}, 'the dialog harness ran' ) or BAIL_OUT("harness: $out");

subtest 'the password step turns into the code step' => sub {
    my $s = $f->{step};
    is( $s->{one_form},           1,               'one form is showing' );
    ok( $s->{has_code},                            'a code box' );
    ok( !$s->{has_password},                       'and no password box' );
    is( $s->{code_autocomplete}, 'one-time-code',  'a code box a phone can fill from a message' );
    is( $s->{code_inputmode},    'numeric',        'with the numeric keypad' );
    ok( $s->{has_remember},                        'remember is shown when the server offered it' );
    is( $s->{remember_type},     'checkbox',       'as a checkbox' );
    is( $s->{remember_label_for}, 'ls-odoo-remember', 'with its label' );
    like( $s->{remember_label}, qr/Don't ask again on this device/, 'in Odoo\'s own words' );
    ok( $s->{open},                                'the dialog is still open: this is not a sign-in yet' );
};

subtest 'remember is not shown when the server did not offer it' => sub {
    ok( $f->{no_remember}{has_code},      'the code box is' );
    ok( !$f->{no_remember}{has_remember}, 'the checkbox is not' );
};

subtest 'a wrong code is said, and the person tries again; the right one signs in' => sub {
    ok( $f->{code_cleared_before_answer}, 'the code box is cleared before the answer arrives' );
    like( $f->{wrong}{msg}, qr/did not accept that code/, 'the wrong code is said in the dialog' );
    ok( $f->{wrong}{still_open},      'the dialog stays open' );
    ok( $f->{wrong}{form_still_there}, 'at the same code step' );
    is( $f->{wrong}{code_box}, '',     'with the code gone' );
    ok( $f->{right}{result},           'the right code resolves the dialog true' );
    ok( $f->{right}{closed},           'and closes it' );
    is( $f->{requests}, 4, 'one token fetch and three posts: the script asked once per person action, never on its own' );
};

subtest 'the password and the code are each in one POST and no other' => sub {
    my @p = @{ $f->{posts} };
    is( scalar @p, 3, 'three posts' );
    ok( $p[0]{signin} && !$p[0]{signin_code}, 'the first is the password' );
    ok( $p[1]{signin_code} && !exists $p[1]{password}, 'the second is a code and carries no password' );
    is( $p[1]{remember}, JSON::PP::true, 'the ticked box is sent as remember true' );
    is( $p[2]{remember}, JSON::PP::false, 'and the unticked as false' );
    my @raw = @{ $f->{raws} };
    like( $raw[0], qr/Sup3r-secret-pw/, 'the password is in the first body' );
    unlike( $raw[1] . $raw[2], qr/Sup3r-secret-pw/, 'and not in the code posts' );
    unlike( $raw[0] . $raw[2], qr/111111/, 'the first code is in its own post only' );
    unlike( $raw[0] . $raw[1], qr/222222/, 'and the second in its own' );
};

subtest 'a sign-in that has run out goes back to the password' => sub {
    my $l = $f->{lapsed};
    ok( $l->{open},         'the dialog is open' );
    is( $l->{forms}, 1,     'one form' );
    ok( $l->{has_password}, 'it is the password form again' );
    ok( !$l->{has_code},    'not the code' );
    like( $l->{msg}, qr/run out/, 'saying so' );
};

subtest 'cancelling the code step ends the half-open sign-in' => sub {
    my $c = $f->{cancel};
    is( $c->{result}, JSON::PP::false, 'the dialog resolves false' );
    ok( $c->{closed},  'and closes' );
    ok( $c->{signout}, 'a signout was posted so Odoo is not left holding it' );
    ok( !$c->{code_sent}, 'and no code was sent' );
};

subtest 'an account without two-factor signs in as before' => sub {
    ok( $f->{plain}{result},     'resolved true' );
    ok( $f->{plain}{closed},     'closed' );
    is( $f->{plain}{posts}, 1,   'after one post' );
};

done_testing();
