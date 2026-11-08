#!/usr/bin/perl
# SM1369 X6, H-6 (ruling 55): `lazysite check` RUNS WHAT AN EXTENSION CHECKS OF
# ITSELF, AND PRINTS IT AS ITS OWN.
#
# An enabled extension declares `hooks.checks`; the check calls each function,
# through the hook loader, with the docroot and the lazysite directory, and
# prints every finding it answers with its own report(). Through the real tool,
# run as a child, against a fixture extension and a real index:
#
#   * each finding is printed at its level, with its fix, and counted in the
#     summary like the tool's own;
#   * a check that dies is one WARN naming the extension, and the run goes on;
#   * a finding that is not one (a level the tool does not know) is a WARN, not
#     a crash and not a silent drop;
#   * installed and off, the extension is one line - installed, off - and none
#     of its checks runs (G-1);
#   * the Odoo extension's checks are its own now: core's tool names no Odoo
#     check.
#
# Sabotage: drop the enabled test from report_extension_checks and the off case
# prints the fixture's findings - this fails.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir index_extensions);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

sub site {
    my ($on) = @_;
    my $d    = site_tempdir();
    my $base = dirname($d);
    make_path( "$d/lazysite/$_", ) for qw(auth cache logs manager);
    make_path("$base/extensions/probe/lib");
    write_extension( "$base/extensions/probe.pl", {
            id => 'probe', name => 'Probe', contract => 1,
            owns => { hooks => { checks => [ 'ProbeCheck::findings', 'ProbeCheck::dies', 'ProbeCheck::odd' ] } } } );
    spit( "$base/extensions/probe/lib/ProbeCheck.pm",
        "package ProbeCheck;\n"
            . "sub findings { my (\$doc, \$lz) = \@_; return [\n"
            . "  { level => 'OK',   text => 'probe: all is well under ' . ( -d \$lz ? 'its lazysite dir' : '?' ) },\n"
            . "  { level => 'WARN', text => 'probe: something to look at', fix => 'look at it' },\n"
            . "  { level => 'FAIL', text => 'probe: something broken', fix => 'mend it' } ] }\n"
            . "sub dies { die \"probe check fell over\\n\" }\n"
            . "sub odd { return [ { level => 'SHOUT', text => 'probe: loud' } ] }\n1;\n" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nextensions:\n  - extensions/probe.pl\n" );
    my $r = index_extensions($d);
    die 'not indexed: ' . JSON::PP->new->encode($r) unless $r->{ok};
    # off: the conf no longer lists it, and the index built while it was on
    # still does - the check reads the conf again (G-1)
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" ) unless $on;
    return $d;
}

sub run_check {
    my ($d) = @_;
    local @ENV{qw(LAZYSITE_EXTENSION_DIRS LAZYSITE_DEV_SERVER)};
    delete @ENV{qw(LAZYSITE_EXTENSION_DIRS LAZYSITE_DEV_SERVER)};
    return scalar qx($^X -I\Q$root/lib\E \Q$script\E --docroot \Q$d\E 2>&1);
}

subtest 'enabled: its findings are the check\'s own' => sub {
    my $out = run_check( site(1) );
    like( $out, qr/^\[\s*ok\s*\] probe: all is well under its lazysite dir$/m, 'an OK, given the lazysite dir' ) or diag $out;
    like( $out, qr/^\[\s*warn\s*\] probe: something to look at/m, 'a WARN' );
    like( $out, qr/look at it/, '...with its fix' );
    like( $out, qr/^\[\s*fail\s*\] probe: something broken/mi, 'a FAIL' );
    like( $out, qr/^\[\s*warn\s*\] the Probe extension's check did not run \(ProbeCheck::dies\): .*probe check fell over/m,
        'a check that dies is a WARN naming the extension' );
    like( $out, qr/^\[\s*warn\s*\] the Probe extension's check \(ProbeCheck::odd\) answered a finding that is not one/m,
        'a finding with a level the tool does not know is a WARN' );
    unlike( $out, qr/probe: loud/, '...and is not printed as if it were one' );
    like( $out, qr/\d+ fail/i, 'the run went on to its summary, counting the FAIL' );
};

subtest 'installed and off: one line, and nothing of it runs' => sub {
    my $out = run_check( site(0) );
    like( $out, qr/^\[\s*ok\s*\] the Probe extension is installed, off - its checks run while it is on$/m, 'installed, off' )
        or diag $out;
    unlike( $out, qr/probe: |ProbeCheck/, 'none of its checks ran' );
};

subtest 'the Odoo extension\'s checks are its own' => sub {
    open my $fh, '<', $script or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    $src =~ s/^\s*#.*$//mg;
    unlike( $src, qr/report_odoo_|\bOdoo::Ops\b|extensions\/odoo\.pl/, 'the tool names no Odoo check' );
    my $desc = JSON::PP::decode_json( scalar qx{$^X -I$root/lib $root/extensions/odoo.pl --describe} );
    is_deeply( $desc->{owns}{hooks}{checks}, ['Lazysite::Odoo::Check::run'], 'the extension declares them' );
};

done_testing;
