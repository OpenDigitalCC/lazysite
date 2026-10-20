#!/usr/bin/perl
# SM1207 (lab finding L-1, oom-pick): A `custom` CHANGE OF A SITE PACK APPLIES
# THROUGH oomd.
#
# SM1170 fixed the in-process path (Lazysite::Odoo::with_site_ops around Runner->apply;
# t/unit/odoo/56). With odoo_daemon on, the apply is oomd's: the Runner there finds a
# custom change's class by name with Odoo::Ops::Registry->new and no arguments
# (t/vendor/oom/lib/Odoo/Ops/Runner.pm:652), which reads oomd's OWN environment
# (ODOO_OPS_NAMESPACES, set by the service at start from odoo_packs, Oomd.pm _start)
# and its config (pack_dirs, written by Lazysite::Odoo::Daemon). So the site's pack
# must be there when oomd starts. The operation leaves the pid of the process that
# applied it in a file: the daemon's, not this test's.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet fake_shop);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
$ENV{PERL5LIB} .= ':' . TestHelper::repo_root() . '/t/lib';

sub put {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}

sub read_pid {
    my ($f) = @_;
    open my $fh, '<', $f or return;
    my $p = <$fh>;
    chomp $p if defined $p;
    return $p;
}

my %WHO = ( mode => 'authenticated', actor => 'alice', caps => { manage_connectors => 1 }, groups => ['staff'], ip => '192.0.2.7' );

sub run_site {
    my ( $label, $d, $opname, $apply ) = @_;
    $Lazysite::Odoo::DOCROOT = $d;
    no warnings 'once';
    $Lazysite::Odoo::TRANSPORT = fake_shop();
    bind( $d, id => 'mark', operation => $opname, modes => 'authenticated', callers => 'staff',
        ( $apply ? ( apply => 'immediate' ) : () ), params => 'file=file' );
    my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
    ok( wait_until( sub { oomd_up($d) }, 30 ), "$label: the real oomd is up" )
        or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );
    my $mark = "$d/mark-$label.txt";
    my ($b) = Lazysite::Odoo::find_binding('mark');
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::call( $b, { file => $mark }, %WHO ) } );
    my $out = $r;
    if ( !$apply ) {
        ok( $r->{planned}, "$label: a plan, not a write" ) or diag explain $r;
        ok( !-e $mark, "$label: nothing applied yet" );
        ( undef, $out ) = quiet( sub { Lazysite::Odoo::confirm( $r->{plan}, %WHO ) } );
    }
    is( Lazysite::Odoo::last_via(), 'daemon', "$label: it went through the daemon" );
    unlike( $out->{error} // '', qr/no operation/, "$label: the daemon found the operation's class" );
    ok( $out->{ok} && $out->{applied}, "$label: it applied" ) or diag explain $out;
    isnt( $out->{kind} // '', 'apply-incomplete', "$label: not apply-incomplete" );
    my $pid = read_pid($mark);
    ok( defined $pid && $pid =~ /\A\d+\z/ && $pid != $$, "$label: the change ran in the daemon, not in the test" )
        or diag "pid in file: " . ( $pid // 'none' );
    oomd_stop($svc);
    return;
}

subtest 'a pack named in odoo_packs: plan, then confirm' => sub {
    my $d = oomd_site( odoo_packs => 'LazysiteTest::OdooCustom' );
    run_site( 'ns', $d, 'shopc.mark', 0 );
};

subtest 'a pack named in odoo_packs: an immediate binding' => sub {
    my $d = oomd_site( odoo_packs => 'LazysiteTest::OdooCustom' );
    run_site( 'now', $d, 'shopc.mark', 1 );
};

subtest 'a pack in an odoo_pack_dirs directory: plan, then confirm' => sub {
    my $d = oomd_site( odoo_packs => 'Odoo::Test::OomdOps' );
    my $root = "$d/lazysite/odoo-packs";
    put( "$root/shopd/pack.yaml", <<'YAML' );
name: shopd
version: 1.0.0
oom_min: "0.30"
namespace: Odoo::Pack::Shopd
series: [16, 17, 18]
summary: A fixture pack with a custom change
YAML
    put( "$root/shopd/lib/Odoo/Pack/Shopd/Mark.pm", <<'PM' );
package Odoo::Pack::Shopd::Mark;
use strict;
use warnings;
use parent 'Odoo::Ops::Operation';
sub op_name     { 'shopd.mark' }
sub summary     { 'Leave the applying pid in a file' }
sub params      { return { file => { type => 'str', required => 1 } } }
sub read_scope  { return {} }
sub write_scope { return {} }
sub writes      { 1 }
sub buckets     { return [ { name => 'marked', meaning => 'a mark' } ] }
sub holds       { return [] }
sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'marked', action => 'custom', handler => $self->op_name, kind => 'mark',
        model => 'x.mark', id => 1, key => 'mark:1', vals => { file => $self->param('file') } );
    return $plan;
}
sub apply_custom {
    my ( $class, $client, $c ) = @_;
    open my $fh, '>', $c->{vals}{file} or die "mark: $!\n";
    print {$fh} "$$\n";
    close $fh;
    return { id => 1, reported => 'mark' };
}
sub undo_custom { return ( {}, undef ) }
1;
PM
    OdooTest::write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
        odoo_allow_writes => 'true', odoo_packs => 'Odoo::Test::OomdOps', odoo_daemon => 'on',
        odoo_daemon_workers => 2, odoo_pack_dirs => $root );
    run_site( 'dir', $d, 'shopd.mark', 0 );
};

done_testing;
