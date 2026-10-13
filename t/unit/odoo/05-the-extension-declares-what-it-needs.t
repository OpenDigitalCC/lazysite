#!/usr/bin/perl
# SM747 / OB7 / R3: the extension declares OOM as `libodoo-oom-perl (>= 0.03)`
# and the enable path refuses it by NAME when OOM is absent or older - telling
# the operator the package that exists, not one guessed from a module name.
#
# The guess would have been libodoo-ops-perl, which does not exist: OOM ships
# many modules under one package, which is the case the declaration's
# (package >= version) form is for.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper              qw(repo_root site_tempdir run_cmd);
use OdooTest                qw(oom_lib);
use Lazysite::Plugins::Owns qw(validate_owns parse_dep);

my $root   = repo_root();
my $plugin = "$root/plugins/odoo.pl";
my $d      = eval { decode_json( scalar run_cmd( $^X, $plugin, '--describe' ) ) };
ok( ref $d eq 'HASH', '--describe answers JSON' ) or BAIL_OUT('no descriptor');

subtest 'the declaration is sound' => sub {
    is_deeply( [ validate_owns( $d->{id}, $d->{owns} ) ], [], 'owns validates' );
    is_deeply( [ sort @{ $d->{owns}{config_keys} } ],
        [ sort map { $_->{key} } @{ $d->{config_schema} } ],
        'config_keys names exactly what config_schema offers' );
    ok( $d->{contract}, 'a contract extension: born disabled, executes only while listed' );
    ok( !exists $d->{owns}{storage},
        'no storage is declared - the store holds the connection user\'s key' );
};

subtest 'the dep grammar' => sub {
    is_deeply( [ parse_dep( $d->{owns}{deps}[0] ) ], [ q{Odoo::Ops}, q{libodoo-oom-perl}, q{0.03} ],
        'the extension declares the module, its package and the oldest version' );
    is_deeply( [ parse_dep('YAML::PP') ], ['YAML::PP'], 'a bare module is still a dep' );
    for my $bad ( 'Odoo::Ops (libodoo-oom-perl)', 'Odoo::Ops libodoo-oom-perl >= 0.02',
        'Odoo::Ops (libodoo-oom-perl >= x)', 'Odoo::Ops (lib odoo >= 0.02)', 'odoo' )
    {
        is_deeply( [ parse_dep($bad) ], [], "refused: $bad" );
        ok( scalar( validate_owns( 't', { deps => [$bad] } ) ), 'and the validator says so' );
    }
};

# The enable path's check, in a child whose @INC is controlled - OOM absent,
# then the 0.01 tree.
sub missing_with {
    my (@inc) = @_;
    my $out = run_cmd( $^X, ( map { "-I$_" } @inc, "$root/lib" ), '-MJSON::PP=encode_json',
        '-MLazysite::Manager::Plugins', '-e',
        'my $d = JSON::PP::decode_json(qx($^X ' . $plugin . ' --describe));'
            . 'my ($m, $b) = Lazysite::Manager::Plugins::_missing_deps("plugins/odoo.pl", "'
            . $plugin . '", $d); print encode_json([$m, $b]);' );
    return eval { decode_json($out) } // [ $out, [] ];
}

subtest 'absent: refused, naming the package that exists' => sub {
    plan skip_all => 'an Odoo::Ops is installed on this host' if eval { require Odoo::Ops; 1 };
    my ( $msg, $bare ) = @{ missing_with() };
    like( $msg, qr/Odoo::Ops \(Debian: libodoo-oom-perl \(>= 0\.03\)\)/, 'the declared package' );
    unlike( $msg, qr/libodoo-ops-perl/, 'not the guess' );
    is_deeply( $bare, ['Odoo::Ops'], 'the audit gets the bare name' );
};

subtest 'present and too old: refused, saying which version is here' => sub {
    my ( $msg, $bare ) = @{ missing_with( OdooTest::old_oom_lib() ) };
    like( $msg, qr/Odoo::Ops 0\.03 or newer - this host has 0\.01/, 'the version gap is named' );
    is_deeply( $bare, ['Odoo::Ops'], 'and the module' );
};

subtest 'the Status button reports and repairs nothing' => sub {
    my $site = site_tempdir();
    my $out  = run_cmd( $^X, $plugin, '--action', 'status', '--docroot', $site );
    my $s    = eval { decode_json($out) } // {};
    like( $s->{message} // '', qr/libodoo-oom-perl|not configured/, 'it says what is missing' );
    ok( !-e "$site/lazysite/odoo", 'and created nothing' );
};

done_testing();
