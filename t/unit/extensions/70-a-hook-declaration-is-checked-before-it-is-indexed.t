#!/usr/bin/perl
# SM1369 X1 (ruling 55): A HOOK DECLARATION IS CHECKED BEFORE ANYTHING IS INDEXED.
#
# An extension's `owns.hooks` and `owns.requires` are validated by
# Lazysite::Extensions::Hooks, through Owns::validate_owns, before the index is
# built from them. An unknown hook is refused by name. So is a hook this engine
# does not call yet: X1 wires no hook, and a declaration nothing calls would read
# as working. A function a hook names is a fully qualified Perl name, never one
# Perl or core resolves by itself.
#
# The live-kind cases make a fixture kind live for the test (`local`), because
# no real kind is live until its slice lands.
#
# Sabotage: drop the `live` test in validate_hooks and the not-built case passes
# a declaration through - this fails.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Extensions::Owns qw(validate_owns);
use Lazysite::Extensions::Hooks qw(validate_hooks validate_requires hook_functions hook_kinds);

sub errors { return [ map { $_->{error} } @_ ] }

subtest 'an unknown hook is refused by name' => sub {
    my $e = errors( validate_hooks( 'x', { identity_providr => {} } ) );
    is( scalar @$e, 1, 'one problem' );
    like( $e->[0], qr/unknown hook 'identity_providr'/, 'naming the key' );
    like( $e->[0], qr/identity_provider/,               'and listing the known ones' );
};

subtest 'a known hook this engine does not call yet is refused, naming its slice' => sub {
    # SM1369 X2: three kinds are live (capability_info, api_actions,
    # refusal_kinds); their rules are t/unit/extensions/72's. X3 adds two
    # (page_sources, handler_types); X5 three (assets, components, template_vars,
    # H-10). The rest are refused as X1 refused them all.
    my @live = grep { $Lazysite::Extensions::Hooks::KINDS{$_}{live} } hook_kinds();
    is_deeply( \@live,
        [qw(api_actions assets capability_info checks components endpoints handler_types identity_provider page_sources panels refusal_kinds services template_vars)],
        'the live kinds are X2\'s three, X3\'s two, X4\'s one, X5\'s five and X6\'s two (n782: H-4, H-5, H-6, H-8)' );
    for my $k ( grep { !$Lazysite::Extensions::Hooks::KINDS{$_}{live} } hook_kinds() ) {
        my $e = errors( validate_hooks( 'x', { $k => [] } ) );
        is( scalar @$e, 1, "$k: refused" );
        like( $e->[0], qr/not built in this engine yet - it lands in slice X[3-8]/, "$k: naming the slice" );
    }
};

subtest 'hooks must be a mapping, and Owns says so' => sub {
    like( errors( validate_owns( 'x', { hooks => [] } ) )->[0], qr/hooks must be a mapping/, 'a list is refused' );
    is_deeply( errors( validate_owns( 'x', { deps => ['JSON::PP'] } ) ), [], 'a declaration without hooks is as it was' );
    like( errors( validate_owns( 'x', { hooks => { nope => 1 } } ) )->[0], qr/unknown hook 'nope'/,
        'Owns reads the hook rules' );
};

subtest 'a live kind: its functions are fully qualified names an extension may call' => sub {
    local $Lazysite::Extensions::Hooks::KINDS{fixture_list}
        = { hook => 'test', slice => 'X1', live => 1, form => 'functions' };
    is_deeply( errors( validate_hooks( 'x', { fixture_list => [ 'Probe::Hooks::answer', 'A::b_c' ] } ) ), [],
        'two good names pass' );
    for my $bad ( 'answer', 'main::answer', 'CORE::exit', 'UNIVERSAL::isa', 'Probe::Hooks::import',
        'Probe::Hooks::DESTROY', "Probe'Hooks::answer", 'Probe::Hooks::Answer', '::answer', [] )
    {
        my $e = errors( validate_hooks( 'x', { fixture_list => [$bad] } ) );
        is( scalar @$e, 1, 'refused: ' . ( ref $bad ? 'a reference' : $bad ) );
    }
    like( errors( validate_hooks( 'x', { fixture_list => 'Probe::Hooks::answer' } ) )->[0],
        qr/must be a list of function names/, 'a bare string is not a list' );
    is_deeply( [ hook_functions( { fixture_list => [ 'B::y', 'A::x', 'B::y' ] } ) ], [ 'A::x', 'B::y' ],
        'the functions a declaration names, once each' );
};

subtest 'a live record kind: known keys only, plain fields, required keys' => sub {
    local $Lazysite::Extensions::Hooks::KINDS{fixture_rec} = { hook => 'test', slice => 'X1', live => 1,
        form => 'records', functions => [qw(run)], fields => [qw(name label)], required => [qw(name run)] };
    is_deeply( errors( validate_hooks( 'x', { fixture_rec => [ { name => 'a', run => 'P::run_it' } ] } ) ), [],
        'a sound record passes' );
    my $e = errors( validate_hooks( 'x', { fixture_rec => [ { name => 'a', run => 'P::run_it', extra => 1 } ] } ) );
    like( $e->[0], qr/unknown key 'extra'/, 'an unknown key is refused' );
    $e = errors( validate_hooks( 'x', { fixture_rec => [ { run => 'P::run_it' } ] } ) );
    like( $e->[0], qr/must carry 'name'/, 'a required key is required' );
    $e = errors( validate_hooks( 'x', { fixture_rec => [ { name => [], run => 'P::run_it' } ] } ) );
    like( $e->[0], qr/name must be a plain value/, 'a field is a plain value' );
    $e = errors( validate_hooks( 'x', { fixture_rec => [ { name => 'a', run => 'main::system' } ] } ) );
    like( $e->[0], qr/run names no function/, 'a function key holds a function name' );
    is_deeply( [ hook_functions( { fixture_rec => [ { name => 'a', run => 'P::run_it' } ] } ) ], ['P::run_it'],
        'the record\'s function is collected' );
};

subtest 'requires names other extensions by id' => sub {
    is_deeply( errors( validate_requires( 'kit', ['odoo'] ) ), [], 'one id passes' );
    like( errors( validate_requires( 'kit', 'odoo' ) )->[0], qr/must be a list/, 'a list' );
    like( errors( validate_requires( 'kit', ['kit'] ) )->[0], qr/cannot require itself/, 'not itself' );
    like( errors( validate_requires( 'kit', [ 'a', 'a' ] ) )->[0], qr/listed twice/, 'once each' );
    like( errors( validate_requires( 'kit', ['../x'] ) )->[0], qr/must be an extension id/, 'an id, not a path' );
    like( errors( validate_owns( 'kit', { requires => ['Kit'] } ) )->[0], qr/must be an extension id/,
        'Owns reads the requires rule' );
};

done_testing();
