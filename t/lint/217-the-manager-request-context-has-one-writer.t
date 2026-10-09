#!/usr/bin/perl
# SM944 S21: the manager request context has one writer.
#
# WHAT IT IS. What a manager-API request establishes about itself - who is
# asking ($auth_user), through which door ($token_auth, %token_caps), how far it
# reaches (@REQUEST_SCOPES, $REQUEST_CONFINED), whether it is the operator
# ($IS_OPERATOR), what it asked for ($action, $path, $body), and since S22b the
# account caps memo behind _user_caps (%USER_CAPS) - lives in
# Lazysite::Manager::Common as package variables, imported by the script and by
# the area modules that read them. Before SM944 it was file-scope `my` variables
# of lazysite-manager-api.pl, which nothing else could touch; moving it to
# package variables is what lets a handler leave the script unchanged, and it is
# also what lets anything that loads Common write it.
#
# THE RULE (ruled 2026-10-09). Only lazysite-manager-api.pl assigns these facts,
# and Common's reset_request_context(); everything else only reads them. A
# module that set one would be deciding identity or reach for a request it did
# not authenticate - a scope widened by a helper, an operator memo filled by a
# module - and a module loaded by a long-lived process (the daemon, MCP, WebDAV)
# would carry what it set into whatever runs next.
#
# WHAT IT CHECKS.
#   1. Common declares the ten with no initialiser, assigns them only inside
#      reset_request_context() (a sub that declares its own lexical of the same
#      name is reading that, not the fact), resets every one of them, exports
#      every one, and calls the reset at load. The one other writer in Common is
#      the memo's own reader: _user_caps fills %USER_CAPS one account at a time
#      (S22b, ruled 2026-10-09); a reset that left the memo full would carry one
#      request's account caps into the next in a pooled worker.
#   2. The script imports every one but the memo, which it neither reads nor
#      writes now that _user_caps lives in Common, declares none of them at file
#      scope, writes the memo by no name, and calls reset_request_context()
#      before it reads a credential.
#   3. Every other source file: no write to a fact by its full name
#      ($Lazysite::Manager::Common::auth_user = ...), outside the closed list
#      below of sites that pre-date the rule; and a file that imports a fact
#      never declares that name and never assigns it.
# A write is an assignment (any op=), ++/--, s///, tr///, local, undef, chomp,
# push/pop/shift/unshift/splice, delete, or an element or slice store. A write
# through a reference is out of reach of a text check.
#
# THE LIST. Five sites assigned Common's $action or $auth_user before S21 made
# them part of the context, all for log attribution: two other entry points name
# their own request, and three modules bridge their own copy of the acting user
# into Common's for one conf write (each goes when that module's own row imports
# from Common). The counts are exact, so a site that goes must leave the list
# with it, and a new one must be argued onto it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use File::Find ();

my $root = repo_root();

my %SIGIL = (
    auth_user   => '$', token_auth     => '$', REQUEST_CONFINED => '$',
    IS_OPERATOR => '$', action         => '$', path             => '$',
    body        => '$', REQUEST_SCOPES => '@', token_caps       => '%',
    USER_CAPS   => '%',
);

# Common's own writers beyond the reset: the memo and the one sub that fills it.
my %FILLED_BY = ( USER_CAPS => '_user_caps' );
# The facts the script reads and so imports: all but the memo (S22b).
my @SCRIPT_FACTS = grep { $_ ne 'USER_CAPS' } sort keys %SIGIL;
my @FACTS = sort keys %SIGIL;

my %KNOWN = (
    'lazysite-mcp.pl'         => { action => 1 },    # MCP's own request: action 'mcp'
    'tools/lazysite-users.pl' => { auth_user => 1 }, # the CLI's acting user, local to one write
    'lib/Lazysite/Manager/Layouts.pm' => { auth_user => 1 }, # local bridge for one conf write
    'lib/Lazysite/Manager/Domains.pm' => { auth_user => 1 }, # local bridge for one conf write
    'lib/Lazysite/Manager/Themes.pm' => { auth_user => 1 }, # local bridge for one conf write
);

