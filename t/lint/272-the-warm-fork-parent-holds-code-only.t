#!/usr/bin/perl
# SM1226 (SM1082 C3, R3): THE ODOO ENDPOINT'S WARM-FORK PARENT HOLDS CODE ONLY.
#
# The trade-off note the release manager ruled on (2026-10-20, "D5 - yes"): "the
# parent must load code and configuration ONLY - no Odoo sessions, API keys or
# per-person data - enforced by a test (as t/lint/269 classifies the pool's
# resident state)". Every child the parent forks inherits whatever the parent
# holds, so a credential in the parent is a credential in every request.
#
# WHAT THE PARENT RUNS is small and fixed: it requires the endpoint and the
# Lazysite:: modules the endpoint names (Lazysite::WarmFork::preload), binds a
# socket, and loops accept - fork - close. It never runs a sub of the endpoint
# or of its modules, and never reads a request (the child does). So what it can
# hold is exactly what COMPILING those files puts in memory: their file-scope
# initialisers and any statement they run at load. This holds all three:
#
#   1. THE SET. The files the parent loads, computed with the parent's own
#      function (Lazysite::WarmFork::_names, the closure preload walks), and
#      checked against a real preload in a fresh perl: every Lazysite file the
#      parent has in %INC after its preload is in the set read here.
#   2. EVERY FILE-SCOPE VARIABLE of the set (t/lib/FileScope.pm, t/lint/269's
#      scan) is EMPTY at load (no initialiser: only code the parent never runs
#      could fill it), CONSTANT (an initialiser of literals only - stricter than
#      269's: no call, no variable, no `::` name), or COMPUTED AT LOAD and listed
#      below with what it holds. A new computed one fails here, naming file, line
#      and variable; a table entry that matches nothing fails too.
#   3. THE PARENT'S OWN CODE calls nothing of the endpoint's: outside the child
#      (_child and the STDIN tie), Lazysite::WarmFork names no Lazysite:: function
#      but the log line, and main::main is called only in the child; the endpoint
#      script runs nothing at load but its lib search; no module of the set runs a
#      statement at load other than those listed.
#
# What a request brings is held at runtime by t/integration/325, which reads the
# parent's memory after it has served signed-in requests. The OOM modules the
# parent preloads (@OOM_PRELOAD) are another project's code and are covered there
# too, by value rather than by source.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use FileScope  qw(code_lines file_scope_decls);

my $root = repo_root();
unshift @INC, "$root/lib";
require Lazysite::WarmFork;

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "$f: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# --- 1. the set --------------------------------------------------------------------
my %text = map { $_ => slurp("$root/$_") } qw(lazysite-odoo.pl lib/Lazysite/WarmFork.pm lib/Lazysite/WarmFork/Wire.pm);
{
    no warnings 'once';
    my @queue = ( @Lazysite::WarmFork::ALWAYS, Lazysite::WarmFork::_names( $text{'lazysite-odoo.pl'} ) );
    my %seen;
    while ( defined( my $m = shift @queue ) ) {
        next if $seen{$m}++;
        my $f = 'lib/' . join( '/', split /::/, $m ) . '.pm';
        next unless -f "$root/$f";
        $text{$f} = slurp("$root/$f");
        push @queue, Lazysite::WarmFork::_names( $text{$f} );
    }
}
cmp_ok( scalar keys %text, '>', 20, 'the parent\'s set reaches the endpoint\'s modules and theirs' );
ok( $text{'lib/Lazysite/Odoo.pm'} && $text{'lib/Lazysite/Auth/Session.pm'}, '...the engine and the verifier among them' );

subtest 'a real preload loads nothing of lazysite\'s that this reads past' => sub {
    my $code = 'require Lazysite::WarmFork; my ( $l, $s, $e ) = Lazysite::WarmFork::preload( $ARGV[0] ); '
        . 'die "preload: $e" if defined $e; require JSON::PP; print JSON::PP::encode_json( [ sort keys %INC ] )';
    local $ENV{DOCUMENT_ROOT} = '/nonexistent';
    my $out = qx{$^X -I$root/lib -e '$code' $root/lazysite-odoo.pl 2>/dev/null};
    my $inc = eval { decode_json($out) } || [];
    ok( scalar @$inc, 'the preload ran in a fresh perl' ) or return;
    my @ours = grep { m{\ALazysite/} } @$inc;
    cmp_ok( scalar @ours, '>', 20, 'and loaded the endpoint\'s modules' );
    for my $f (@ours) {
        ok( exists $text{"lib/$f"}, "lib/$f is in the set read here" );
    }
};

# --- 2. every file-scope variable ---------------------------------------------------

