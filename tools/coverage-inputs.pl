#!/usr/bin/perl
# tools/coverage-inputs.pl - the digest of everything that decides coverage.
#
# SM736: the coverage stage is the most expensive thing this project runs - two
# hours and twenty minutes on the 0.11.11 cut, against eleven minutes for the
# whole correctness suite. It is also a PURE FUNCTION of a knowable input set:
# the measured CGIs, the code they call into, every test that exercises them,
# and the floor config. Nothing else can move the percentage.
#
# So when that set is byte-identical to a run that already passed, the answer is
# known and re-deriving it buys nothing.
#
# WHAT THIS DELIBERATELY DOES NOT COVER. The correctness suite is not skippable
# on this argument and is not skipped: a gate result is a fact about a tree AT A
# TIME, and date-sensitive tests exist as a class - the 0.11.0 work found five
# stats tests that failed daily for ninety minutes after UTC midnight. Coverage
# is a structural measurement and does not have that property; correctness does.
#
# SM950 (3): ONLY THE TESTS THAT CAN REACH A MEASURED FILE. A test runs a CGI in
# one of two ways: it starts another process (system, exec, fork, backticks, qx,
# a piped open, $^X, IPC::*, a launcher module), or it loads the file into itself
# (`do EXPR`, `require EXPR`, string eval, a module loader). Neither happens
# without one of those constructs in the test's own code or in code it calls.
# The code is read with PPI, so a backtick in a string or a `system` in a comment
# is not mistaken for one. A .t is LEFT OUT of the digest only when
#
#   - its code has none of those constructs, and no dynamic call (`->can`,
#     `->$name`, `&$ref`, goto) that could reach one unseen;
#   - it names no measured file and builds no `lazysite-$...` name; and
#   - it mentions no sub, in any module under lib/, t/ or plugins/, that
#     launches - directly or through a sub that does - and loads no module
#     whose load-time code launches, directly or through what IT loads.
#
# Everything else is IN: what the analysis cannot show to be inert counts. Every
# module under lib/ and t/, every plugin (the CGIs `do` them), the measured CGIs,
# the floor file, coverage.sh and this file itself are always in - a change to
# the rules here moves the digest too. Without PPI every test is in. `--list`
# prints each test's classification and why.
#
# WHERE IT FIRES: a promotion, a cut after a documentation-only change, and a
# commit that changed only tests that reach nothing measured.
#
# Parsing ~1,100 files with PPI takes about a minute, so each file's analysis is
# cached in tmp/ under the hash of its content, PPI's version and this file. A
# cache that will not load is ignored; a missing one costs only time.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Find;
use File::Basename qw(dirname);
use Cwd            qw(abs_path);
use Storable       qw(nstore retrieve);
use Scalar::Util   qw(refaddr);

