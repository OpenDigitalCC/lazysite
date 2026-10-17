#!/usr/bin/perl
# SM1172 (OOM Lab L-15, "parallel installs"): "Saving `odoo_packs` while another
# app is installed left the other app's operations answering 404 'no operation
# installed' for a few seconds (the list is rewritten whole)."
#
# THE CAUSE. plugin-save writes lazysite/odoo.conf atomically (temp + rename), so
# a reader never sees a torn file. But it READ the file, changed it in memory and
# wrote it back with no lock held across the three, while the lazysite.conf writer
# beside it takes one. Two saves overlapping both read the old file and the second
# rename won: the first save's keys (an app's odoo_packs namespace) were gone from
# the file, and so from `connection()`, until something saved them again.
#
# Driven without timing: the hook runs at the exact point after the first save has
# READ the file. If the lock is free there (the defect), a whole second save runs
# inside the window; if it is held (the fix), another save has to wait for this one,
# and runs once it is done.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use Fcntl qw(:flock);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Manager::Plugins ();

my $root   = repo_root();
my $parent = site_tempdir();
my $d      = "$parent/public_html";
make_path( "$d/lazysite", "$parent/plugins" );
copy( "$root/plugins/odoo.pl", "$parent/plugins/odoo.pl" ) or die $!;
chmod 0755, "$parent/plugins/odoo.pl";
local $ENV{PERL5LIB} = "$root/lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );

my $conf = "$d/lazysite/odoo.conf";
sub conf { open my $h, '<', $conf or return ''; local $/; return <$h> }
sub reset_conf {
    open my $c, '>', $conf or die $!;
    print {$c} "odoo_url: https://odoo.example.com\nodoo_db: lab\n";
    close $c;
}
$Lazysite::Manager::Plugins::DOCROOT = $d;
sub save { return Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/odoo.pl', {@_} ) }

# Run $second at the point the first save has read the file; say whether the lock
# was free there. A held lock means the second save would wait, so it runs after.
my ( $was_free, @later );
{
    no warnings 'redefine';
    my $real = \&Lazysite::Manager::Plugins::_slurp_or_empty;
    my $armed;
    sub arm_hook {
        my ($second) = @_;
        $armed = $second;
        $was_free = undef;
        @later    = ();
    }
    *Lazysite::Manager::Plugins::_slurp_or_empty = sub {
        my $content = $real->(@_);
        return $content unless $armed && $_[0] eq $conf;
        my $job = $armed;
        undef $armed;
        open my $probe, '>>', "$d/lazysite/.odoo.conf.lock" or die $!;
        if ( flock $probe, LOCK_EX | LOCK_NB ) {
            $was_free = 1;
            flock $probe, LOCK_UN;
            close $probe;
            $job->();
        }
        else {
            $was_free = 0;
            close $probe;
            push @later, $job;    # a second process would wait for this lock
        }
        return $content;
    };
}

# 1. The read happens under the lock.
reset_conf();
arm_hook( sub { save( odoo_allow_writes => '1' ) } );
my $a = save( odoo_packs => 'Lab::Stock::Ops' );
$_->() for splice @later;
ok( $a->{ok}, 'the first save succeeds' );
is( $was_free, 0, 'the file is read with the lock held, so no other save can slip in between' );

# 2. Two saves that overlap both land.
my $text = conf();
like( $text, qr/^odoo_packs: Lab::Stock::Ops$/m,       "the first save's key is in the file" );
like( $text, qr/^odoo_allow_writes: 1$/m,              "the overlapping save's key is in the file too" );
like( $text, qr{^odoo_url: https://odoo\.example\.com$}m, 'the keys neither save touched are kept' );

# 3. The same with one app's pack added after another's (two installs).
reset_conf();
arm_hook( sub { save( odoo_ca_file => '' ) } );
save( odoo_packs => 'Lab::Stock::Ops' );
$_->() for splice @later;
arm_hook( sub { save( odoo_identity_ttl => '300' ) } );
save( odoo_packs => 'Lab::Stock::Ops,Lab::Picking::Ops' );
$_->() for splice @later;
$text = conf();
like( $text, qr/^odoo_packs: Lab::Stock::Ops,Lab::Picking::Ops$/m, 'the list holds both apps' );
like( $text, qr/^odoo_identity_ttl: 300$/m,                        '...and the overlapping save survived' );

done_testing;