my $Q = 'Lazysite::Manager::Common::';

sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    local $/;
    return scalar <$fh>;
}

# Code only: POD, everything after __END__/__DATA__, whole-line comments and a
# comment after a statement's semicolon or brace. Line numbers are kept.
sub code_of {
    my ($src) = @_;
    $src =~ s/^__(?:END|DATA)__\b.*//ms;
    $src =~ s{^(=[a-zA-Z].*?^=cut\b[^\n]*)}{ my $p = $1; $p =~ s/[^\n]//g; $p }gmse;
    $src =~ s/^\s*#.*$//mg;
    $src =~ s/([;{}])\s+#.*$/$1/mg;
    return $src;
}

# Every write to FACT in CODE, as "line N: text". $prefix is '' for the bare
# (imported or owned) name, or the package qualifier.
sub writes {
    my ( $code, $fact, $prefix ) = @_;
    my $s   = $SIGIL{$fact};
    my $n   = quotemeta( $prefix . $fact );
    my $op  = qr/(?:\*\*|<<|>>|&&|\|\||\/\/|[-+*\/.x%&|^])?=(?![=~>])/;
    my $dec = qr/\b(?:local|my|our|state)\b\s*(?:\([^)]*?)?/;
    my @re;
    if ( $s eq '$' ) {
        my $v = qr/\$$n\b(?!\s*(?:\[|\{|::))/;
        push @re, qr/$v\s*$op/, qr/$v\s*(?:\+\+|--)/, qr/(?:\+\+|--)\s*$v/,
            qr/$v\s*=~\s*(?:s|tr|y)\b/, qr/\b(?:chomp|chop|undef)\s*\(?\s*$v/,
            qr/\(\s*(?:[^()]*?,\s*)?$v\s*(?:,[^()]*)?\)\s*=(?![=~>])/;
    }
    elsif ( $s eq '@' ) {
        my $v = qr/\@$n\b(?!\s*(?:\[|\{))/;
        push @re, qr/$v\s*=(?![=~>])/, qr/\b(?:push|unshift|splice|pop|shift)\s*\(?\s*$v/,
            qr/\$$n\s*\[[^\]]*\]\s*$op/, qr/\$\#$n\s*=(?![=~>])/,
            qr/\bundef\s*\(?\s*$v/,      qr/\(\s*$v\s*\)\s*=(?![=~>])/;
    }
    else {
        my $v = qr/%$n\b/;
        push @re, qr/$v\s*=(?![=~>])/, qr/\$$n\s*\{[^}]*\}\s*$op/,
            qr/\$$n\s*\{[^}]*\}\s*(?:\+\+|--)/, qr/\bdelete\s*\(?\s*(?:local\s+)?\$$n\s*\{/,
            qr/\@$n\s*\{[^}]*\}\s*=(?![=~>])/, qr/\bundef\s*\(?\s*$v/;
    }
    # local of the whole variable or of one element; and (bare names only) a
    # my/our/state of the same name, which would shadow the fact.
    push @re, qr/\blocal\b\s*(?:\([^)]*?)?[\$\@%]$n\b/, qr/\blocal\s+\$$n\s*[\[\{]/;
    push @re, qr/$dec[\$\@%]$n\b(?!\s*(?:\[|\{|::))/ if $prefix eq '';
    my @hits;
    my $ln = 0;
    for my $line ( split /\n/, $code, -1 ) {
        $ln++;
        for my $re (@re) {
            if ( $line =~ $re ) { ( my $t = $line ) =~ s/^\s+//; push @hits, "line $ln: $t"; last }
        }
    }
    # S22b: the operator on the next line - `$X{$k}` ending one line and `//=`
    # starting the next, as _user_caps fills its memo - is an assignment too.
    my $lhs
        = $s eq '%'     ? qr/\$$n\s*\{[^}\n]*\}/
        : $s eq '@'     ? qr/\$$n\s*\[[^\]\n]*\]/
        : $prefix eq '' ? qr/\$$n\b(?!\s*(?:\[|\{|::))/
        :                 qr/\$$n\b(?!\s*(?:\[|\{))/;
    while ( $code =~ /($lhs)[ \t]*\n[ \t]*$op/g ) {
        my ( $what, $from ) = ( $1, $-[0] );
        my $at = 1 + ( () = substr( $code, 0, $from ) =~ /\n/g );
        push @hits, "line $at: $what (operator on the next line)";
    }
    return @hits;
}

# The names a file imports from Common.
sub imported_facts {
    my ($code) = @_;
    my %open2close = ( '(' => ')', '{' => '}', '[' => ']', '/' => '/' );
    my @names;
    while ( $code =~ /\buse\s+Lazysite::Manager::Common\b\s*qw\s*([({\[\/])/g ) {
        my $close = $open2close{$1};
        my $from  = pos $code;
        my $to    = index( $code, $close, $from );
        next if $to < 0;
        push @names, split ' ', substr( $code, $from, $to - $from );
    }
    my %want = map { ( $SIGIL{$_} . $_ => $_ ) } @FACTS;
    return grep { defined } map { $want{$_} } @names;
}

# --- 1. Common owns them ------------------------------------------------------
{
    my $code = code_of( slurp("$root/lib/Lazysite/Manager/Common.pm") );

    for my $f (@FACTS) {
        like( $code, qr/^our\s*\([^)]*\Q$SIGIL{$f}$f\E\b[^)]*\)\s*;/m,
            "Common declares $SIGIL{$f}$f with `our` and no initialiser" );
    }
    my ($exports) = $code =~ /our\s+\@EXPORT_OK\s*=\s*qw\s*\((.*?)\)/s;
    my %exp       = map { $_ => 1 } split ' ', $exports // '';
    is_deeply( [ grep { !$exp{ $SIGIL{$_} . $_ } } @FACTS ], [], 'Common exports every fact' );
    ok( $exp{reset_request_context}, '...and reset_request_context' );

    # Per sub, to its closing brace in column 0; what is outside every sub is
    # file scope, which assigns none of them (the `our` carries no value).
    my ( %subs, @order );
    my $cur = '(file scope)';
    my $ln  = 0;
    for my $line ( split /\n/, $code, -1 ) {
        $ln++;
        if ( $line =~ /^sub\s+(\w+)/ ) { $cur = $1; push @order, $cur }
        $subs{$cur} .= "$line\n";
        $subs{'(file scope)'} .= "\n" if $cur ne '(file scope)';
        $cur = '(file scope)' if $line =~ /^\}/;
    }
    ok( exists $subs{reset_request_context}, 'Common defines reset_request_context' );
    my $reset = $subs{reset_request_context} // '';
    is_deeply( [ grep { !writes( $reset, $_, '' ) } @FACTS ], [], 'the reset sets every fact' );

    my @stray;
    for my $sub ( '(file scope)', @order ) {
        next if $sub eq 'reset_request_context';
        my $body = $subs{$sub};
        for my $f (@FACTS) {
            next if ( $FILLED_BY{$f} // '' ) eq $sub;
            # A sub's own `my $path` is a lexical; its writes are not the fact's.
            next if $sub ne '(file scope)'
                && $body =~ /\b(?:my|state)\b\s*(?:\([^)]*?)?\Q$SIGIL{$f}$f\E\b/;
            push @stray, map { "$sub: $_" }
                grep { !/^line \d+: our\s*\(/ } writes( $body, $f, '' );
        }
    }
    is_deeply( \@stray, [], 'Common assigns the context only in reset_request_context' )
        or diag( join "\n", @stray );
    like( $subs{'(file scope)'}, qr/^reset_request_context\(\);/m, 'Common resets the context when it loads' );
    for my $f ( sort keys %FILLED_BY ) {
        my $by = $subs{ $FILLED_BY{$f} } // '';
        is_deeply( [ map { s/^line \d+: //r } writes( $by, $f, '' ) ],
            ["\$$f\{\$user\} (operator on the next line)"],
            "$FILLED_BY{$f} fills $SIGIL{$f}$f one element at a time (\$$f\{\$user\} //= ...), and only that" );
    }
}

# --- 2. The script is the writer ----------------------------------------------
{
    my $code = code_of( slurp("$root/lazysite-manager-api.pl") );
    my %imp  = map { $_ => 1 } imported_facts($code);
    is_deeply( [ grep { !$imp{$_} } @SCRIPT_FACTS ], [], 'the script imports every fact it reads from Common' );
    is_deeply( [ map { writes( $code, $_, '' ), writes( $code, $_, $Q ) } grep { !$imp{$_} } @FACTS ],
        [], '...and writes the memo by no name' );
    my @mine = grep { $code =~ /^(?:my|our|state)\b\s*(?:\([^)]*?)?\Q$SIGIL{$_}$_\E\b/m } @FACTS;
    is_deeply( \@mine, [], 'the script declares none of them at file scope (no private copy beside the shared one)' );

    my $reset = $code =~ /^reset_request_context\(\);/m ? $-[0] : -1;
    my $cred  = index( $code, '$ENV{HTTP_AUTHORIZATION}' );
    ok( $reset >= 0, 'the script calls reset_request_context()' );
    ok( $cred > 0 && $reset >= 0 && $reset < $cred, '...before it reads a credential' );
}

# --- 3. Everything else reads -------------------------------------------------
my @sources;
File::Find::find(
    { no_chdir => 1,
        wanted => sub {
            return unless /\.(?:pm|pl)\z/;
            # Matched on the path below $root: the checkout itself may sit under
            # a tmp/ (a git worktree, the release staging clone in /tmp).
            ( my $rel = $File::Find::name ) =~ s{\A\Q$root\E}{};
            return if $rel =~ m{/(?:t|tmp|dist|man|node_modules)/};
            push @sources, $File::Find::name;
        },
    },
    grep { -d } map { "$root/$_" } qw(lib tools plugins lazysite-processor),
);
push @sources, grep { -f } glob "$root/*.pl";
ok( scalar @sources > 50, 'found the sources to scan' );

my ( @qualified, @imported, %seen );
for my $file ( sort @sources ) {
    ( my $rel = $file ) =~ s{\A\Q$root\E/}{};
    next if $rel eq 'lazysite-manager-api.pl' || $rel eq 'lib/Lazysite/Manager/Common.pm';
    my $code = code_of( slurp($file) );
    for my $f (@FACTS) {
        my @w = writes( $code, $f, $Q );
        $seen{$rel}{$f} = scalar @w if @w;
        push @qualified, map { "$rel: $SIGIL{$f}$Q$f $_" } @w
            unless @w == ( $KNOWN{$rel}{$f} // 0 );
    }
    for my $f ( imported_facts($code) ) {
        push @imported, map { "$rel: $SIGIL{$f}$f $_" } writes( $code, $f, '' );
    }
}
is_deeply( \@qualified, [], 'no file writes a fact by its full name, beyond the five known sites' )
    or diag( "Only lazysite-manager-api.pl sets the request context:\n  " . join "\n  ", @qualified );
is_deeply( \@imported, [], 'a file that imports a fact never declares or assigns it' )
    or diag( "Read it; the script sets it:\n  " . join "\n  ", @imported );
for my $rel ( sort keys %KNOWN ) {
    for my $f ( sort keys %{ $KNOWN{$rel} } ) {
        is( $seen{$rel}{$f} // 0, $KNOWN{$rel}{$f},
            "the known site in $rel still writes $f (remove it from the list when it goes)" );
    }
}

done_testing();
