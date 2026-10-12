package CrashHook;

# P24 (WORK-PLAN-0154): make one handler die, from outside, so a test can ask
# what a surface records when a handler crashes. Loaded into a child perl with
# PERL5OPT=-MCrashHook before the surface script compiles: it loads the module
# named by CRASH_HOOK_SUB's package and replaces that sub with one that dies
# with CRASH_HOOK_MSG. A script's later `use Module qw(sub)` imports the
# replacement. Test-only; never on a shipped path.
use strict;
use warnings;

if ( my $full = $ENV{CRASH_HOOK_SUB} ) {
    my ( $pkg, $sub ) = $full =~ /\A([\w:]+)::(\w+)\z/ or die "CRASH_HOOK_SUB: $full\n";
    ( my $file = "$pkg.pm" ) =~ s{::}{/}g;
    require $file;
    my $msg = $ENV{CRASH_HOOK_MSG} // 'crash';
    no strict 'refs';
    no warnings 'redefine';
    *{"${pkg}::$sub"} = sub { die "$msg\n" };
}

1;
