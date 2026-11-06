#!/usr/bin/perl
# SM1369 X1 (ruling 55): THE HOOK INDEX, AND THE LOADER THAT READS IT.
#
# Enabling, disabling or saving an extension rebuilds lazysite/extensions.index.json
# from the descriptors of the enabled extensions; a hook's function is loaded
# lazily, only from the extension's own payload lib (extensions/<stem>/lib), and
# only while the extension and everything it requires is on - checked again at
# the call (G-1). Each guarantee is driven through the real registry, against a
# real fixture tree whose extensions answer --describe.
#
# No hook kind is live in X1, so the test makes a fixture kind live with `local`;
# the index build runs in this process and sees it.
#
# AND A SITE WITH NO HOOKS IS WHAT IT WAS: an enable, a disable and a save of an
# extension that declares none write no index and answer exactly the keys they
# answered before.
#
# Sabotage: take the enabled check out of call_hook and the "an index left
# behind" case runs a disabled extension's code - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Extensions qw(action_extension_enable action_extension_disable
    action_extension_save extension_enabled);
use Lazysite::Extensions::Hooks qw(call_hook read_index);

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; return scalar <$fh> }

# A descriptor whose --describe prints $desc as JSON.
sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

my ( $M, $N ) = ( '', 0 );
my $KIND = { hook => 'test', slice => 'X1', live => 1, form => 'functions' };

sub fixture {
    $M = 'Probe' . ++$N;
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/web";
    make_path( "$d/lazysite", "$base/extensions/probe/lib/${M}" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    write_extension( "$base/extensions/probe.pl", {
            id => 'probe', name => 'Probe', contract => 1,
            config_file => 'lazysite/probe.conf', config_schema => [ { key => 'note', label => 'Note', type => 'text' } ],
            owns => { hooks => { fixture_kind => [ "${M}::Hooks::answer", "${M}::Hooks::boom" ] } } } );
    spit( "$base/extensions/probe/lib/${M}/Hooks.pm",
        "package ${M}::Hooks;\nsub answer { return 'answer:' . join ',', \@_ }\n"
            . "sub boom { die \"boom\\n\" }\nsub hidden { return 'hidden' }\n1;\n" );
    write_extension( "$base/extensions/plain.pl", {
            id => 'plain', name => 'Plain', contract => 1,
            config_file => 'lazysite/plain.conf', config_schema => [ { key => 'note', label => 'Note', type => 'text' } ] } );
    $Lazysite::Manager::Extensions::DOCROOT = $d;
    return ( $base, $d );
}

sub index_file { return "$_[0]/lazysite/extensions.index.json" }

subtest 'a site with no hooks: no index, and the same answers' => sub {
    my ( $base, $d ) = fixture();
    my $r = action_extension_enable('extensions/plain.pl');
    is_deeply( [ sort keys %$r ], [qw(action ok script)], 'enable answers what it answered before' );
    ok( !-e index_file($d), 'no index is written' );
    $r = action_extension_save( 'plain', 'extensions/plain.pl', { note => 'x' } );
    is_deeply( [ sort keys %$r ], [qw(changed ok)], 'a save answers what it answered before' );
    $r = action_extension_disable('extensions/plain.pl');
    is_deeply( [ sort keys %$r ], [qw(action ok script)], 'disable answers what it answered before' );
    ok( !-e index_file($d), 'still no index' );
};

subtest 'enabled, the hooks are indexed and the declared function runs from the payload' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    my $r = action_extension_enable('extensions/probe.pl');
    ok( $r->{ok}, 'enabled' ) or diag explain $r;
    is_deeply( $r->{index}{indexed}, ['probe'], 'the response says it was indexed' );
    my $idx = decode_json( slurp( index_file($d) ) );
    is( $idx->{format},                 1, 'the index has its format' );
    is( $idx->{extensions}{probe}{key}, 'extensions/probe.pl', 'keyed by the registry key' );
    is_deeply( $idx->{extensions}{probe}{functions}, [ "${M}::Hooks::answer", "${M}::Hooks::boom" ],
        'with the functions it declares' );

    my ( $ok, @out ) = call_hook( $d, 'probe', "${M}::Hooks::answer", 'a', 'b' );
    ok( $ok, 'the hook ran' ) or diag "@out";
    is( $out[0], 'answer:a,b', 'with the arguments core passed' );
    like( $INC{"$M/Hooks.pm"}, qr{/extensions/probe/lib/${M}/Hooks\.pm\z}, 'loaded from the payload lib' );
    is( scalar( grep { !ref && $_ eq "$base/extensions/probe/lib" } @INC ), 1, 'which is on @INC once' );
    isnt( $INC[0], "$base/extensions/probe/lib", 'appended, not prepended' );

    ( $ok, my $why ) = call_hook( $d, 'probe', "${M}::Hooks::hidden" );
    ok( !$ok, 'a function the declaration does not name is refused' );
    like( $why, qr/not a function the extension 'probe' declares/, 'and says so' );

    ( $ok, $why ) = call_hook( $d, 'probe', "${M}::Hooks::boom" );
    ok( !$ok, 'a hook that dies fails closed' );
    like( $why, qr/died/, 'with its reason, not an exception' );

    ( $ok, $why ) = call_hook( $d, 'nobody', "${M}::Hooks::answer" );
    ok( !$ok, 'an extension with no index entry runs nothing' );

    $r = action_extension_disable('extensions/probe.pl');
    ok( !-e index_file($d), 'disabled, the last hooks leave and the index goes' );
    ( $ok, $why ) = call_hook( $d, 'probe', "${M}::Hooks::answer" );
    ok( !$ok, 'and the hook no longer runs' );
};

