#!/usr/bin/perl
# N13-04: the two writers of the audit trail agree about whether it is switched off.
#
# Lazysite::Audit writes almost every audit line. plugins/form-handler.pl writes
# form submissions to the same file directly, without loading the lib, and so
# carries a marked copy of the switch reader. A switch that stopped one writer
# and not the other would leave the trail recording after an operator was told
# it had stopped - which is the failure the whole switch design exists to avoid.
#
# The handler runs its main flow when loaded, so its reader is lifted out of the
# source and run in a sandbox against a real conf, beside the module's reader,
# over the same texts - including the shapes a hand-rolled reader gets wrong.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Audit ();

my $root = repo_root();
open my $fh, '<:utf8', "$root/plugins/form-handler.pl" or die $!;
my $src = do { local $/; <$fh> };
close $fh;
my ($sub) = $src =~ /(^sub _audit_trail_off \{.*?^\})/ms;
ok( defined $sub, 'found the form handler\'s marked copy' ) or BAIL_OUT('no reader to compare');
eval "package FH; our \$DOCROOT; $sub; 1" or die "cannot load the marked copy: $@";

my $d = site_tempdir();
make_path("$d/lazysite");
$FH::DOCROOT = $d;

my @CASES = (
    [ 'no key at all',                     "site_name: T\n" ],
    [ 'on',                                "audit_trail: on\n" ],
    [ 'off',                               "audit_trail: off\n" ],
    [ 'OFF in capitals',                   "audit_trail: OFF\n" ],
    [ 'off with trailing space',           "audit_trail: off   \n" ],
    [ 'a value that is neither',           "audit_trail: maybe\n" ],
    [ 'a commented-out off',               "# audit_trail: off\n" ],
    [ 'no space after the colon',          "audit_trail:off\n" ],
    [ 'two lines, the last says off',      "audit_trail: on\naudit_trail: off\n" ],
    [ 'two lines, the last says on',       "audit_trail: off\naudit_trail: on\n" ],
);
my $n = 0;
for my $c (@CASES) {
    my ( $what, $conf ) = @$c;
    open my $o, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$o} $conf;
    close $o;
    utime undef, time + ( ++$n ), "$d/lazysite/lazysite.conf";    # the module memoises on mtime
    my $module = Lazysite::Audit::audit_trail_state("$d/lazysite") eq 'off' ? 1 : 0;
    my $copy   = FH::_audit_trail_off() ? 1 : 0;
    is( $copy, $module, "both writers read '$what' the same way ("
            . ( $module ? 'off' : 'on' ) . ')' );
}

# And the direction a reader can get wrong without disagreeing: absence is ON.
open my $o, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$o} "site_name: T\n";
close $o;
utime undef, time + 100, "$d/lazysite/lazysite.conf";
is( Lazysite::Audit::audit_trail_state("$d/lazysite"), 'on',
    'a site that never set the key is recording - absence is on, not off' );

done_testing();