# A computed initialiser: anything that is not literals. qw() and qr// bodies are
# literal text; a call, a variable, a `::` name, a method, a readline, a backtick,
# a block (do, sub, eval, map, grep, sort) are not.
sub computed {
    my ($rest) = @_;
    return 0 unless $rest =~ /\A=(?!=)\s*(.*?);?\s*\z/s;
    my $rhs = $1;
    $rhs =~ s{\bq[wr]\s*(?:\((?:\\.|[^()\\])*\)|\[(?:\\.|[^\[\]\\])*\]|\{(?:\\.|[^{}\\])*\}|/(?:\\.|[^/\\])*/|<(?:\\.|[^<>\\])*>|\|(?:\\.|[^|\\])*\||!(?:\\.|[^!\\])*!)[a-z]*}{ QW }gs;
    return $rhs =~ /[\$\@%&]\w|\$\{|\w::\w|\b\w+\s*\(|->|[<`]|\b(?:do|sub|eval|map|grep|sort)\b/ ? 1 : 0;
}

# What each computed file-scope variable holds once the file has compiled: none
# is about a request, a person or a credential.
my $DERIVED = 'derived at load from a constant list in the same file';
my $SEAM    = 'a code reference to a sub of its own module (a test seam); code, not data';
my $PATTERN = 'a compiled pattern built from constants';
my %T       = (
    'lib/Lazysite/Daemon/Service/Scheduler.pm' => { '%JOBS' => 'the job table: names, intervals and code references' },
    'lib/Lazysite/Data/Descriptor.pm' => { '%TYPE' => $DERIVED, '%TRUE' => $DERIVED, '%FALSE' => $DERIVED },
    'lib/Lazysite/Data/Owned.pm' => { '%RESERVED' => $DERIVED, '%STAMPED' => $DERIVED },
    'lib/Lazysite/Handlers.pm'   => { '%RESERVED_FORM' => $DERIVED },
    'lib/Lazysite/Lifecycle.pm'  => { '%IS_VERDICT'    => $DERIVED },
    'lib/Lazysite/Manager/Common.pm' => { '$DANGEROUS_RE' => $PATTERN, '%REFUSAL_STATUS' => $DERIVED },
    'lib/Lazysite/Manager/Connectors.pm' => { '$MODES' => 'a reference to Lazysite::Egress\'s constant list of modes' },
    'lib/Lazysite/Manager/Domains.pm' => { '%IS_KEY' => $DERIVED, '%IS_PRESENTATION' => $DERIVED },
    'lib/Lazysite/Manager/Plugins.pm' => { '$ROW_JSON' => 'a JSON::PP encoder, constructed with no data' },
    'lib/Lazysite/Manager/Upload.pm' => { '%TEXT_EXTENSIONS' => $DERIVED },
    'lib/Lazysite/Notify.pm' => { '$XMPP_SENDER' => $SEAM, '$MAIL_SENDER' => $SEAM, '$SRV_RESOLVER' => $SEAM },
    'lib/Lazysite/Odoo.pm' => { '%PRIVATE4' => 'a constant table of code references (private address ranges)', '%CALL_FIELD' => $DERIVED },
    'lib/Lazysite/Odoo/Binding.pm' => { '%FROM_INPUT' => $DERIVED, '%SNIFFED' => $DERIVED },
    'lib/Lazysite/Odoo/Fields.pm' => { '%TYPE' => 'derived at load from the module\'s constant TYPES()' },
    'lib/Lazysite/Outbox.pm' => { '$MAIL_SENDER' => $SEAM },
    'lib/Lazysite/Timing.pm' => {
        '%KNOWN' => $DERIVED,
        '$LOADED' => 'the clock when the file compiled; the child moves it to the fork (worker_started), which starts its `load` phase',
    },
    'lib/Lazysite/Util.pm' => { '%LINK_SAFE_SCHEME' => $DERIVED, '%ENV_ALLOWLIST' => $DERIVED },
    'lib/Lazysite/Validate.pm' => { '%FORM_FLAGS' => $DERIVED, '%CLASS_RESERVED' => $DERIVED },
    'lib/Lazysite/WarmFork.pm' => {
        '$REQUEST_TIMEOUT' => 'the child\'s time limit, from whether this run is under Devel::Cover (PERL5OPT): a property of the run'
    },
);

my ( %used, @computed );
for my $f ( sort keys %text ) {
    my %done;
    for my $d ( file_scope_decls( $text{$f} ) ) {
        next if $d->{var} =~ /\A[\$\@%](?:EXPORT_OK|EXPORT|EXPORT_TAGS|ISA|VERSION)\z/;
        next if $done{ $d->{var} }++;
        next unless computed( $d->{rest} );
        push @computed, [ $f, $d ];
    }
}
cmp_ok( scalar @computed, '>', 5, 'the scan finds the computed file-scope variables' );
subtest 'every file-scope variable computed at load is listed with what it holds' => sub {
    for my $c (@computed) {
        my ( $f, $d ) = @$c;
        my $why = $T{$f} && $T{$f}{ $d->{var} };
        $used{$f}{ $d->{var} } = 1 if $why;
        ok( $why, "$f:$d->{line} $d->{var}" . ( $why ? " - $why" : '' ) )
            or diag( "$d->{var} is computed when $f compiles, in the warm-fork parent, and every request's child "
                . 'inherits it: list it in t/lint/272 with what it holds, or make it empty at load and fill it per request' );
    }
};
subtest 'no entry in the table is stale' => sub {
    for my $f ( sort keys %T ) {
        for my $v ( sort keys %{ $T{$f} } ) {
            ok( $used{$f}{$v}, "$f $v is a computed file-scope variable of the parent's set" );
        }
    }
};

# --- 3. what the parent runs --------------------------------------------------------

# The statements of a file at depth 0, outside every sub and every BEGIN block:
# what compiling it runs.
#
# A block at depth 0 is a named sub, a BEGIN/END block or a bare block (the
# closure idiom, whose declarations the variable scan reads): it is dropped. Any
# other block (an anonymous sub or a hash inside a declaration) is part of its
# statement, whose body is not read.
sub top_statements {
    my ($t) = @_;
    my @out;
    my ( $depth, $stmt, $mode ) = ( 0, '', '' );
    for my $l ( code_lines($t) ) {
        my $line = $l->[1];
        for my $ch ( split //, $line ) {
            if ( $ch eq '{' ) {
                if ( $depth == 0 ) {
                    $mode = ( $stmt =~ /\bsub\s+\w+[^;]*\z/ || $stmt =~ /\b(?:BEGIN|END|INIT)\s*\z/ || $stmt =~ /\A\s*\z/ )
                        ? 'drop' : 'inner';
                }
                $depth++;
                next;
            }
            if ( $ch eq '}' ) {
                $depth--;
                if ( $depth == 0 ) { $stmt = $mode eq 'drop' ? '' : "$stmt\{}"; $mode = '' }
                next;
            }
            next if $depth > 0;
            $stmt .= $ch;
            if ( $ch eq ';' ) {
                ( my $s = $stmt ) =~ s/\s+/ /g;
                $s =~ s/\A\s+//;
                push @out, [ $l->[0], $s ] if length $s;
                $stmt = '';
            }
        }
        $stmt .= ' ' if $depth == 0;
    }
    return @out;
}

my $DECL = qr/\A(?:package\s|use\s|no\s|our\s|my\s|1\s*;|__PACKAGE__\s*;)/;
my %RUNS = (
    'lazysite-odoo.pl'         => [qr/\Aexit main\(\) if !caller;\z/],
    'lib/Lazysite/WarmFork.pm' => [qr/\Aexit main\(\@ARGV\) unless caller;\z/],
    # sets the module's request variables to "no request" (nobody, no capability,
    # no reach) when it compiles, so nothing reads them unset: constants, no person
    'lib/Lazysite/Manager/Common.pm' => [qr/\Areset_request_context\(\);\z/],
    # not a statement: the tail of `my $ATOM = qr/[^\s\@,;<>"()...]+/`, which the
    # scan splits at the `;` inside the pattern
    'lib/Lazysite/Mail.pm' => [qr/\A<>"\(\)\\\\\\x00-\\x1f\\x7f\]\+\/;\z/],
);
subtest 'nothing of the set runs a statement at load but its declarations' => sub {
    for my $f ( sort keys %text ) {
        for my $s ( top_statements( $text{$f} ) ) {
            my ( $n, $st ) = @$s;
            next if $st =~ $DECL;
            my $ok = grep { $st =~ $_ } @{ $RUNS{$f} || [] };
            ok( $ok, "$f:$n runs only what is allowed: $st" )
                or diag('a statement at file scope runs in the warm-fork parent when it compiles; move it into a sub');
        }
    }
};

subtest 'the parent calls nothing of the endpoint\'s; only the child runs it' => sub {
    my $wf = $text{'lib/Lazysite/WarmFork.pm'};
    ( my $parent = $wf ) =~ s/^sub _child \{.*?^\}\n//ms;
    $parent =~ s/^package Lazysite::WarmFork::Stdin;.*?^package Lazysite::WarmFork;//ms;
    my $code  = join "\n", map { $_->[1] } code_lines($parent);
    my @calls = $code =~ /\b(Lazysite::[\w:]+::\w+)\s*\(/g;
    is_deeply( [ sort { $a cmp $b } grep { $_ ne 'Lazysite::Util::log_event' && !/\ALazysite::WarmFork(?:::|\z)/ } @calls ], [],
        'outside the child it names no Lazysite:: function but its own and the log line' );
    unlike( $code, qr/\bmain::main\b/, 'and never calls the endpoint' );
    like( join( "\n", map { $_->[1] } code_lines($wf) ), qr/\bmain::main\(\)/, 'the child does' );
    my ($pre) = $wf =~ /^(sub preload \{.*?^\})/ms;
    my @ran = $pre =~ /\b((?:[A-Z]\w*::)+\w+)\s*\(/g;
    is_deeply( \@ran, [], 'preload calls no function of any module: it only requires' );
    unlike( $pre, qr/\bopen\b|\bsysread\b|\bread\s*\(|<\$\w+>|\bqx\b|`|\bdo\s+"/,
        'and reads no file itself: no configuration, no key, no secret' );
    is_deeply( [ $pre =~ /\b_slurp\(\s*([^)]*?)\s*\)/g ], [ '$script', '$INC{$f}' ],
        'the only files it reads are the sources it walks for module names (the endpoint and each module loaded)' );
};

done_testing;