subtest 'an index left behind by a failed write cannot run a disabled extension' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    action_extension_enable('extensions/probe.pl');
    ok( -e index_file($d), 'indexed' );
    # The conf loses the entry and the index does not hear of it.
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    ok( !extension_enabled('extensions/probe.pl'),             'the extension is off' );
    ok( exists read_index("$d/lazysite")->{extensions}{probe}, 'and the stale index still lists it' );
    my ( $ok, $why ) = call_hook( $d, 'probe', "${M}::Hooks::answer" );
    ok( !$ok, 'the call is refused' );
    like( $why, qr/is off/, 'because the extension is off now' );
};

subtest 'an index whose payload lib does not match is stale and runs nothing' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    action_extension_enable('extensions/probe.pl');
    my $idx = decode_json( slurp( index_file($d) ) );
    $idx->{extensions}{probe}{lib} = '/tmp/elsewhere/lib';
    spit( index_file($d) . '.new', JSON::PP->new->encode($idx) );
    rename index_file($d) . '.new', index_file($d) or die $!;
    my ( $ok, $why ) = call_hook( $d, 'probe', "${M}::Hooks::answer" );
    ok( !$ok, 'refused' );
    like( $why, qr/stale/, 'as stale' );
};

subtest 'a declaration that would not be indexed is not enabled' => sub {
    my ( $base, $d ) = fixture();
    my $r = action_extension_enable('extensions/probe.pl');
    ok( !$r->{ok}, 'a hook that is not built yet: refused' );
    is( $r->{kind}, 'descriptor', 'as a fault in the descriptor' );
    like( $r->{error}, qr/fixture_kind/, 'naming the hook' );
    ok( !extension_enabled('extensions/probe.pl'), 'and the conf is unchanged' );
    ok( !-e index_file($d),                        'nothing is indexed' );
};

subtest 'a hook module must be the extension\'s own' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;

    # Naming core's code: a module that resolves outside the payload.
    write_extension( "$base/extensions/probe.pl", { id => 'probe', name => 'Probe', contract => 1,
            owns => { hooks => { fixture_kind => ['Lazysite::Paths::lazysite_dir'] } } } );
    make_path("$base/extensions/probe/lib/Lazysite");
    spit( "$base/extensions/probe/lib/Lazysite/Paths.pm", "package Lazysite::Paths;\n1;\n" );
    my $r = action_extension_enable('extensions/probe.pl');
    ok( !$r->{ok}, 'a module that shadows core is refused' );
    like( $r->{error}, qr/also found outside the extension/, 'and says why' );

    # A module the payload does not have.
    write_extension( "$base/extensions/probe.pl", { id => 'probe', name => 'Probe', contract => 1,
            owns => { hooks => { fixture_kind => ['Probe::Absent::f'] } } } );
    $r = action_extension_enable('extensions/probe.pl');
    ok( !$r->{ok}, 'a module the payload lacks is refused' );
    like( $r->{error}, qr/not a file in the extension's payload lib/, 'and says why' );
};

