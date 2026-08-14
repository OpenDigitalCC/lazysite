#!/usr/bin/perl
# SM294: a pool setting must be read at startup, because %ENV does not survive.
#
# THE TRAP, which cost real time to find and is invisible in every CGI test.
# Under FastCGI, FCGI.pm REPLACES %ENV on each Accept() with that request's
# parameters. Whatever the pool put in the environment when it spawned the worker
# is simply gone by the time a request is handled. So:
#
#     sub handle { do_the_thing() if $ENV{LAZYSITE_FRONT_DOOR} }   # never true
#
# is always false under the pool - the one deployment the setting exists for -
# while working perfectly as a plain CGI, where %ENV *is* the request. The
# feature tests pass, the operator sets the flag, and nothing happens.
#
# It is the same family as SM285's @PROBE_EXT and SM293's %REGISTRY_CT, which
# t/lint/39 covers: state that is fine in a one-shot process and wrong in a
# persistent one. Different mechanism, same silent direction - so it gets its own
# check rather than a comment.
#
# THE RULE. Every variable the pool launcher exports to the worker must be read
# by the processor at FILE SCOPE (captured once, before the accept loop), never
# inside a sub. The list is derived FROM THE LAUNCHER, not hand-maintained here:
# a list somebody must remember to edit is a list that will be wrong, which is
# the lesson of t/lint/31, t/lint/39 and t/lint/41.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $pool = slurp("$root/tools/lazysite-pool.pl");
my $proc = slurp("$root/lazysite-processor.pl");

# What the launcher hands the worker.
my %exported;
while ( $pool =~ /^\s*\$ENV\{([A-Z_]+)\}\s*(?:=|\|\|=)/mg ) {
    $exported{$1} = 1;
}
delete $exported{$_} for qw(PATH);

cmp_ok( scalar keys %exported, '>=', 4,
    'found the settings the pool exports to the worker' )
    or diag( 'parsed: ' . join ', ', sort keys %exported );

# Where the processor's top-level subs start and end. The file is perltidy-clean,
# so a top-level sub closes with a brace in column 0 - the same assumption
# t/lint/37 already relies on to extract a sub body.
my @lines = split /\n/, $proc, -1;
my @in_sub;    # line index -> 1 when inside a top-level sub
my $depth = 0;
for my $i ( 0 .. $#lines ) {
    if ( !$depth && $lines[$i] =~ /^sub\s+\w+/ ) { $depth = 1 }
    $in_sub[$i] = $depth;
    if ( $depth && $lines[$i] =~ /^\}/ ) { $depth = 0 }
}

subtest 'every pool setting is captured at startup, not per request' => sub {
    my @offenders;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;      # a comment describing the rule
        next unless $in_sub[$i];    # file scope is where they belong
        while ( $l =~ /\$ENV\{([A-Z_]+)\}/g ) {
            my $name = $1;
            next unless $exported{$name};
            # A WRITE inside a sub is fine - that is building the environment for
            # a child process, not reading the pool's own settings.
            next if $l =~ /\$ENV\{\Q$name\E\}\s*=[^=]/;
            push @offenders, sprintf '%s:%d: %s', 'lazysite-processor.pl',
                $i + 1, $l =~ s/^\s+//r;
        }
    }

    is_deeply( \@offenders, [], 'no pool setting is read inside a sub' )
        or diag( join "\n  ",
        '',
        @offenders,
        '',
        'Under FastCGI these read the REQUEST environment, not the pool\'s, so',
        'they are always unset in the deployment they exist for. Capture the',
        'value at file scope (see $DOCROOT, $FRONT_DOOR) and use that.' );
};

subtest 'the front-door settings in particular' => sub {
    # Named explicitly because these are the ones SM294 added and the ones whose
    # silent-off failure was actually observed during that work.
    for my $name (qw(LAZYSITE_FRONT_DOOR LAZYSITE_CGIBIN)) {
        ok( $exported{$name}, "$name is exported by the pool launcher" );
    }
    like( $proc, qr/^my \$FRONT_DOOR\s*=/m,
        'the processor captures front-door mode at file scope' );
};

done_testing();
