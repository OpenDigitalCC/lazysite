#!/usr/bin/perl
# SM447 / ADR 0009: the plugin's `owns` declaration is asserted against the
# code, not merely present.
#
# THE WHOLE POINT OF THE CONTRACT is that the platform CONSUMES the
# declaration instead of knowing about the plugin by name: backup and site
# packages read `storage`, the SBOM gate reads `deps`, the capability lints
# discover `capabilities`. Every one of those consumers trusts the list. A
# declaration nothing checks is a comment with punctuation - and worse than a
# comment, because the platform acts on it.
#
# The failure it prevents is specific and has already happened once, as SM410
# finding B: a plugin's data directory carried by one backup kind and silently
# dropped by another, because each learned about plugin-owned assets
# separately. A wrong `storage` line reintroduces exactly that, and the symptom
# is a restored site missing data nobody notices until they look for it.
#
# ADR 0009 says a clause that survives the data plugin is proven rather than
# speculative. This is what surviving means.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin;

my $root   = "$FindBin::Bin/../../..";
my $plugin = "$root/plugins/data.pl";
plan skip_all => 'plugin not present' unless -f $plugin;

my $d = eval { decode_json(`$^X \Q$plugin\E --describe`) };
ok( ref $d eq 'HASH', '--describe returns JSON' ) or BAIL_OUT($@);

subtest 'it describes itself even with no Lazysite tree' => sub {
    # A plugin that cannot describe itself cannot be listed, and an operator
    # sees it MISSING rather than broken - so the module lookup is deferred
    # and this is the assertion that keeps it deferred.
    my $out = `$^X \Q$plugin\E --describe 2>&1`;
    ok( $out =~ /^\{/, 'output is JSON, not a load error' );
    is( $?, 0, 'and it exits cleanly' );
};

my $owns = $d->{owns};
ok( ref $owns eq 'HASH', 'it carries an owns declaration' ) or BAIL_OUT('no owns');

subtest 'config_keys names exactly what config_schema offers' => sub {
    my @schema = sort map { $_->{key} } @{ $d->{config_schema} || [] };
    my @owned  = sort @{ $owns->{config_keys} || [] };
    is_deeply( \@owned, \@schema,
        'the two lists agree' )
        or diag( 'One is what the operator is shown and the other is what the '
            . 'platform treats as this plugin\'s. A key in one and not the '
            . 'other is either an unsettable setting or an unowned key.' );
};

subtest 'deps names every non-core module the data code loads' => sub {
    # Read from the modules themselves. The SBOM gate greps the code and
    # demands every module it finds is declared, so a list that drifts from
    # the code fails the RELEASE - which is the most expensive place to find
    # it.
    my %found;
    for my $f ( glob "$root/lib/Lazysite/Data/*.pm" ) {
        open my $fh, '<', $f or next;
        while ( my $l = <$fh> ) {
            next if $l =~ /^\s*#/;
            $found{$1} = 1 if $l =~ /^\s*(?:use|require)\s+([A-Z][\w:]+)/;
        }
        close $fh;
    }
    delete $found{$_} for grep { /^Lazysite::/ } keys %found;
    delete $found{$_} for qw(strict warnings);

    # WHICH MODULES ARE CORE IS READ FROM sbom-deps.json, not from a list
    # written here. A hand-list in a test is a fourth opinion about the
    # dependency set, and the gate reads the file - so the file decides.
    my $sbom = decode_json( do {
        open my $fh, '<', "$root/dist/config/sbom-deps.json" or die $!;
        local $/; <$fh>;
    } );
    my $mods = $sbom->{modules} || {};

    my %declared = map { $_ => 1 } @{ $owns->{deps} || [] };
    for my $m ( sort keys %found ) {
        ok( $mods->{$m},
            "$m is in sbom-deps.json" )
            or diag( "lib/Lazysite/Data/ loads $m and nothing declares it. "
                . 'The SBOM gate greps the code and demands every module it '
                . 'finds is listed, so this fails the RELEASE - the most '
                . 'expensive place to find it.' );
        next if $mods->{$m} && $mods->{$m}{core};
        ok( $declared{$m}, "$m is declared in the plugin's deps" )
            or diag( "$m is not core, so it is this plugin's to declare." );
    }
    # The engine modules are used through Connect/SQLite and must be declared
    # even though the loop above removes them from the grep set.
    ok( $declared{$_}, "$_ is declared" ) for qw(DBI DBD::SQLite);
    ok( $declared{'YAML::PP'}, 'YAML::PP is declared' );
};

subtest 'storage names the directory the store actually lives in' => sub {
    my @storage = @{ $owns->{storage} || [] };
    ok( scalar @storage, 'storage is declared' );

    # Against the adapter's own answer, not a repeated string. dsn_for is what
    # decides where the file goes, so it is what this must agree with.
    require "$root/lib/Lazysite/Data/SQLite.pm";
    my $dsn = Lazysite::Data::SQLite::dsn_for('/DOCROOT');
    like( $dsn, qr{/DOCROOT/lazysite/db/}, 'the adapter puts the store there' );

    my ($declared) = grep { index( "lazysite/db/data.sqlite", $_ ) == 0 } @storage;
    ok( $declared, 'and the declaration covers that path' )
        or diag( "dsn_for says $dsn; storage says @storage. Backup and site "
            . 'packages read the DECLARATION, so a site restored from a '
            . 'package would arrive without its data - SM410 finding B, '
            . 'reintroduced.' );
};

subtest 'capabilities names one, and it is MIRRORED not duplicated' => sub {
    my @caps = @{ $owns->{capabilities} || [] };
    is_deeply( \@caps, ['manage_data'], 'exactly manage_data' );

    # THIS ASSERTION USED TO SAY THE OPPOSITE, and the change is deliberate.
    # It required manage_data NOT to be in @CAP_KEYS, on the reasoning that two
    # owners of one capability is the ambiguity ADR 0009 removes. That is
    # right about OWNERSHIP and wrong about the LIST: caps_for() is on every
    # request and cannot run ten plugins to discover names, so the runtime
    # keeps a static mirror.
    #
    # The plugin stays the owner. t/lint/76 discovers the declarations and
    # refuses a mirror with no owner, or one claimed twice - which is where the
    # ambiguity is actually prevented.
    require "$root/lib/Lazysite/Auth/Settings.pm";
    my %key = map { $_ => 1 } @Lazysite::Auth::Settings::CAP_KEYS;
    ok( $key{'manage_data'},
        'manage_data is grantable, so the declaration can take effect' )
        or diag( 'A capability nobody can be granted leaves the plugin\'s '
            . 'actions unreachable, with nothing saying why.' );
};

subtest 'status reports and does not repair' => sub {
    use File::Temp qw(tempdir);
    my $dir = tempdir( CLEANUP => 1 );
    my $out = decode_json(`$^X \Q$plugin\E --action status --docroot \Q$dir\E`);
    ok( $out->{ok}, 'status answers on an empty docroot' );
    is( $out->{store}{exists}, 0, 'and reports no store' );
    ok( !-e "$dir/lazysite/db/data.sqlite",
        'having created nothing' )
        or diag( 'A status check that changes what it reports on is the shape '
            . 'this programme keeps having to undo.' );
    is_deeply( $out->{tables}, [], 'and no tables' );
};

done_testing();