subtest 'a payload reached through a link is not the extension\'s' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    my $elsewhere = tempdir( CLEANUP => 1 );
    rename "$base/extensions/probe", "$elsewhere/probe" or die $!;
    symlink "$elsewhere/probe", "$base/extensions/probe" or die $!;
    my $r = action_extension_enable('extensions/probe.pl');
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/no payload lib/, 'there is no payload lib' );
};

subtest 'requires: enabling while the extension it builds on is off is refused by name' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    write_extension( "$base/extensions/kit.pl", { id => 'kit', name => 'Kit', contract => 1,
            owns => { requires => ['probe'] } } );
    my $r = action_extension_enable('extensions/kit.pl');
    ok( !$r->{ok}, 'refused while probe is off' );
    is( $r->{kind}, 'refused', 'as a refusal' );
    like( $r->{error}, qr/requires the extension 'probe', which is not enabled/, 'naming it' );
    like( $r->{audit_detail}, qr/requires_off: probe/, 'and the audit says which' );
    ok( !extension_enabled('extensions/kit.pl'), 'the conf is unchanged' );

    ok( action_extension_enable('extensions/probe.pl')->{ok}, 'probe on' );
    ok( action_extension_enable('extensions/kit.pl')->{ok},   'then kit enables' );
};

subtest 'requires: a hook stops when the extension it requires goes off' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    make_path("$base/extensions/kit/lib/Kit");
    spit( "$base/extensions/kit/lib/Kit/Hooks.pm", "package Kit::Hooks;\nsub hello { return 'kit' }\n1;\n" );
    write_extension( "$base/extensions/kit.pl", { id => 'kit', name => 'Kit', contract => 1,
            owns => { requires => ['probe'], hooks => { fixture_kind => ['Kit::Hooks::hello'] } } } );
    ok( action_extension_enable('extensions/probe.pl')->{ok}, 'probe on' );
    my $r = action_extension_enable('extensions/kit.pl');
    is_deeply( $r->{index}{indexed}, [qw(kit probe)], 'both indexed' );
    my ( $ok, @out ) = call_hook( $d, 'kit', 'Kit::Hooks::hello' );
    ok( $ok, 'kit\'s hook runs' );

    # Off by the conf alone: the call checks what kit requires.
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nextensions:\n  - extensions/kit.pl\n" );
    ( $ok, my $why ) = call_hook( $d, 'kit', 'Kit::Hooks::hello' );
    ok( !$ok, 'with probe off it does not' );
    like( $why, qr/requires extensions\/probe\.pl, which is off/, 'and says why' );

    # And a rebuild leaves kit out, naming why.
    $r = Lazysite::Manager::Extensions::rebuild_hook_index();
    is_deeply( $r->{indexed}, [], 'a rebuild indexes nothing' );
    like( $r->{refused}[0]{problems}[0], qr/requires the extension 'probe'/, 'and names kit\'s reason' );
    ok( !-e index_file($d), 'so there is no index' );
};

subtest 'a save rebuilds the index of an enabled extension' => sub {
    my ( $base, $d ) = fixture();
    local $Lazysite::Extensions::Hooks::KINDS{fixture_kind} = $KIND;
    action_extension_enable('extensions/probe.pl');
    unlink index_file($d) or die $!;
    my $r = action_extension_save( 'probe', 'extensions/probe.pl', { note => 'x' } );
    is_deeply( $r->{index}{indexed}, ['probe'], 'the save says it rebuilt the index' );
    ok( -e index_file($d), 'and the index is back' );
};

done_testing();
