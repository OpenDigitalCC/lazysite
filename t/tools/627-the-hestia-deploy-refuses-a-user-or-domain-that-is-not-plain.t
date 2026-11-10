#!/usr/bin/perl
# n808: THE HESTIA DEPLOY CHECKS USER AND DOMAIN BEFORE IT TOUCHES ANYTHING.
#
# USER and DOMAIN become /home/USER/web/DOMAIN and the registry file's name, and were
# checked only by that docroot existing. Now DOMAIN must be a plain host name (letters,
# digits, dots and hyphens; no slash, no space, no leading dot or hyphen), USER a plain
# name, both refused with exit 2 before the root check; and USER must be a user Hestia
# holds (v-list-user, stubbed here), refused with exit 2 before the template, the install
# or the registry is touched.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

plan skip_all => 'running as root - the deploy would go on to its work' if $> == 0;

my $root   = repo_root();
my $deploy = "$root/installers/hestia/lazysite-hestia-deploy.sh";
plan skip_all => 'the Hestia deploy is not here' unless -f $deploy;

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }
sub spit  { my ( $p, $b, $m ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; chmod $m // 0644, $p; return }

sub deploy { my $args = join ' ', @_; my $o = qx(bash \Q$deploy\E $args 2>&1); return ( $? >> 8, $o ) }

subtest 'a DOMAIN that is not a plain host name is refused, exit 2' => sub {
    for my $bad ( q{'a/b'}, q{'../b'}, q{'a b'}, q{'.hidden.test'}, q{'-x.test'}, q{'a;b'}, q{'$(x)'} ) {
        my ( $rc, $out ) = deploy( "siteuser $bad" );
        is( $rc, 2, "$bad: refused" ) or diag $out;
        like( $out, qr/DOMAIN must be a plain host name|unknown option/, 'and says what it takes (a leading hyphen is the option parser)' ) or diag $out;
    }
    my ( $rc, $out ) = deploy('siteuser example.test');
    unlike( $out, qr/DOMAIN must be/, 'a plain host name goes on' );
    like( $out, qr/must run as root/, 'to the root check' );
};

subtest 'a USER that is not a plain name is refused, exit 2' => sub {
    for my $bad ( q{'../x'}, q{'a b'}, q{'-x'}, q{'.x'}, q{'a/b'} ) {
        my ( $rc, $out ) = deploy( "$bad example.test" );
        is( $rc, 2, "$bad: refused" ) or diag $out;
        like( $out, qr/USER must be a Hestia user name|unknown option/, 'and says what it takes (a leading hyphen is the option parser)' ) or diag $out;
    }
};

# The Hestia question, through the function the script runs, against a stub v-list-user.
my $T = Cwd::realpath( site_tempdir() );
my $block = slurp($deploy);
$block =~ /^# n807: functions begin.*?\n(.*?)^# n807: functions end\n/ms or BAIL_OUT('the deploy lost its function block');
spit( "$T/functions.sh", $1 );
make_path("$T/h/bin");
spit( "$T/harness.sh", "set -e\nsource '$T/functions.sh'\ncheck_hestia_user\necho passed\n" );

sub ask {
    my ( $user, $rc ) = @_;
    spit( "$T/h/bin/v-list-user", "#!/bin/bash\necho \"\$1\" >> '$T/asked.log'\nexit $rc\n", 0755 );
    local $ENV{HESTIA} = "$T/h";
    local $ENV{U}      = $user;
    my $o = qx(bash '$T/harness.sh' 2>&1);
    return ( $? >> 8, $o );
}

subtest 'USER must be a user Hestia holds' => sub {
    my ( $rc, $out ) = ask( 'nosuchuser', 1 );
    is( $rc, 2, 'v-list-user refuses it: exit 2' ) or diag $out;
    like( $out, qr/'nosuchuser' is not a Hestia user/, 'naming the user' );
    unlike( $out, qr/passed/, 'and the run stops there' );
    ( $rc, $out ) = ask( 'siteuser', 0 );
    is( $rc, 0, 'v-list-user accepts it: the run goes on' ) or diag $out;
    like( slurp("$T/asked.log"), qr/^siteuser$/m, 'and Hestia was asked about that user' );
};

subtest 'the user is asked before the docroot is looked for' => sub {
    my $src = slurp($deploy);
    ok( $src =~ /\ncheck_hestia_user\n\[ -d "\$DOC" \]/, 'check_hestia_user runs just before the docroot test' );
};

subtest 'the summary says the claim link is a credential' => sub {
    like( slurp($deploy), qr/it is a credential for 24 hours: do not paste it into a ticket or a log/, 'the claim line carries the warning' );
};

done_testing();