my $ROOT = dirname( dirname( abs_path($0) ) );
chdir $ROOT or die "coverage-inputs.pl: $ROOT: $!\n";
my $LIST = ( $ARGV[0] // '' ) eq '--list';

# The eight gated CGIs, named here because coverage.sh names them too - if the
# two ever disagree this digest would attest a set that is not the measured one.
# t/lint/111 asserts they match.
my @EXPLICIT = qw(
    lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl
    lazysite-auth.pl lazysite-mcp.pl lazysite-oauth.pl
    tools/lazysite-users.pl tools/lazysite-bundle-apply.pl
    dist/config/coverage-floor
);

# The harness that measures, and this file: a change to how coverage is taken,
# or to which tests are counted, is a change to the answer.
my @HARNESS = qw(tools/coverage.sh tools/coverage-inputs.pl);

# SM944: the processor's parts are the processor - it requires them by path - so
# a change to one moves the digest exactly as a change to the script does.
my @files = grep { -f } @EXPLICIT, @HARNESS, glob('lazysite-processor/*.pm');
my ( @tests, @code );
for my $dir (qw(t lib plugins)) {
    next unless -d $dir;
    find(
        { no_chdir => 1,
            wanted => sub {
                my $f = $File::Find::name;
                return unless -f $f && $f =~ /\.(?:t|pm|pl)$/;
                if   ( $f =~ /\.t$/ ) { push @tests, $f }
                else                  { push @code,  $f }
            },
        },
        $dir
    );
}
push @files, @code;

sub slurp { open my $fh, '<:raw', $_[0] or return; local $/; my $t = <$fh>; close $fh; return $t }

my $HAVE_PPI = eval { require PPI; 1 };

my $STEMS = join '|', map { my $s = $_; $s =~ s{.*/}{}; $s =~ s/\.pl$//; quotemeta $s }
    grep { /\.pl$/ } @EXPLICIT;
my $MEASURED = qr{\b(?:$STEMS)\b|lazysite-(?:[\$\@\{]|$)};

my %LAUNCH_WORD = map { $_ => 1 } qw(system exec fork readpipe syscall waitpid open2 open3 pipe goto AUTOLOAD);
my $LAUNCH_MODULE = qr{^(?:IPC|Proc|Capture|Test::Script|Test::Command|Test::TCP|Test::Mojo|Net::EmptyPort|
    Net::Server|CGI::Compile|CGI::Emulate|Plack|HTTP::Server|Mojo|Module::Load|Module::Runtime|Class::Load|
    Module::Pluggable|IO::Pipe|Expect|TAP|Test::Harness|App::Prove|Test::Compile|Test::Strict|Test::Cmd|
    Parallel|AnyEvent|IO::Async)(?:::|$)}x;

# What a TEST may load and still be shown inert: core and CPAN modules that
# start no process and load no file by name. A test that loads anything else -
# a network client, a template engine, a module not listed - is in. Modules
# under lib/, t/ and plugins/ are judged by their own code instead.
my %INERT = map { $_ => 1 } qw(
    strict warnings utf8 lib feature open constant parent base vars integer bytes
    Test::More Test::Builder FindBin File::Path File::Temp File::Basename File::Copy File::Find
    File::Spec File::stat Cwd JSON::PP Digest::SHA Digest::MD5 MIME::Base64 Encode Symbol Exporter
    POSIX Fcntl Errno Time::HiRes Time::Local Scalar::Util List::Util Storable Data::Dumper Carp
    Getopt::Long DB_File DBI YAML::PP Archive::Zip Text::MultiMarkdown Sys::Syslog
);

sub quote_text {
    my ($t) = @_;
    return $t->string  if $t->can('string');
    return $t->literal if $t->isa('PPI::Token::QuoteLike::Words');
    return $t->content;
}

# One pass over a run of significant tokens: why it launches (or undef), the
# words it mentions, and whether it names a measured file.
sub scan {
    my (@t) = @_;
    my ( $why, $named, %words );
    my $launch = sub { $why //= $_[0] };
    for my $i ( 0 .. $#t ) {
        my $k    = $t[$i];
        my $next = $i < $#t ? $t[ $i + 1 ] : undef;
        my $prev = $i > 0   ? $t[ $i - 1 ] : undef;
        my $c    = $k->content;
        if ( $k->isa('PPI::Token::QuoteLike::Backtick') || $k->isa('PPI::Token::QuoteLike::Command') ) {
            ( my $short = $c ) =~ s/\s+/ /g;
            $launch->( 'command (' . substr( $short, 0, 40 ) . ')' );
        }
        elsif ( $k->isa('PPI::Token::HereDoc') ) {
            $launch->('command heredoc') if $c =~ /<<~?\s*`/;
            my $body = join '', $k->heredoc;
            $named //= $1 if $body =~ /($MEASURED)/;
        }
        elsif ( $k->isa('PPI::Token::Magic') && $c eq '$^X' ) { $launch->('$^X') }
        elsif ( $k->isa('PPI::Token::Regexp') || $k->isa('PPI::Token::QuoteLike::Regexp') ) {
            $launch->('code in a regex') if $c =~ /\(\?\??\{/;
            my ($mods) = $c =~ /([a-z]*)\z/;
            $launch->('s///ee') if $k->isa('PPI::Token::Regexp::Substitute') && ( $mods =~ tr/e// ) >= 2;
        }
        elsif ( $k->isa('PPI::Token::Cast') ) {
            $launch->("dynamic call ($c)")
                if ( $c eq '&' || $c eq '*' ) && $next && ( $next->isa('PPI::Token::Symbol') || $next->content eq '{' );
        }
        elsif ( $k->isa('PPI::Token::Operator') && $c eq '->' && $next ) {
            $launch->('dynamic method') if $next->isa('PPI::Token::Symbol') || $next->isa('PPI::Token::Cast');
            $launch->('->can') if $next->content eq 'can';
        }
        elsif ( $k->isa('PPI::Token::Symbol') ) {
            my $s = $k->symbol;
            if ( $s =~ /^&(.+)$/ ) { my $n = $1; $words{$n} = 1; $words{$1} = 1 if $n =~ /::(\w+)$/ }
        }
        elsif ( $k->isa('PPI::Token::Quote') || $k->isa('PPI::Token::QuoteLike::Words') ) {
            my $s = quote_text($k);
            $named //= $1 if $s =~ /($MEASURED)/;
            $words{$_} = 1 for grep { /^[A-Z]\w*(?:::\w+)+$/ } split /[^\w:]+/, $s;
        }
        elsif ( $k->isa('PPI::Token::Word') ) {
            $words{$c} = 1;
            $words{$1} = 1 if $c =~ /::(\w+)$/;
            $named //= $1 if $c =~ /($MEASURED)/;
            next if $next && $next->content eq '=>';              # a hash key
            my $method = $prev && $prev->content eq '->';
            $launch->("loads a launcher ($c)") if $c =~ $LAUNCH_MODULE;
            next if $prev && $prev->content =~ /^(?:use|no)$/;    # `use open`, a pragma
                # A method `open` (IO::File and friends) takes its mode where a
                # function's would be a path; not worth telling apart.
            if    ($method)            { $launch->('->open') if $c eq 'open'; next }
            if    ( $LAUNCH_WORD{$c} ) { $launch->($c) }
            elsif ( $c eq 'do' || $c eq 'eval' ) {
                $launch->("$c EXPR") unless $next && $next->content eq '{';
            }
            elsif ( $c eq 'require' ) {
                $launch->('require EXPR')
                    unless $next && ( $next->isa('PPI::Token::Word') || $next->isa('PPI::Token::Number') );
            }
            elsif ( $c eq 'open' ) {
                my $mode = open_mode( @t[ $i + 1 .. $#t ] );
                $launch->("open ($mode)") if defined $mode;
            }
        }
    }
    return ( $why, $named, [ sort keys %words ] );
}

# The second argument of an open: undef when it is a plain read or write mode,
# otherwise what makes it a possible pipe (a `|`, or a mode not known until run
# time).
sub open_mode {
    my (@t) = @_;
    shift @t if @t && $t[0]->content eq '(';
    my $depth = 0;
    my $i     = 0;
    for ( ; $i < @t; $i++ ) {
        my $c = $t[$i]->content;
        $depth++                   if $c eq '('  || $c eq '[' || $c eq '{';
        $depth--                   if $c eq ')'  || $c eq ']' || $c eq '}';
        return 'one-argument open' if $depth < 0 || $c eq ';';
        last                       if $depth == 0 && ( $c eq ',' || $c eq '=>' );
    }
    my $arg = $t[ $i + 1 ] or return;
    return 'mode computed at run time' unless $arg->isa('PPI::Token::Quote');
    my $s = quote_text($arg);
    return "'$s'" if $s =~ /^\s*\||\|\s*$/ || $s eq '-|' || $s eq '|-';
    return;
}

# A file's analysis: for a module, its packages, what it loads, its named subs
# and its load-time code; for a test, the whole file.
sub analyse {
    my ( $path, $text ) = @_;
    my $doc = PPI::Document->new( \$text );
    return { failed => 1 } unless $doc;
    $doc->prune('PPI::Token::Comment');
    $doc->prune('PPI::Token::Pod');
    my @sig = grep { $_->significant } $doc->tokens;
    my ( %a, %skip );
    # What it loads by name. A plain `use Foo qw(...)` statement runs nothing
    # here (the module is judged on its own), so it is left out of load-time
    # code; one carrying anything more - `use constant X => qx(...)` - is not.
    for my $st ( @{ $doc->find('PPI::Statement::Include') || [] } ) {
        my @it = grep { $_->significant } $st->tokens;
        push @{ $a{uses} }, $st->module if $st->module;
        push @{ $a{uses} }, grep { /^[A-Z]\w*(?:::\w+)*$/ } map { split /[^\w:]+/, quote_text($_) }
            grep { $_->isa('PPI::Token::Quote') || $_->isa('PPI::Token::QuoteLike::Words') } @it
            if ( $st->module // '' ) =~ /^(?:parent|base)$/;
        my $plain = !grep {
            !( $_->isa('PPI::Token::Word')
                || $_->isa('PPI::Token::Quote')
                || $_->isa('PPI::Token::QuoteLike::Words')
                || $_->isa('PPI::Token::Number')
                || $_->content =~ /^(?:,|=>|;)$/ )
        } @it;
        $skip{ refaddr($_) } = 1 for $plain ? @it : ();
    }
    if ( $path =~ /\.t$/ ) {
        @a{qw(why named words)} = scan(@sig);
        return \%a;
    }
    my %in_sub;
    my %subs;
    for my $s ( @{ $doc->find('PPI::Statement::Sub') || [] } ) {
        next if $s->isa('PPI::Statement::Scheduled') || $s->forward || !defined $s->name;
        my @st = grep { $_->significant } $s->tokens;
        $in_sub{ refaddr($_) } = 1 for @st;
        my ( $why, undef, $words ) = scan(@st);
        my $n = $s->name;
        $n =~ s/.*:://;
        $subs{$n}{why} //= $why;
        push @{ $subs{$n}{words} }, @$words;
    }
    # Load-time code: everything outside a named sub, except a plain `use`
    # (above) and an export list (names, not calls).
    for my $st ( @{ $doc->find('PPI::Statement::Variable') || [] } ) {
        next unless $st->content =~ /^our\s+\@EXPORT(?:_OK)?\s*=\s*qw/;
        $skip{ refaddr($_) } = 1 for $st->tokens;
    }
    my @top = grep { !$in_sub{ refaddr($_) } && !$skip{ refaddr($_) } } @sig;
    @a{qw(top_why top_named top_words)} = scan(@top);
    $a{subs} = \%subs;
    $a{pkgs} = [ map { $_->namespace } @{ $doc->find('PPI::Statement::Package') || [] } ];
    $a{overload} = ( grep { $_ eq 'overload' } @{ $a{uses} || [] } ) ? 1 : 0;
    return \%a;
}

my $VERSION_KEY = sha256_hex( ( slurp($0) // '' ) . ( $HAVE_PPI ? $PPI::VERSION : 'none' ) );
my $CACHE       = "$ROOT/tmp/coverage-inputs-cache.sto";
my $cache       = {};
if ( $HAVE_PPI && -f $CACHE ) {
    my $c = eval { retrieve($CACHE) };
    $cache = $c if ref $c eq 'HASH';
}
my ( %fresh, %an );
for my $f ( @code, @tests ) {
    last unless $HAVE_PPI;
    my $text = slurp($f) // '';
    my $key  = sha256_hex( $VERSION_KEY, $f =~ /\.t$/ ? 't' : 'm', $text );
    $an{$f} = $fresh{$key} = $cache->{$key} // analyse( $f, $text );
}
if ($HAVE_PPI) {
    mkdir "$ROOT/tmp";
    my $tmp = "$CACHE.$$";
    rename $tmp, $CACHE if eval { nstore( \%fresh, $tmp ); 1 };
    unlink $tmp;
}

# Which subs launch, to a fixed point: a sub that mentions a launching sub's
# name launches. Names, not packages - two subs sharing a name share the
# verdict, which can only keep more tests in.
my %launching;
my $grew = 1;
while ( $HAVE_PPI && $grew ) {
    $grew = 0;
    for my $f (@code) {
        my $subs = $an{$f}{subs} || {};
        for my $n ( keys %$subs ) {
            next if $launching{$n};
            next unless $subs->{$n}{why} || grep { $launching{$_} } @{ $subs->{$n}{words} };
            $launching{$n} = 1;
            $grew = 1;
        }
        # A DESTROY, AUTOLOAD or tie method (an all-capitals name) runs without
        # being named, and so does an overload handler. When one of THIS
        # file's launches, every sub of the file counts as launching.
        my @implicit = $an{$f}{overload} ? keys %$subs : grep { /^[A-Z_]+$/ } keys %$subs;
        my $fires    = grep {
            my $s = $subs->{$_};
            $s->{why} || grep { $launching{$_} } @{ $s->{words} }
        } @implicit;
        if ($fires) {
            for ( grep { !$launching{$_} } keys %$subs ) { $launching{$_} = 1; $grew = 1 }
        }
    }
}

# Modules whose loading launches: their own load-time code does, an unparsable
# file is assumed to, or a module they load does.
my ( %loads, %pkg_of );
for my $f (@code) {
    ( my $p = $f ) =~ s{^(?:t/(?:[\w/]*/)?lib|lib|plugins)/}{};
    $p             =~ s{\.p[ml]$}{};
    $p             =~ s{/}{::}g;
    $pkg_of{$f} = [ $p, @{ $an{$f}{pkgs} || [] } ];
    my $a = $an{$f} || {};
    $loads{$_} = 1 for grep { $a->{failed} || $a->{top_why} || grep { $launching{$_} } @{ $a->{top_words} || [] } }
        @{ $pkg_of{$f} };
}
my %local = map { $_ => 1 } map { @$_ } values %pkg_of;
$grew = 1;
while ($grew) {
    $grew = 0;
    for my $f (@code) {
        next if grep     { $loads{$_} } @{ $pkg_of{$f} };
        next unless grep { $loads{$_} } @{ $an{$f}{uses} || [] };
        $loads{$_} = 1 for @{ $pkg_of{$f} };
        $grew = 1;
    }
}

sub why_in {
    my ($f) = @_;
    return 'PPI is not installed, so nothing can be shown inert' unless $HAVE_PPI;
    my $a = $an{$f};
    return 'PPI could not parse it'              if $a->{failed};
    return "launches: $a->{why}"                 if $a->{why};
    return "names a measured file ($a->{named})" if $a->{named};
    my ($ext) = grep { !$local{$_} && !$INERT{$_} } @{ $a->{uses} || [] };
    return "loads $ext, not known to be inert" if $ext;
    my @w = @{ $a->{words} };
    my ($s) = grep { $launching{$_} } @w;
    return "calls a launching sub ($s)" if $s;
    my ($m) = grep { $loads{$_} } @w;
    return "loads a module whose loading launches ($m)" if $m;
    return;
}

for my $f ( sort @tests ) {
    my $why = why_in($f);
    push @files, $f if defined $why;
    printf "%s\t%s\t%s\n", ( defined $why ? 'in' : 'out' ), $f, $why // 'reaches nothing measured' if $LIST;
}
exit 0 if $LIST;

my $h = Digest::SHA->new(256);
for my $f ( sort @files ) {
    open my $fh, '<:raw', $f or next;
    local $/;
    $h->add( $f, <$fh> );
    close $fh;
}
printf "%s %d\n", $h->hexdigest, scalar @files;
