#!/usr/bin/perl
# SM1244 (#376 part 1): OOM 0.37 and earlier can send a write again when its
# answer timed out, so a change can be made twice in Odoo; 0.38 calls it
# `unknown` and does not repeat it. `lazysite check` warns while the Odoo
# extension is on and the OOM the site loads is older than 0.38, naming the
# version and the file found and the fix.
#
# The site loads OOM by `require Odoo::Ops` on its @INC, so the check is run with
# PERL5LIB naming a stand-in OOM of a given version, ahead of the host's.
use strict;
use warnings;
use Test::More;
use File::Basename ();
use File::Path     qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";

sub site {
    my ($odoo) = @_;
    my $doc = site_tempdir();
    make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
    open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n" . ( $odoo ? "plugins:\n  - plugins/odoo.pl\n" : '' );
    close $cf;
    return $doc;
}

# A stand-in OOM: Odoo::Ops and Odoo::Ops::Version at $v.
sub fake_oom {
    my ( $doc, $v ) = @_;
    my $lib = File::Basename::dirname($doc) . "/oom-$v/lib";
    make_path("$lib/Odoo/Ops");
    for my $m ( [ 'Odoo/Ops.pm', 'Odoo::Ops' ], [ 'Odoo/Ops/Version.pm', 'Odoo::Ops::Version' ] ) {
        open my $fh, '>', "$lib/$m->[0]" or die $!;
        print {$fh} "package $m->[1];\nour \$VERSION = '$v';\n1;\n";
        close $fh;
    }
    return $lib;
}

sub check {
    my ( $doc, $lib ) = @_;
    local $ENV{PERL5LIB} = $lib . ( length( $ENV{PERL5LIB} // '' ) ? ":$ENV{PERL5LIB}" : '' );
    return scalar qx($^X \Q$script\E --docroot \Q$doc\E 2>&1);
}

subtest 'the extension on, OOM 0.37: a warning naming the version and the fix' => sub {
    my $doc = site(1);
    my $lib = fake_oom( $doc, '0.37' );
    my $out = check( $doc, $lib );
    like( $out, qr/the Odoo extension is on and the OOM it loads is 0\.37/, 'it names the version found' )
        or diag $out;
    like( $out, qr/\Q$lib\E\/Odoo\/Ops\/Version\.pm/, 'and the file the site loads it from' );
    like( $out, qr/can send a write again when its answer timed out/, 'and what that risks' );
    like( $out, qr/install OOM 0\.38 or later/, 'and the fix' );
    like( $out, qr/\[ warn \] [^\n]*OOM it loads is 0\.37/, 'at WARN' );
};

subtest 'an older OOM still warns' => sub {
    my $doc = site(1);
    my $out = check( $doc, fake_oom( $doc, '0.31' ) );
    like( $out, qr/OOM it loads is 0\.31/, 'warned' ) or diag $out;
};

subtest 'the extension on, OOM 0.38: no warning, and the version is said' => sub {
    my $doc = site(1);
    my $out = check( $doc, fake_oom( $doc, '0.38' ) );
    unlike( $out, qr/can send a write again/, 'no warning' );
    like( $out, qr/the Odoo extension loads OOM 0\.38/, 'it says which OOM it loads' ) or diag $out;
};

subtest 'the extension off: nothing is said about OOM' => sub {
    my $doc = site(0);
    my $out = check( $doc, fake_oom( $doc, '0.37' ) );
    unlike( $out, qr/can send a write again|the Odoo extension loads OOM/, 'a site that does not call Odoo is not told' );
};

done_testing;
