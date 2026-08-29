#!/usr/bin/perl
# SM694: a plugin can declare an executable it needs, and is refused without it.
#
# SM472 established the rule and the reason: A PLUGIN THAT CANNOT RUN IS NOT
# ENABLED. It was learned expensively - the data plugin once enabled cleanly on
# a host without YAML::PP, listed its empty set of tables happily, and answered
# 500 to every attempt to declare one, because the parser is only reached once
# there is something to parse. Five variations were bisected before anyone said
# the module's name.
#
# That check asks `require`, which answers for Perl modules and nothing else. A
# plugin wrapping an external tool had no way to declare what it needs, so the
# rule could not protect it: the operator would enable it and it would fail at
# first use, which is the state SM472 exists to prevent.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

use Lazysite::Manager::Plugins ();

subtest 'a command is found only when it is really there' => sub {
    ok( Lazysite::Manager::Plugins::_bin_on_path('perl'),
        'perl is on the path' );
    ok( !Lazysite::Manager::Plugins::_bin_on_path('definitely-not-installed-xyz'),
        'a command that does not exist is absent' )
        or diag( 'A check that answers "installed" for everything would let a '
            . 'plugin enable and fail at first use - the state this exists to '
            . 'prevent.' );
    ok( !Lazysite::Manager::Plugins::_bin_on_path(''),
        'and an empty name is not a command' );
};

subtest 'a directory is not an executable' => sub {
    # -x is true for a directory. Without the -d guard, a plugin declaring a
    # name that happens to match a directory on PATH would enable and then fail
    # on first use.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Plugins.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /(sub _bin_on_path \{.*?\n\})/s;
    ok( $fn, 'the lookup was found' ) or return;
    like( $fn, qr/!-d/, 'a directory is excluded' );
    like( $fn, qr{/usr/local/bin:/usr/bin:/bin},
        'and PATH has a conservative fallback' )
        or diag( 'The CGI environment may carry no PATH. Concluding "absent" '
            . 'is safe; concluding "present" because a login shell would have '
            . 'found it is not.' );
};

subtest 'the descriptor cannot choose what gets executed' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Plugins.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /(sub _missing_deps \{.*?\n\})/s;
    ok( $fn, 'the dependency check was found' ) or return;

    like( $fn, qr/\Q[A-Za-z0-9][A-Za-z0-9._-]*\E/,
        'a declared command name is a bare name, checked against a pattern' )
        or diag( 'This value comes from a plugin descriptor. A lookup that '
            . 'interpolated it would let a descriptor decide what runs - the '
            . 'module branch guards its names for exactly this reason.' );
    like( $fn, qr/\$desc->\{owns\}\{bins\}/, 'bins is read from the descriptor' );
    like( $fn, qr/return undef unless \@deps \|\| \@bins;/,
        'and a plugin declaring only bins is still checked' )
        or diag( 'The early return used to test @deps alone, so a plugin with '
            . 'bins and no modules would skip the check entirely.' );
};

subtest 'the refusal names what is missing, as it does for a module' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Plugins.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /(sub _missing_deps \{.*?\n\})/s;
    like( $fn, qr/a program, not a Perl module/,
        'it says the missing thing is a program' )
        or diag( 'An operator told "needs pandoc" alongside module names would '
            . 'reasonably go looking for a CPAN package.' );
};

done_testing();
